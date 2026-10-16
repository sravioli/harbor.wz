---@module "harbor.sources.saved"
---@author sravioli
---@license GNU-GPLv3

---Saved session files.

local store = require "harbor.session.store"

local M = {}

---@return harbor.Entry[]
function M.collect()
  local out = {}
  for _, s in ipairs(store.list()) do
    out[#out + 1] = { kind = "saved", name = s.name, file = s.file }
  end
  return out
end

return M
