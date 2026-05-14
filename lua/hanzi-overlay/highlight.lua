-- Highlight groups for the inline overlay text:
--   HanziOverlay      -- fallback when hanzi-gate isn't installed (no SRS data)
--   HanziOverlayNew   -- legacy: only used when gate_integration is on AND the
--                        old binary new/known distinction is in play. Kept for
--                        backward compatibility with users overriding it.
--   HanziOverlaySrs1  -- "fresh"    : correct < config.srs_thresholds.improving
--   HanziOverlaySrs2  -- "improving": improving <= correct < mastered
--   HanziOverlaySrs3  -- "mastered" : correct >= config.srs_thresholds.mastered
--
-- The SRS gradient lives in the warm-orange family so the buffer doesn't end
-- up rainbow-coloured. Bright shades pull the eye to words you still need to
-- learn; muted shades fade words you've earned.
--
-- Re-applied on `ColorScheme` because many themes clear or redefine groups on
-- switch, and our defaults get clobbered otherwise.

local M = {}

M.group     = "HanziOverlay"
M.new_group = "HanziOverlayNew"
M.fresh     = "HanziOverlaySrs1"
M.improving = "HanziOverlaySrs2"
M.mastered  = "HanziOverlaySrs3"

local function apply(hl_cfg)
  hl_cfg = hl_cfg or {}
  local attrs = { italic = hl_cfg.italic or false, bold = hl_cfg.bold or false }
  if vim.o.termguicolors and hl_cfg.fg then
    attrs.fg = hl_cfg.fg
  else
    -- 8 = bright black in most terminal palettes -> the closest "dim" we
    -- can get without truecolor.
    attrs.ctermfg = 8
  end
  vim.api.nvim_set_hl(0, M.group, attrs)

  -- "New" words: stand out without being garish. The user can override via
  -- highlight.new = { fg = "#...", bold = true } in their setup() table.
  local new_cfg = hl_cfg.new or {}
  local new_attrs = {
    italic = new_cfg.italic == nil and true or new_cfg.italic,
    bold   = new_cfg.bold   == nil and false or new_cfg.bold,
  }
  if vim.o.termguicolors and (new_cfg.fg or true) then
    new_attrs.fg = new_cfg.fg or "#e0af68"  -- warm amber, mostly readable on dark+light
  else
    new_attrs.ctermfg = new_cfg.ctermfg or 11  -- bright yellow
  end
  vim.api.nvim_set_hl(0, M.new_group, new_attrs)

  -- SRS gradient. The fg of each bucket is overridable via
  -- highlight.srs = { fresh = "#...", improving = "#...", mastered = "#..." }
  -- in setup(). Bold/italic follow the main group so the gradient stays
  -- visually coherent.
  local srs_cfg = hl_cfg.srs or {}
  local srs_palette = {
    [M.fresh]     = { fg = srs_cfg.fresh     or "#fb923c", cterm = 208 }, -- vivid orange
    [M.improving] = { fg = srs_cfg.improving or "#e0af68", cterm = 11  }, -- warm amber
    [M.mastered]  = { fg = srs_cfg.mastered  or "#a8896b", cterm = 8   }, -- muted amber
  }
  for group, spec in pairs(srs_palette) do
    local sa = { italic = hl_cfg.italic or false, bold = hl_cfg.bold or false }
    if vim.o.termguicolors then sa.fg = spec.fg else sa.ctermfg = spec.cterm end
    vim.api.nvim_set_hl(0, group, sa)
  end
end

function M.setup(hl_cfg)
  apply(hl_cfg)
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("HanziOverlayColors", { clear = true }),
    callback = function() apply(hl_cfg) end,
  })
end

return M
