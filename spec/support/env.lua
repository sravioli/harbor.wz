--- Shared spec environment: fresh mock state, isolated data dir, defaults.

local wezterm = require "wezterm"

local M = {}

-- selene: allow(incorrect_standard_library_use)
local is_win = package.config:sub(1, 1) == "\\"

local counter = 0

---Create a unique temporary directory and return it with forward slashes.
---@return string
function M.tmpdir()
  counter = counter + 1
  local base = (os.getenv "TEMP" or os.getenv "TMPDIR" or "/tmp"):gsub("\\", "/")
  local dir = ("%s/harbor-spec-%d-%d"):format(base, os.time(), counter)
  if is_win then
    os.execute(('mkdir "%s" >NUL 2>&1'):format((dir:gsub("/", "\\"))))
  else
    os.execute(('mkdir -p "%s"'):format(dir))
  end
  return dir
end

---Remove a directory created by `tmpdir`.
---@param dir string
function M.rmdir(dir)
  if is_win then
    os.execute(('rmdir /s /q "%s" >NUL 2>&1'):format((dir:gsub("/", "\\"))))
  else
    os.execute(('rm -rf "%s"'):format(dir))
  end
end

---Reset everything and configure harbor with `opts` (data dir is isolated).
---@param opts? table
---@return string dir
function M.setup(opts)
  wezterm._reset()
  require("harbor.state")._reset()
  require("harbor.history")._reset()
  require("harbor.session.auto")._reset()
  local dir = M.tmpdir()
  if is_win then
    os.execute(('mkdir "%s\\sessions" >NUL 2>&1'):format((dir:gsub("/", "\\"))))
  else
    os.execute(('mkdir -p "%s/sessions"'):format(dir))
  end
  wezterm._dirs[dir] = {}
  wezterm._dirs[dir .. "/sessions"] = {}
  opts = opts or {}
  opts.sessions = opts.sessions or {}
  opts.sessions.dir = dir
  require("harbor.config").setup(opts)
  return dir
end

M.is_win = is_win

return M
