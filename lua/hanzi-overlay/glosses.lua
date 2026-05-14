-- Loads ~/.config/nvim/hanzi-immersion/glosses.tsv into an in-memory index
-- keyed by lowercased English/Danish phrase, and converts the TSV's numbered
-- pinyin ("wen1du4") into display-ready diacritic pinyin ("wēndù", with
-- apostrophes inserted before a/e/o syllable starts when ambiguous).
--
-- The pinyin conversion happens once, on load, rather than at extmark time --
-- per-keystroke debounces should be doing extmark math, not Unicode lookups.

local M = {}

----------------------------------------------------------------------
-- Numbered pinyin -> diacritic pinyin.
--
-- Tone-placement rule (the standard one):
--   1. If the syllable contains `a`, mark the `a`.
--   2. Else if it contains `o`, mark the `o`.
--   3. Else if it contains `e`, mark the `e`.
--   4. Else for `iu` mark the `u`; for `ui` mark the `i`.
--   5. Otherwise mark the last vowel.
-- Tone 5 / no digit = neutral, no diacritic.
--
-- ASCII `v` and `u:` are both accepted as `ü` in the input -- some sources
-- type one or the other and the user shouldn't have to normalise.
----------------------------------------------------------------------

local DIACRITICS = {
  a = { "ā", "á", "ǎ", "à", "a" },
  e = { "ē", "é", "ě", "è", "e" },
  i = { "ī", "í", "ǐ", "ì", "i" },
  o = { "ō", "ó", "ǒ", "ò", "o" },
  u = { "ū", "ú", "ǔ", "ù", "u" },
  ["ü"] = { "ǖ", "ǘ", "ǚ", "ǜ", "ü" },
}

-- Pick which vowel in `letters` (already lowercased, ü-normalised) carries
-- the tone. Returns the byte index of that vowel, or nil if there is no vowel.
local function tone_carrier_index(letters)
  -- 1-3: priority vowels.
  for _, v in ipairs({ "a", "o", "e" }) do
    local i = letters:find(v, 1, true)
    if i then return i end
  end
  -- 4: iu / ui contractions.
  local iu = letters:find("iu", 1, true)
  if iu then return iu + 1 end -- the `u`
  local ui = letters:find("ui", 1, true)
  if ui then return ui + 1 end -- the `i`
  -- ü as a single codepoint can't be located with plain find on a multi-byte
  -- string by character index, but it can be the only vowel (e.g. nǚ, lǜ).
  -- We just scan for it.
  for pos = 1, #letters do
    local c = letters:sub(pos, pos)
    if c == "i" or c == "u" then return pos end
  end
  -- ü is 2 bytes (0xC3 0xBC); detect by scanning.
  local up = letters:find("ü", 1, true)
  if up then return up end
  return nil
end

-- Replace the byte at `idx` (or the 2-byte ü starting at `idx`) with its
-- tone-`n` diacritic equivalent. Returns the rewritten string.
local function apply_tone(letters, idx, tone)
  local target = letters:sub(idx, idx)
  local span = 1
  if target == "\xC3" then -- first byte of ü in UTF-8
    target = letters:sub(idx, idx + 1)
    span = 2
  end
  local map = DIACRITICS[target]
  if not map then return letters end
  local replacement = map[tone] or target
  return letters:sub(1, idx - 1) .. replacement .. letters:sub(idx + span)
end

