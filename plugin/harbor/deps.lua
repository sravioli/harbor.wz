---@module "harbor.deps"
---@author sravioli
---@license GNU-GPLv2

---Dependency loader. Prefers modules already on `package.path` (local dev
---checkouts, specs) and falls back to `wezterm.plugin.require`.

local wezterm = require "wezterm"

---@class Harbor.Deps
---@field warp   Warp.Api
---@field memo   table
---@field log    table
---@field warden Warden
---@field sigil  table|nil  Optional: icons in the picker.
---@field ribbon table|nil  Optional: formatted picker labels.
local M = {}

local URL = "https://github.com/sravioli/%s.wz"

---@param module string
---@param name   string
---@param optional? boolean
---@return table|nil
local function require_plugin(module, name, optional)
  local ok, plugin = pcall(require, module)
  if ok and plugin then
    return plugin
  end

  ok, plugin = pcall(wezterm.plugin.require, URL:format(name))
  if ok and plugin then
    return plugin
  end

  if optional then
    wezterm.log_warn(("[harbor] optional dependency %s unavailable: %s"):format(name, plugin))
    return nil
  end
  error(("[harbor] unable to load dependency %s: %s"):format(name, tostring(plugin)))
end

M.warp = require_plugin("warp.api", "warp")
M.memo = require_plugin("memo.api", "memo")
M.warden = require_plugin("warden.api", "warden")
M.sigil = require_plugin("sigil.api", "sigil", true)
M.log = M.warp.log
M.ribbon = M.warp.ribbon

return M
