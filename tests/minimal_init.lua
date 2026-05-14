-- Minimal init for headless runs:
--
--   nvim --headless -u tests/minimal_init.lua \
--     -c 'lua require("hanzi-overlay").setup({})' -c 'qa'
--
-- Puts the repo root on the runtimepath and sources plugin/ so `require` works
-- without the plugin being "installed".

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":h:h")

vim.opt.runtimepath:prepend(root)
vim.opt.swapfile = false

vim.cmd("runtime! plugin/hanzi-overlay.lua")