-- "wen1du4" -> { "wēn", "dù" }. Unrecognised junk is returned verbatim as a
-- single chunk -- we'd rather show literal input than swallow it silently.
local function numbered_to_diacritic_syllables(input)
  local syllables = {}
  -- Match a run of letters (with optional `u:`/`v` for ü) followed by an
  -- optional tone digit. We normalise `u:` -> `ü`, `v` -> `ü` first.
  local norm = input:lower():gsub("u:", "ü"):gsub("v", "ü")
  for letters, tone in norm:gmatch("([a-zü]+)([1-5]?)") do
    if letters ~= "" then
      local n = tonumber(tone) or 5
      if n == 5 then
        syllables[#syllables + 1] = letters
      else
        local carrier = tone_carrier_index(letters)
        if carrier then
          syllables[#syllables + 1] = apply_tone(letters, carrier, n)
        else
          syllables[#syllables + 1] = letters
        end
      end
    end
  end
  return syllables
end

-- Join syllables, inserting `'` before any syllable that starts with a/e/o
-- when preceded by another syllable (standard pinyin disambiguation rule).
-- Without the apostrophe, "xian" and "xi'an" become indistinguishable.
local function join_syllables(syllables)
  if #syllables == 0 then return "" end
  local out = { syllables[1] }
  for i = 2, #syllables do
    local first = syllables[i]:sub(1, 1)
    if first == "a" or first == "e" or first == "o"
       or first == "ā" or first == "á" or first == "ǎ" or first == "à"
       or first == "ē" or first == "é" or first == "ě" or first == "è"
       or first == "ō" or first == "ó" or first == "ǒ" or first == "ò" then
      out[#out + 1] = "'"
    end
    out[#out + 1] = syllables[i]
  end
  return table.concat(out)
end

function M.pretty_pinyin(numbered)
  if not numbered or numbered == "" then return "" end
  return join_syllables(numbered_to_diacritic_syllables(numbered))
end

----------------------------------------------------------------------
-- TSV parsing.
----------------------------------------------------------------------

-- Lua's string.lower is ASCII-only; for Danish text we need codepoint-aware
-- lowercasing, which vim.fn.tolower provides.
local function lower(s)
  return vim.fn.tolower(s)
end

local function split_glosses(field)
  if not field or field == "" then return {} end
  local out = {}
  for piece in field:gmatch("[^;]+") do
    local trimmed = vim.trim(piece)
    if trimmed ~= "" then out[#out + 1] = trimmed end
  end
  return out
end

-- Parsed shape per index entry:
--   { hanzi = "温度", pinyin = "wēndù", source = "english" or "danish",
--     phrase = "temperature" }
-- The index is keyed by the lowercased phrase (which is what we look for in
-- the buffer). First-write-wins on collisions, so the TSV's row order acts
-- as priority -- put your preferred mapping for an ambiguous gloss first.
local function build_index(rows)
  local index = {}
  local by_length = {}
  for _, r in ipairs(rows) do
    local pretty = M.pretty_pinyin(r.pinyin)
    local function add(phrase, source)
      local key = lower(phrase)
      if key ~= "" and index[key] == nil then
        index[key] = { hanzi = r.hanzi, pinyin = pretty, phrase = phrase, source = source }
        by_length[#by_length + 1] = key
      end
    end
    for _, en in ipairs(split_glosses(r.english)) do add(en, "english") end
    for _, da in ipairs(split_glosses(r.danish))  do add(da, "danish")  end
  end
  -- Sort longest-first so multi-word phrases beat substrings of themselves
  -- ("magnetic field" wins over "field" at the same starting position).
  table.sort(by_length, function(a, b) return #a > #b end)
  return index, by_length
end

-- Read the file and return rows in TSV order. Bad lines (wrong column count)
-- are skipped silently -- we'd rather render fewer overlays than crash.
local function read_tsv(path)
  local fd = io.open(path, "r")
  if not fd then return nil end
  local rows = {}
  for line in fd:lines() do
    -- skip blank and comment lines
    if line ~= "" and not line:match("^%s*#") then
      local fields = vim.split(line, "\t", { plain = true, trimempty = false })
      if #fields >= 3 then
        rows[#rows + 1] = {
          hanzi = vim.trim(fields[1] or ""),
          pinyin = vim.trim(fields[2] or ""),
          english = vim.trim(fields[3] or ""),
          danish = vim.trim(fields[4] or ""),
        }
      end
    end
  end
  fd:close()
  return rows
end

----------------------------------------------------------------------
-- Module-level cache. `M.load()` populates these; everything downstream
-- (scanner, overlay) reads them.
----------------------------------------------------------------------

M.path = nil
M.index = {}     -- lowercased phrase -> entry
M.keys = {}      -- ordered list (longest first), iterate this when scanning
M.loaded = false

function M.path_for(shared_dir)
  return vim.fn.expand(shared_dir) .. "/glosses.tsv"
end

-- Returns true on success, false on missing file. Other parse errors are
-- swallowed by read_tsv() -- by design, an empty rows table just means
-- "nothing to overlay".
function M.load(shared_dir)
  M.path = M.path_for(shared_dir)
  local rows = read_tsv(M.path)
  if not rows then
    M.index, M.keys, M.loaded = {}, {}, false
    return false
  end
  M.index, M.keys = build_index(rows)
  M.loaded = true
  return true
end

-- Look up the entry for a buffer match (case-insensitive comparison was done
-- at index build time, so the caller should already have a lowercased key).
function M.get(lower_phrase)
  return M.index[lower_phrase]
end

return M
