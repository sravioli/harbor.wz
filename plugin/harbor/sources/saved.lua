---@module "harbor.sources.saved"
---@author sravioli
---@license GNU-GPLv2

---Saved session files.

local store = require "harbor.session.store"

local M = {}

---@return harbor.Entry[]
function M.collect()
  local out = {}
  local times = require("harbor.history").saved_times()
  for _, s in ipairs(store.list()) do
    out[#out + 1] = { kind = "saved", name = s.name, file = s.file, saved_at = times[s.name] }
  end
  return out
end

return M
