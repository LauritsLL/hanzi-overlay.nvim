-- Filesystem watcher for glosses.tsv. When the file changes we reload the
-- index and re-render every buffer that's currently using the overlay.
--
-- The watcher is set up once during setup() and persists for the session.
-- We watch the parent directory (not the file directly) because some editors
-- write atomically via rename, which destroys file-level fs_event handles --
-- watching the directory and filtering by filename is more robust.

local M = {}

local config = require("hanzi-overlay.config")
local glosses = require("hanzi-overlay.glosses")

local handle = nil
local reload_timer = nil

-- Coalesce a burst of rename + write into a single reload.
local function schedule_reload()
  if reload_timer then
    reload_timer:stop()
    reload_timer:close()
  end
  reload_timer = vim.uv.new_timer()
  reload_timer:start(100, 0, vim.schedule_wrap(function()
    if reload_timer and not reload_timer:is_closing() then
      reload_timer:stop(); reload_timer:close()
    end
    reload_timer = nil

    local ok = glosses.load(config.get().shared_data_dir)
    if not ok then return end
    -- Avoid require-cycle by requiring here.
    require("hanzi-overlay.overlay").refresh_all()
  end))
end

function M.start()
  M.stop()

  local cfg = config.get()
  local dir = vim.fn.expand(cfg.shared_data_dir)
  if vim.fn.isdirectory(dir) == 0 then return end

  handle = vim.uv.new_fs_event()
  if not handle then return end

  local ok = handle:start(dir, {}, vim.schedule_wrap(function(err, filename)
    if err then return end
    if filename == "glosses.tsv" or filename == nil then
      schedule_reload()
    end
  end))
  if not ok then
    handle:close()
    handle = nil
  end
end

function M.stop()
  if handle then
    pcall(function() handle:stop() end)
    pcall(function() handle:close() end)
    handle = nil
  end
  if reload_timer then
    pcall(function() reload_timer:stop() end)
    pcall(function() reload_timer:close() end)
    reload_timer = nil
  end
end

return M
