-- Sourced once at startup. Keep light: register the user command and the
-- FileType bootstrap, let everything else be require()d lazily.

if vim.g.loaded_hanzi_overlay then return end
vim.g.loaded_hanzi_overlay = true

local SUBCOMMANDS = { "refresh", "disable", "enable", "stats", "toggle", "next", "prev" }

vim.api.nvim_create_user_command("HanziOverlay", function(opts)
  local sub = opts.fargs[1]
  local mod = require("hanzi-overlay")
  if sub == nil or sub == "toggle" then
    mod.toggle()
  elseif sub == "refresh" then
    mod.refresh()
  elseif sub == "disable" then
    mod.disable()
  elseif sub == "enable" then
    mod.enable()
  elseif sub == "stats" then
    mod.stats()
  elseif sub == "next" then
    mod.jump_next()
  elseif sub == "prev" then
    mod.jump_prev()
  else
    vim.notify("[hanzi-overlay] unknown subcommand: " .. tostring(sub), vim.log.levels.ERROR)
  end
end, {
  nargs = "?",
  desc = "Hanzi Overlay: toggle (no arg), refresh / disable / enable / stats / next / prev",
  complete = function(arglead)
    return vim.tbl_filter(function(c) return c:find(arglead, 1, true) == 1 end, SUBCOMMANDS)
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("HanziOverlay", { clear = true }),
  callback = function()
    -- Defer one tick so the user has a chance to call setup() in their config
    -- before the first buffer is attached (Lazy.nvim's order isn't guaranteed
    -- when both `ft = ...` and `config = function() ... end` are in play).
    vim.schedule(function()
      local ok, mod = pcall(require, "hanzi-overlay")
      if ok then mod.attach_current_buffer() end
    end)
  end,
})

-- Flush pending passive exposures to disk on nvim exit. Cheap no-op when
-- gate_integration is disabled or nothing has been recorded this session.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("HanziOverlayFlush", { clear = true }),
  callback = function()
    local ok, exposures = pcall(require, "hanzi-overlay.exposures")
    if ok then pcall(exposures.flush) end
  end,
})
