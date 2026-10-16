---@module "harbor.sources.workspaces"
---@author sravioli
---@license GNU-GPLv3

---Live mux workspaces.

local wezterm = require "wezterm"

local state = require "harbor.state"
local util = require "harbor.util"

local M = {}

---Best-effort root directory of a live workspace.
---
---Prefers the path harbor opened it with; falls back to the cwd of the
---active pane of the first window in that workspace.
---@param name string
---@param windows table|nil
---@return string|nil
function M.root(name, windows)
  local known = state.workspace_path(name)
  if known then
    return known
  end
  for _, win in ipairs(windows or {}) do
    local ok, ws = pcall(win.get_workspace, win)
    if ok and ws == name then
      local tok, tab = pcall(win.active_tab, win)
      local pane = tok and tab and tab:active_pane()
      return util.pane_cwd(pane)
    end
  end
  return nil
end

---@return harbor.Entry[]
function M.collect()
  local mux = wezterm.mux
  local ok, names = pcall(mux.get_workspace_names)
  if not ok or type(names) ~= "table" then
    return {}
  end
  local wok, windows = pcall(mux.all_windows)
  windows = wok and windows or {}

  local out = {}
  for _, name in ipairs(names) do
    out[#out + 1] = {
      kind = "workspace",
      name = name,
      path = M.root(name, windows),
    }
  end
  return out
end

return M
