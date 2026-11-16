---@module "harbor.sources.snapshots"
---@author sravioli
---@license GNU-GPLv2

---Saved tab and window snapshots.

local store = require "harbor.session.store"

local M = {}

---@return harbor.Entry[]
function M.collect()
  local out = {}
  for _, kind in ipairs { "tab", "window" } do
    for _, s in ipairs(store.list(kind)) do
      out[#out + 1] = { kind = kind, name = s.name, file = s.file }
    end
  end
  return out
end

return M
