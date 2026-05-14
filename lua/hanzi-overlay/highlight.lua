-- Two highlight groups for the inline overlay text:
--   HanziOverlay     -- the default (dim, "I've seen this before")
--   HanziOverlayNew  -- distinct, only used when gate_integration is on and the
--                       hanzi is not yet in hanzi-gate's state.words.
--
-- Re-applied on `ColorScheme` because many themes clear or redefine groups on
-- switch, and our defaults get clobbered otherwise.

local M = {}

M.group = "HanziOverlay"
M.new_group = "HanziOverlayNew"

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
end

function M.setup(hl_cfg)
  apply(hl_cfg)
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("HanziOverlayColors", { clear = true }),
    callback = function() apply(hl_cfg) end,
  })
end

return M
