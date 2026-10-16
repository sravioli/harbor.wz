---@module "harbor.sources.zoxide"
---@author sravioli
---@license GNU-GPLv3

---Directories ranked by zoxide (`zoxide query --list --score`).

local deps = require "harbor.deps"
local log = require "harbor.logger"
local util = require "harbor.util"

local process = deps.warp.process

local M = {}

---@param opts table `sources.zoxide`
---@return string|nil
function M.executable(opts)
  return process.which("zoxide", { path = opts and opts.path })
end

---Parse `zoxide query --list --score` output.
---@param text string
---@param opts { min_score?: number, limit?: integer }
---@return harbor.Entry[]
function M.parse(text, opts)
  local out = {}
  local min = opts.min_score or 0
  local limit = opts.limit or 0
  for _, line in ipairs(process.lines(text)) do
    local score, p = line:match "^%s*([%d%.]+)%s+(.+)$"
    score = tonumber(score)
    if score and p and score >= min then
      out[#out + 1] = { kind = "dir", source = "zoxide", path = util.clean_path(p), score = score }
      if limit > 0 and #out >= limit then
        break
      end
    end
  end
  return out
end

---@param opts table `sources.zoxide`
---@return harbor.Entry[]
function M.collect(opts)
  local exe = M.executable(opts)
  if not exe then
    log:debug "zoxide not found; skipping source"
    return {}
  end
  local ok, stdout, stderr = process.run({ exe, "query", "--list", "--score" }, { resolve = false })
  if not ok then
    log:warn("zoxide query failed: %s", stderr)
    return {}
  end
  return M.parse(stdout, opts)
end

---Tell zoxide about a visited directory (best effort).
---@param opts table `sources.zoxide`
---@param p string
function M.add(opts, p)
  local exe = M.executable(opts)
  if exe and p then
    process.run({ exe, "add", "--", p }, { resolve = false })
  end
end

return M
