-- Extmark orchestration: scan the buffer line by line, decide which hits to
-- keep based on the density mode, and place inline virtual-text extmarks.
--
-- Per-buffer state lives in `vim.b.hanzi_overlay_mode` and in our internal
-- `state` table keyed by bufnr (mode is duplicated in the buffer var because
-- it's user-visible and survives reloads of this module during dev).

local M = {}

local config = require("hanzi-overlay.config")
local glosses = require("hanzi-overlay.glosses")
local scanner = require("hanzi-overlay.scanner")
local ts = require("hanzi-overlay.treesitter")
local hl = require("hanzi-overlay.highlight")
local exposures = require("hanzi-overlay.exposures")

-- Read the gate's per-word SRS data (state.json) regardless of the
-- gate_integration flag. The map is only consulted for highlight bucketing --
-- it is not a "promotion" or "write" bridge, just a read of whatever the gate
-- has been recording on its own. If hanzi-gate isn't installed the call
-- returns nil and every overlay falls back to the default group, identical to
-- pre-integration behaviour.
local function gate_known_words()
  local ok, store = pcall(require, "hanzi-gate.store")
  if not ok then return nil end
  local st = store.load and store.load()
  return st and st.words or nil
end

-- Pick the highlight group for one hanzi from its gate `correct` count.
-- Thresholds come from config.srs_thresholds; defaults grade at 5 and 15
-- correct uses (see config.lua for the rationale). We use raw `correct`
-- rather than the SRS ease score because the gate caps ease at 3.0 after
-- 5 passes -- past that, ease can't distinguish a word you've used 6 times
-- from one you've used 60.
--
-- Hanzi with no state record at all are treated as fresh: in practice that
-- only happens for legacy glosses.tsv rows added before this workflow, and
-- surfacing them brightly nudges the user to re-gate them.
local function pick_group(gate_known, hanzi)
  if not gate_known or not hanzi then return hl.group end
  local rec = gate_known[hanzi]
  if type(rec) ~= "table" then return hl.fresh end
  local correct = tonumber(rec.correct) or 0
  local thr = config.get().srs_thresholds or {}
  local mastered  = tonumber(thr.mastered)  or 15
  local improving = tonumber(thr.improving) or 5
  if correct >= mastered  then return hl.mastered  end
  if correct >= improving then return hl.improving end
  return hl.fresh
end

M.ns = vim.api.nvim_create_namespace("hanzi_overlay")

-- Per-buffer state.
--   mode: "hanzi" | "pinyin" | "off"
--   disabled: session-only kill switch from :HanziOverlay disable
--   count, used_keys: from the last render -- read by :HanziOverlay stats
--   debounce_timer: a vim.uv timer; one per buffer
local state = {}

local function buf_state(buf)
  state[buf] = state[buf] or { mode = nil, disabled = false, count = 0, used_keys = {} }
  return state[buf]
end

function M.get_mode(buf)
  local s = buf_state(buf)
  if s.mode then return s.mode end
  -- First read: honour vim.b var, else config default.
  local v = vim.b[buf].hanzi_overlay_mode
  s.mode = v or config.get().default_mode or "hanzi"
  return s.mode
end

function M.set_mode(buf, mode)
  buf_state(buf).mode = mode
  vim.b[buf].hanzi_overlay_mode = mode
end

function M.is_disabled(buf)
  return buf_state(buf).disabled
end

function M.disable(buf)
  buf_state(buf).disabled = true
  M.clear(buf)
end

function M.enable(buf)
  buf_state(buf).disabled = false
end

----------------------------------------------------------------------
-- Render
----------------------------------------------------------------------

function M.clear(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  pcall(vim.api.nvim_buf_clear_namespace, buf, M.ns, 0, -1)
  buf_state(buf).count = 0
  buf_state(buf).used_keys = {}
end

local function is_blank(line)
  return line == "" or line:match("^%s*$") ~= nil
end

-- Skip ranges for one line. We always pass the regex sieve along, because it
-- catches things treesitter can also see -- the precise per-position ts check
-- below runs *additionally*, not instead.
local function line_skip_ranges(_buf, ft, _row, line)
  return ts.regex_skip_ranges(ft, line)
end

-- Render a single buffer. Honors density, mode, max_overlays, ts/regex skips.
function M.render(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then return end

  local s = buf_state(buf)
  if s.disabled then return end

  local cfg = config.get()
  local ft = vim.bo[buf].filetype
  if not vim.tbl_contains(cfg.filetypes, ft) then return end

  M.clear(buf)

  local mode = M.get_mode(buf)
  if mode == "off" then return end
  if not glosses.loaded then return end

  local n_lines = vim.api.nvim_buf_line_count(buf)
  if n_lines > cfg.large_buffer_lines then
    -- Big buffer: only render on manual refresh. The autocmd checks this flag
    -- via M.is_large_buffer() before scheduling debounced refreshes.
    -- We still render here on explicit calls.
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ts_ok = ts.has_parser(ft)
  local total = 0
  local max = cfg.max_overlays
  local used_keys = {}

  -- Snapshot the gate's per-word stats once per render. Used for SRS-ease
  -- bucketing of highlight groups (fresh/improving/mastered). Independent of
  -- gate_integration.enabled, which now only controls the write side
  -- (exposures.record) and the legacy binary new/known distinction.
  local gi = cfg.gate_integration or {}
  local gate_known = gate_known_words()

  -- "buffer" density: one seen set for the whole render.
  -- "paragraph" density: reset whenever we cross a blank line.
  -- "every" density: nil seen (no dedup).
  local buffer_seen = (cfg.density == "buffer") and {} or nil
  local para_seen   = (cfg.density == "paragraph") and {} or nil

  -- Cross-line block tracking for the regex fallback (multi-line fenced code
  -- blocks, math envs). When treesitter is available we still maintain it,
  -- but the precise per-position ts check below is the authority.
  local block = ts.new_block_ctx()

  for row_idx, line in ipairs(lines) do
    if total >= max then break end
    local row = row_idx - 1

    ts.advance_block_ctx(block, ft, line)

    if is_blank(line) then
      if cfg.density == "paragraph" then para_seen = {} end
    elseif block.in_block then
      -- Wholly inside a multi-line skip block: don't scan.
    else
      local skip_ranges = line_skip_ranges(buf, ft, row, line)

      local seen
      if cfg.density == "buffer" then
        seen = buffer_seen
      elseif cfg.density == "paragraph" then
        seen = para_seen
      end

      local hits = scanner.scan_line(line, {
        case_insensitive = cfg.case_insensitive,
        skip_ranges = skip_ranges,
        seen_keys = seen,
        allow_trailing = cfg.allow_trailing,
      })

      for _, hit in ipairs(hits) do
        if total >= max then break end

        local skip_ts = ts_ok and ts.should_skip_position(buf, ft, row, hit.col_start)

        if not skip_ts and hit.entry then
          local text = (mode == "pinyin") and hit.entry.pinyin or hit.entry.hanzi
          if text and text ~= "" then
            local h = hit.entry.hanzi
            local group = pick_group(gate_known, h)
            pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, row, hit.col_end, {
              virt_text = { { " " .. text, group } },
              virt_text_pos = "inline",
              hl_mode = "combine",
              undo_restore = false,
              invalidate = true,
              right_gravity = false,
            })
            total = total + 1
            used_keys[hit.key] = (used_keys[hit.key] or 0) + 1
            -- Bridge: record exposure once per session per hanzi (no-op when
            -- gate_integration is disabled). Hot path, so keep it cheap.
            if gi.enabled and h then exposures.record(h, cfg) end
          end
        end
      end
    end

    ts.finish_block_line(block)
  end

  s.count = total
  s.used_keys = used_keys
end

function M.is_large_buffer(buf)
  local cfg = config.get()
  return vim.api.nvim_buf_line_count(buf) > cfg.large_buffer_lines
end

----------------------------------------------------------------------
-- Debounced refresh. One uv timer per buffer.
----------------------------------------------------------------------

function M.schedule_refresh(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local s = buf_state(buf)
  if s.disabled then return end
  if M.is_large_buffer(buf) then return end

  local cfg = config.get()
  if s.debounce_timer then
    s.debounce_timer:stop()
    s.debounce_timer:close()
    s.debounce_timer = nil
  end
  local t = vim.uv.new_timer()
  s.debounce_timer = t
  t:start(cfg.debounce_ms, 0, vim.schedule_wrap(function()
    if t and not t:is_closing() then
      t:stop(); t:close()
    end
    s.debounce_timer = nil
    if vim.api.nvim_buf_is_valid(buf) then M.render(buf) end
  end))
end

-- Force refresh: skips debounce, ignores large-buffer auto-disable.
function M.refresh_now(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then return end
  M.render(buf)
end

----------------------------------------------------------------------
-- Stats
----------------------------------------------------------------------

function M.stats(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local s = buf_state(buf)
  return { count = s.count or 0, used_keys = s.used_keys or {}, mode = M.get_mode(buf) }
end

function M.cycle_mode(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local m = M.get_mode(buf)
  local next_mode = ({ hanzi = "pinyin", pinyin = "off", off = "hanzi" })[m] or "hanzi"
  M.set_mode(buf, next_mode)
  if next_mode == "off" then
    M.clear(buf)
  else
    M.render(buf)
  end
  return next_mode
end

-- Re-render every active buffer (used by the glosses.tsv watcher).
function M.refresh_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local cfg = config.get()
      if vim.tbl_contains(cfg.filetypes, vim.bo[buf].filetype) then
        M.render(buf)
      end
    end
  end
end

----------------------------------------------------------------------
-- Jump between overlays. Wraps around the buffer when there's no further mark.
----------------------------------------------------------------------

-- Returns extmark positions [{ row, col }, ...], sorted ascending. Empty if none.
local function mark_positions(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, M.ns, 0, -1, {})) do
    out[#out + 1] = { row = m[2], col = m[3] }
  end
  return out
end

local function jump(buf, direction)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  local marks = mark_positions(buf)
  if #marks == 0 then return false end
  local cur = vim.api.nvim_win_get_cursor(0)
  local cr, cc = cur[1] - 1, cur[2]

  local target
  if direction == "next" then
    for _, m in ipairs(marks) do
      if m.row > cr or (m.row == cr and m.col > cc) then target = m; break end
    end
    target = target or marks[1] -- wrap to first
  else
    for i = #marks, 1, -1 do
      local m = marks[i]
      if m.row < cr or (m.row == cr and m.col < cc) then target = m; break end
    end
    target = target or marks[#marks] -- wrap to last
  end

  vim.api.nvim_win_set_cursor(0, { target.row + 1, target.col })
  return true
end

function M.jump_next(buf) return jump(buf, "next") end
function M.jump_prev(buf) return jump(buf, "prev") end

return M
