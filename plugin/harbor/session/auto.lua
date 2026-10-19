---@module "harbor.session.auto"
---@author sravioli
---@license GNU-GPLv2

---Autosave loop, save-on-focus-lost and restore-on-startup.

local wezterm = require "wezterm"

local config = require "harbor.config"
local history = require "harbor.history"
local log = require "harbor.logger"
local util = require "harbor.util"

local M = {}

local GEN_KEY = "harbor_autosave_generation"

---Last saved structural signature per workspace (this Lua state only).
---@type table<string, string>
local signatures = {}

---Save `name` unless its structure is unchanged since the last autosave.
---@param name string
---@return boolean saved
function M.save_if_changed(name)
  if require("harbor.state").protection(name) then
    log:warn(
      "autosave blocked for protected workspace %s: %s",
      name,
      require("harbor.state").protection(name)
    )
    return false
  end
  local capture = require "harbor.session.capture"
  local sig = capture.signature(name)
  if signatures[name] == sig then
    return false
  end
  local ok = require("harbor.workspace").save(nil, nil, name, { quiet = true })
  if ok then
    signatures[name] = sig
  end
  return ok
end

---Workspaces covered by the autosave scope.
---@return string[]
function M.targets()
  local cfg = config.get().sessions.autosave
  local ws = require "harbor.workspace"
  local exclude = {}
  for _, n in ipairs(cfg.exclude) do
    exclude[n] = true
  end
  local names = cfg.scope == "active" and { ws.active() } or ws.names()
  local out = {}
  for _, n in ipairs(names) do
    if not exclude[n] then
      out[#out + 1] = n
    end
  end
  return out
end

---One autosave pass.
function M.tick(generation)
  for _, name in ipairs(M.targets()) do
    if generation and wezterm.GLOBAL[GEN_KEY] ~= generation then
      return
    end
    util.try("autosave " .. name, M.save_if_changed, name)
  end
end

---Start the periodic loop. Each config evaluation bumps a generation
---counter so loops scheduled by an older evaluation stop on their own.
function M.start()
  local cfg = config.get().sessions.autosave
  local gen = (tonumber(wezterm.GLOBAL[GEN_KEY]) or 0) + 1
  wezterm.GLOBAL[GEN_KEY] = gen
  if not cfg.enabled or not (wezterm.time and wezterm.time.call_after) then
    return
  end

  local function loop()
    if wezterm.GLOBAL[GEN_KEY] ~= gen then
      return
    end
    util.try("autosave", M.tick, gen)
    -- Always reschedule, even if this pass failed.
    if wezterm.GLOBAL[GEN_KEY] == gen then
      util.try("schedule autosave", wezterm.time.call_after, cfg.interval, loop)
    end
  end
  wezterm.time.call_after(cfg.interval, loop)
  log:debug("autosave every %ss", cfg.interval)
end

---Register event handlers. Idempotent within one config evaluation.
function M.register()
  if M._registered then
    M.start()
    return
  end
  M._registered = true
  wezterm.on("window-focus-changed", function(window, _)
    local cfg = config.get().sessions
    if not cfg.autosave.enabled or not cfg.autosave.on_focus_lost then
      return
    end
    if not window:is_focused() then
      local name = window:active_workspace()
      util.try("autosave on focus lost", M.save_if_changed, name)
    end
  end)
  wezterm.on("gui-startup", function()
    local cfg = config.get().sessions
    if not cfg.restore_on_startup then
      return
    end
    local name = cfg.restore_on_startup
    if name == true then
      name = history.current()
    end
    if type(name) ~= "string" then
      return
    end
    local store = require "harbor.session.store"
    local doc, err = store.read(name)
    if not doc then
      log:info("nothing to restore on startup (%s)", err)
      return
    end
    local ok, rerr = require("harbor.session.restore").workspace(doc)
    if ok then
      util.try("activate restored workspace", wezterm.mux.set_active_workspace, name)
    else
      log:warn("startup restore failed: %s", rerr)
    end
  end)

  M.start()
end

---Testing hook.
function M._reset()
  signatures = {}
end

return M
