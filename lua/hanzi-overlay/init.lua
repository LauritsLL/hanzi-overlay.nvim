-- Public surface: setup(), toggle(), refresh(), disable(), enable(), stats().
--
-- This module also wires the buffer autocmds (the plugin/ entry point handles
-- the user command and the FileType bootstrap, but the per-buffer TextChanged
-- handlers are installed here on first attach -- one autocmd group per buffer).

local M = {}

local config = require("hanzi-overlay.config")
local glosses = require("hanzi-overlay.glosses")
local overlay = require("hanzi-overlay.overlay")
local watcher = require("hanzi-overlay.watcher")
local hl = require("hanzi-overlay.highlight")

local function notify(msg, level)
  vim.notify("[hanzi-overlay] " .. msg, level or vim.log.levels.INFO)
end

local attached = {}

-- Install per-buffer autocmds and keymaps the first time we see a buffer.
local function attach(buf)
  if attached[buf] then return end
  attached[buf] = true

  local cfg = config.get()
  local group = vim.api.nvim_create_augroup("HanziOverlayBuf" .. buf, { clear = true })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group, buffer = buf,
    callback = function() overlay.schedule_refresh(buf) end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group, buffer = buf,
    callback = function() overlay.schedule_refresh(buf) end,
  })
  -- Clean up state when the buffer goes away.
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group, buffer = buf,
    callback = function()
      attached[buf] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })

  local km = cfg.keymaps or {}
  local function map(lhs, rhs, desc)
    if not lhs or lhs == "" then return end
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end
  map(km.toggle_mode,   function() M.toggle(buf) end,  "hanzi-overlay: cycle mode")
  map(km.force_refresh, function() M.refresh(buf) end, "hanzi-overlay: force refresh")
  map(km.disable,       function() M.disable(buf) end, "hanzi-overlay: disable for session")
  map(km.jump_next,     function() M.jump_next(buf) end, "hanzi-overlay: next overlay")
  map(km.jump_prev,     function() M.jump_prev(buf) end, "hanzi-overlay: previous overlay")

  -- Initial render once we're attached.
  overlay.refresh_now(buf)
end

-- Called by the FileType autocmd in plugin/. Public so tests can drive it.
function M.attach_current_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local cfg = config.get()
  if not vim.tbl_contains(cfg.filetypes, vim.bo[buf].filetype) then return end
  attach(buf)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function M.setup(opts)
  config.setup(opts)
  hl.setup(config.get().highlight)

  local ok = glosses.load(config.get().shared_data_dir)
  if not ok then
    notify(
      "glosses.tsv not found at " .. glosses.path_for(config.get().shared_data_dir)
        .. " -- plugin is inert. See README for format.",
      vim.log.levels.WARN
    )
    return M
  end

  watcher.start()
  return M
end

function M.toggle(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local m = overlay.cycle_mode(buf)
  notify("mode: " .. m)
  return m
end

function M.refresh(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  overlay.refresh_now(buf)
end

function M.disable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  overlay.disable(buf)
  notify("disabled for this buffer (this session)")
end

function M.jump_next(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not overlay.jump_next(buf) then notify("no overlays in this buffer", vim.log.levels.WARN) end
end

function M.jump_prev(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not overlay.jump_prev(buf) then notify("no overlays in this buffer", vim.log.levels.WARN) end
end

function M.enable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  overlay.enable(buf)
  overlay.refresh_now(buf)
end

function M.stats(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local s = overlay.stats(buf)
  local lines = {
    string.format("mode: %s", s.mode),
    string.format("overlays rendered: %d", s.count),
  }
  local entries = {}
  for k, n in pairs(s.used_keys) do entries[#entries + 1] = { k, n } end
  table.sort(entries, function(a, b) return a[2] > b[2] end)
  if #entries == 0 then
    lines[#lines + 1] = "(no overlays)"
  else
    lines[#lines + 1] = "words used:"
    for _, e in ipairs(entries) do
      lines[#lines + 1] = string.format("  %s  ×%d", e[1], e[2])
    end
  end
  notify(table.concat(lines, "\n"))
end

return M
