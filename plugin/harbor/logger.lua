---@module "harbor.logger"
---@author sravioli
---@license GNU-GPLv2

---Shared log.wz instance tagged `harbor`.

local deps = require "harbor.deps"

---@class Harbor.Logger
---@field debug fun(self: Harbor.Logger, msg: string, ...: any)
---@field info  fun(self: Harbor.Logger, msg: string, ...: any)
---@field warn  fun(self: Harbor.Logger, msg: string, ...: any)
---@field error fun(self: Harbor.Logger, msg: string, ...: any)
local log = deps.log.new("harbor", true)

return log
