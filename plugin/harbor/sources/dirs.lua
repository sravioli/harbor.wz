---@module "harbor.sources.dirs"
---@author sravioli
---@license GNU-GPLv3

---Statically configured directories (`sources.dirs.paths`).

local util = require "harbor.util"

local M = {}

---@param opts table `sources.dirs`
---@return harbor.Entry[]
function M.collect(opts)
  local out = {}
  for _, p in ipairs(opts.paths) do
    local clean = util.clean_path(p)
    if clean and util.is_dir(clean) then
      out[#out + 1] = { kind = "dir", source = "dirs", path = clean }
    end
  end
  return out
end

return M
