-- Whole-word, case-insensitive matcher.
--
-- Given a line of buffer text and the gloss index built by glosses.lua, return
-- a list of hits: { col_start, col_end (exclusive), key } in byte units, which
-- is what nvim_buf_set_extmark expects.
--
-- Boundary rule: a hit is valid only if the bytes immediately before
-- (col_start - 1) and at col_end are NOT "word continuation" bytes. We treat
-- ASCII letters/digits/underscore AND any byte with the high bit set as
-- word-continuation. The high-bit catch-all is deliberate: it conservatively
-- treats every UTF-8 continuation/start byte as part of a word, which means
-- we won't accidentally match "field" mid-way through a Danish or German
-- compound like "feltforhold" or "magnetfeltsstørrelse".

local M = {}

local glosses = require("hanzi-overlay.glosses")

-- 0x30-0x39 (digits), 0x41-0x5A (A-Z), 0x5F (_), 0x61-0x7A (a-z),
-- and >= 0x80 (any non-ASCII byte).
local function is_word_byte(b)
  if not b then return false end
  return (b >= 0x30 and b <= 0x39)
      or (b >= 0x41 and b <= 0x5A)
      or  b == 0x5F
      or (b >= 0x61 and b <= 0x7A)
      or  b >= 0x80
end

-- Returns (ok, effective_end). When the trailing byte is still a word byte but
-- `allow_trailing` is set, consumes a run of allowed bytes and re-checks the
-- boundary at the new position; on success the caller anchors the extmark at
-- the extended position so it lands after the *whole* inflected form.
local function boundary_ok(line, s, e, allow_trailing)
  local before = s > 1 and line:byte(s - 1) or nil
  if is_word_byte(before) then return false, e end
  local after = e <= #line and line:byte(e) or nil
  if not is_word_byte(after) then return true, e end
  if not allow_trailing or allow_trailing == "" then return false, e end

  local rest = line:sub(e)
  local prefix = rest:match("^" .. allow_trailing)
  if not prefix or prefix == "" then return false, e end
  local j = e + #prefix
  local after2 = j <= #line and line:byte(j) or nil
  if is_word_byte(after2) then return false, e end
  return true, j
end

-- Lowercase the entire line once -- vim.fn.tolower is codepoint-aware and
-- handles Æ/Ø/Å/Ä/Ö correctly, which string.lower does not.
local function lower_line(line, case_insensitive)
  if not case_insensitive then return line end
  return vim.fn.tolower(line)
end

-- Returns a list of { col_start, col_end, key, entry } in byte coordinates,
-- ordered by col_start. col_end is exclusive (extmark convention).
--
-- `skip_ranges` is a sorted list of [s, e] byte ranges to ignore (math / code
-- spans / etc.); see treesitter.regex_skip_ranges.
--
-- `seen_keys` is an optional set the caller mutates to enforce density modes;
-- if a key is already in `seen_keys`, the hit is skipped. The caller decides
-- whether `seen_keys` resets per paragraph or persists for the buffer.
function M.scan_line(line, opts)
  opts = opts or {}
  local case_insensitive = opts.case_insensitive ~= false
  local skip_ranges = opts.skip_ranges
  local seen_keys = opts.seen_keys
  local trailing_by_source = opts.allow_trailing or {}

  local hits = {}
  if #line == 0 or #glosses.keys == 0 then return hits end

  local hay = lower_line(line, case_insensitive)

  -- Track byte ranges that earlier (longer) matches have already covered so we
  -- don't emit "field" inside an already-matched "magnetic field". Since we
  -- iterate keys longest-first, the first claim on a range wins.
  local claimed = {}
  local function claim_overlaps(s, e)
    for _, c in ipairs(claimed) do
      if not (e <= c[1] or s >= c[2]) then return true end
    end
    return false
  end

  for _, key in ipairs(glosses.keys) do
    if seen_keys and seen_keys[key] then
      -- skip: density mode says we already showed this one
    else
      local entry = glosses.get(key)
      local allow = entry and trailing_by_source[entry.source] or nil
      local i = 1
      while i <= #hay do
        local s, e = hay:find(key, i, true) -- plain find, no patterns
        if not s then break end
        local ee = e + 1 -- extmark exclusive end (byte after the match)

        local b_ok, eff_end = boundary_ok(hay, s, ee, allow)
        local ok = b_ok
            and not claim_overlaps(s - 1, eff_end - 1)
            and not (skip_ranges and require("hanzi-overlay.treesitter").in_ranges(skip_ranges, s - 1))

        if ok then
          claimed[#claimed + 1] = { s - 1, eff_end - 1 }
          hits[#hits + 1] = {
            col_start = s - 1,         -- extmark API: 0-indexed
            col_end = eff_end - 1,
            key = key,
            entry = entry,
          }
          -- When the caller is enforcing density (seen_keys is non-nil), one
          -- hit per key is the cap -- bail out of this key's inner scan.
          if seen_keys then
            seen_keys[key] = true
            break
          end
          if opts.first_match_only then break end
          i = eff_end
        else
          i = e + 1
        end
      end
    end
  end

  table.sort(hits, function(a, b) return a.col_start < b.col_start end)
  return hits
end

return M
