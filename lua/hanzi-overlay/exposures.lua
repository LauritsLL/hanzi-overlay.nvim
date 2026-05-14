-- Tracks "I've passively seen this hanzi" counts for the optional bridge with
-- hanzi-gate.nvim. Each hanzi is counted at most once per nvim session (in
-- `session_seen`) regardless of how many buffers/renders show it -- the slower
-- pace matches "comprehensible input over time" rather than "I refreshed twice."
--
-- Disk shape: { "<hanzi>": { "seen": int, "last_seen": "<iso8601>" } }
-- Writes are coalesced: pending increments stay in memory until flush(), which
-- the plugin entry point calls on VimLeavePre (and which we also invoke after
-- each new addition so a hard crash mid-session doesn't lose everything).

local M = {}

-- Hanzi already counted in this nvim run.
local session_seen = {}
-- Hanzi we've recorded this run but not yet written to disk.
local pending = {}

local function now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function resolve_path(cfg)
  local gi = cfg.gate_integration or {}
  if gi.exposure_file and gi.exposure_file ~= "" then
    return vim.fn.expand(gi.exposure_file)
  end
  return vim.fn.expand(cfg.shared_data_dir) .. "/exposures.json"
end

local function ensure_dir(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
end

local function read_json(path)
  local fd = io.open(path, "r")
  if not fd then return {} end
  local body = fd:read("*a")
  fd:close()
  if not body or body == "" then return {} end
  local ok, decoded = pcall(vim.json.decode, body)
  if not ok or type(decoded) ~= "table" then return {} end
  return decoded
end

local function write_atomic(path, tbl)
  ensure_dir(path)
  local ok, encoded = pcall(vim.json.encode, tbl)
  if not ok then return false end
  local tmp = path .. ".tmp"
  local fd = io.open(tmp, "w")
  if not fd then return false end
  fd:write(encoded)
  fd:close()
  return os.rename(tmp, path) and true or false
end

-- Mark `hanzi` as exposed (no-op if already seen this session, or if the bridge
-- isn't enabled). Returns true if a new entry was queued for write.
function M.record(hanzi, cfg)
  cfg = cfg or require("hanzi-overlay.config").get()
  local gi = cfg.gate_integration or {}
  if not gi.enabled then return false end
  if type(hanzi) ~= "string" or hanzi == "" then return false end
  if session_seen[hanzi] then return false end
  session_seen[hanzi] = true
  pending[hanzi] = true
  return true
end

-- Persist pending increments. Called from VimLeavePre and (optionally) after
-- each new addition. Safe to call when nothing is pending -- it's a no-op then.
function M.flush(cfg)
  if next(pending) == nil then return true end
  cfg = cfg or require("hanzi-overlay.config").get()
  local gi = cfg.gate_integration or {}
  if not gi.enabled then
    pending = {}
    return true
  end
  local path = resolve_path(cfg)
  local data = read_json(path)
  local now = now_iso()
  for h in pairs(pending) do
    local e = data[h]
    if type(e) ~= "table" then e = { seen = 0 } end
    e.seen = (tonumber(e.seen) or 0) + 1
    e.last_seen = now
    data[h] = e
  end
  local ok = write_atomic(path, data)
  if ok then pending = {} end
  return ok
end

-- Test/debug helper: clear the in-memory dedup set so a fresh "session" can be
-- simulated without restarting nvim.
function M._reset_session()
  session_seen = {}
  pending = {}
end

function M.path(cfg)
  cfg = cfg or require("hanzi-overlay.config").get()
  return resolve_path(cfg)
end

return M
