-- Configuration: built-in defaults plus a deep-merge of the user's setup() table.
--
-- Stored as a module-level table because every other module needs read access
-- and setup() runs once at startup; threading a config object through scanner /
-- overlay / watcher / treesitter would just be noise.

local M = {}

M.defaults = {
  -- Filetypes where overlays activate. Anything not in this list is ignored.
  filetypes = { "tex", "markdown" },

  -- How many overlays to draw per buffer:
  --   "every"     -- every match (loud; useful when learning a new word set)
  --   "paragraph" -- each distinct gloss at most once per paragraph (default)
  --   "buffer"    -- each distinct gloss at most once in the whole buffer
  density = "paragraph",

  -- Shared directory with hanzi-gate.nvim. We read glosses.tsv from here.
  shared_data_dir = "~/.config/nvim/hanzi-immersion",

  -- Initial per-buffer display mode. `vim.b.hanzi_overlay_mode` overrides this
  -- once the user starts toggling.
  --   "hanzi" | "pinyin" | "off"
  default_mode = "hanzi",

  highlight = {
    fg = "#888888",
    italic = false,
    bold = false,
  },

  -- Lowercase both sides before matching. Off only makes sense if your gloss
  -- file deliberately encodes proper-noun casing.
  case_insensitive = true,

  -- Per-source suffix tolerance. After matching a gloss, if the byte at the
  -- end of the match is still part of a word (e.g. matched "energi" with "en"
  -- following), the matcher normally rejects -- which kills basically every
  -- inflected Danish noun: energien, lyset, rummet, kraften, banerne, etc.
  -- A pattern here is consumed greedily after the match, then the boundary is
  -- re-checked. Defaults:
  --   danish  -> "%a?[etrns]+"  optional stem-doubling letter (rum->rummet)
  --                             then one or more of: e t r n s, the bytes that
  --                             make up Danish noun endings.
  --   english -> nil (strict)   "wave" must not match inside "waver".
  -- Set a key to false (or empty string) to disable for that source, or add
  -- your own pattern. Patterns are Lua patterns, applied to lowercased text.
  allow_trailing = {
    danish  = "%a?[etrns]+",
    english = nil,
  },

  -- Hard cap: at most this many extmarks per buffer. Cheap insurance against
  -- accidentally annotating a 50k-line wordlist of your own.
  max_overlays = 500,

  -- Coalesce TextChanged storms; refresh fires this long after the last edit.
  debounce_ms = 300,

  -- Above this line count we stop refreshing automatically; the user can still
  -- :HanziOverlay refresh by hand.
  large_buffer_lines = 10000,

  keymaps = {
    toggle_mode   = "<leader>zh",        -- cycle hanzi -> pinyin -> off
    force_refresh = "<leader>zH",
    disable       = "<leader>z<leader>", -- session-only kill switch
    jump_next     = "]z",                -- next overlay (wraps)
    jump_prev     = "[z",                -- previous overlay (wraps)
  },

  -- LaTeX commands whose `{argument}` is a label/citation/path -- never prose --
  -- and so should not be annotated. Used by both the treesitter and regex paths.
  -- Section / textbf / emph / caption / footnote are deliberately NOT here:
  -- their arguments are real prose and were the reason 1000-line files only
  -- produced a handful of overlays before this list existed.
  latex_skip_commands = {
    "label", "cite", "citep", "citet", "Cite", "Citep", "Citet",
    "ref", "eqref", "pageref", "autoref", "nameref", "Cref", "cref",
    "bibitem", "nocite", "footcite", "parencite", "textcite",
    "url", "href",
    "include", "input", "subfile", "import",
    "usepackage", "RequirePackage", "documentclass",
    "includegraphics", "graphicspath",
    "bibliography", "bibliographystyle", "addbibresource",
    "hypersetup",
  },

  -- Optional bridge to hanzi-gate.nvim. When `enabled = true` the overlay:
  --   1. Records each hanzi the first time it's shown in this nvim session,
  --      appending to <exposure_file> so hanzi-gate can promote frequently-seen
  --      words into its active quiz pool.
  --   2. Marks hanzi not yet in hanzi-gate's state.json with a distinct
  --      highlight (HanziOverlayNew) so brand-new vocabulary stands out.
  -- Both behaviours degrade silently if hanzi-gate isn't installed/loaded.
  -- Default off: zero coupling between the plugins unless the user opts in.
  gate_integration = {
    enabled = false,
    exposure_file = nil, -- nil -> <shared_data_dir>/exposures.json
  },
}

M.options = vim.deepcopy(M.defaults)

-- Recursive merge: scalars and list-like tables from `src` overwrite `dst`;
-- map-like tables are merged key by key. Lists replace wholesale -- a user who
-- sets `filetypes = {"tex"}` means *only* tex, not "tex plus the defaults".
local function deep_merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" and not vim.islist(v) and not vim.islist(dst[k]) then
      deep_merge(dst[k], v)
    else
      dst[k] = v
    end
  end
  return dst
end

function M.setup(opts)
  M.options = deep_merge(vim.deepcopy(M.defaults), opts or {})
  return M.options
end

function M.get()
  return M.options
end

return M
