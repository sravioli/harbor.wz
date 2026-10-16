---@module "harbor.sources.projects"
---@author sravioli
---@license GNU-GPLv3

---Git repositories under configured roots. Uses `fd` when available and a
---depth-limited `wezterm.read_dir` walk otherwise.

local wezterm = require "wezterm"

local deps = require "harbor.deps"
local log = require "harbor.logger"
local util = require "harbor.util"

local process = deps.warp.process

local M = {}

---@param root string|table
---@param default_depth integer
---@return string|nil path, integer depth
local function root_spec(root, default_depth)
  if type(root) == "table" then
    return util.clean_path(root.path), root.max_depth or default_depth
  end
  return util.clean_path(root), default_depth
end

---Build the fd argv for one root.
---@param exe string
---@param root string
---@param depth integer
---@param exclude string[]
---@return string[]
function M.fd_argv(exe, root, depth, exclude)
  local argv = {
    exe,
    "--hidden",
    "--no-ignore",
    "--absolute-path",
    "--color=never",
    "--type=d",
    "--type=f",
    "--prune",
    ("--max-depth=%d"):format(depth + 1),
  }
  for _, ex in ipairs(exclude) do
    argv[#argv + 1] = "--exclude=" .. ex
  end
  argv[#argv + 1] = "^\\.git$"
  argv[#argv + 1] = root
  return argv
end

---Turn fd output (paths ending in `.git`) into repository roots.
---@param text string
---@return string[]
function M.parse_fd(text)
  local out = {}
  for _, line in ipairs(process.lines(text)) do
    local p = util.clean_path(line)
    local repo = p and p:match "^(.*)/%.git$"
    if repo and repo ~= "" then
      out[#out + 1] = repo
    end
  end
  return out
end

---Pure-Lua fallback walk.
---@param root string
---@param depth integer
---@param exclude table<string, true>
---@return string[]
function M.walk(root, depth, exclude)
  local out = {}
  local function visit(dir, level)
    local ok, entries = pcall(wezterm.read_dir, dir)
    if not ok or type(entries) ~= "table" then
      return
    end
    local subdirs = {}
    for _, entry in ipairs(entries) do
      local p = util.clean_path(entry) or entry
      local name = util.basename(p)
      if name == ".git" then
        out[#out + 1] = dir
        return
      end
      if level < depth and not exclude[name] and name:sub(1, 1) ~= "." then
        subdirs[#subdirs + 1] = p
      end
    end
    for _, sub in ipairs(subdirs) do
      if util.is_dir(sub) then
        visit(sub, level + 1)
      end
    end
  end
  visit(root, 0)
  return out
end

---@param opts table `sources.projects`
---@return harbor.Entry[]
function M.collect(opts)
  if #opts.roots == 0 then
    return {}
  end
  local fd = process.which("fd", { path = opts.fd_path }) or process.which "fdfind"
  local exclude_set = {}
  for _, ex in ipairs(opts.exclude) do
    exclude_set[ex] = true
  end

  local seen, out = {}, {}
  local function push(p)
    local key = util.path_key(p)
    if key and not seen[key] then
      seen[key] = true
      out[#out + 1] = { kind = "dir", source = "projects", path = p }
    end
  end

  for _, spec in ipairs(opts.roots) do
    local root, depth = root_spec(spec, opts.max_depth)
    if root then
      if opts.include_roots then
        push(root)
      end
      local repos
      if fd then
        local ok, stdout, stderr =
          process.run(M.fd_argv(fd, root, depth, opts.exclude), { resolve = false })
        if ok then
          repos = M.parse_fd(stdout)
        else
          log:debug("fd failed for %s (%s); using fallback walk", root, stderr)
        end
      end
      repos = repos or M.walk(root, depth, exclude_set)
      table.sort(repos)
      for _, repo in ipairs(repos) do
        push(repo)
      end
    end
  end
  return out
end

return M
