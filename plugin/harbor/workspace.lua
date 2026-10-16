---@module "harbor.workspace"
---@author sravioli
---@license GNU-GPLv3

---Workspace operations: open, switch, create, rename/merge, delete, save,
---restore.

local wezterm = require "wezterm"

local config = require "harbor.config"
local deps = require "harbor.deps"
local history = require "harbor.history"
local layout = require "harbor.layout"
local log = require "harbor.logger"
local naming = require "harbor.naming"
local state = require "harbor.state"
local util = require "harbor.util"

local act = wezterm.action
local process = deps.warp.process

local M = {}

-- ── Queries ────────────────────────────────────────────────────────────────

---@return string
function M.active()
  local ok, name = pcall(wezterm.mux.get_active_workspace)
  return ok and name or config.get().default_workspace
end

---@return string[]
function M.names()
  local ok, names = pcall(wezterm.mux.get_workspace_names)
  return ok and names or {}
end

---@param name string
---@return boolean
function M.exists(name)
  for _, n in ipairs(M.names()) do
    if n == name then
      return true
    end
  end
  return false
end

---Mux windows that belong to `name`.
---@param name string
---@return any[]
function M.windows(name)
  local out = {}
  local ok, windows = pcall(wezterm.mux.all_windows)
  for _, win in ipairs(ok and windows or {}) do
    local wok, ws = pcall(win.get_workspace, win)
    if wok and ws == name then
      out[#out + 1] = win
    end
  end
  return out
end

-- ── Switching ──────────────────────────────────────────────────────────────

---Switch the GUI window to an existing workspace.
---@param window any
---@param pane any
---@param name string
function M.switch(window, pane, name)
  local from = M.active()
  if window and pane then
    window:perform_action(act.SwitchToWorkspace { name = name }, pane)
  else
    pcall(wezterm.mux.set_active_workspace, name)
  end
  if from ~= name then
    history.visit(name, from)
    util.emit("workspace.switched", window, pane, { name = name, from = from })
  end
end

---Switch to the previously active workspace.
---@param window any
---@param pane any
---@return boolean
function M.previous(window, pane)
  local prev = history.previous()
  if prev and prev ~= M.active() and M.exists(prev) then
    M.switch(window, pane, prev)
    return true
  end
  util.notify(window, "No previous workspace")
  return false
end

-- ── Creation ───────────────────────────────────────────────────────────────

---Names currently taken, mapped to the path that owns them (or `true`).
---@return table<string, string|true>
local function taken_names()
  local taken = {}
  for _, n in ipairs(M.names()) do
    taken[n] = util.path_key(state.workspace_path(n)) or true
  end
  return taken
end

---Create a workspace (optionally rooted at `root`) and switch to it.
---@param window any
---@param pane any
---@param name string
---@param root? string
---@param opts? { domain?: string, layout?: any }
---@return boolean ok
function M.create(window, pane, name, root, opts)
  opts = opts or {}
  if M.exists(name) then
    M.switch(window, pane, name)
    return true
  end

  local lay = opts.layout
  if lay == nil then
    lay = layout.resolve(root, name)
  else
    lay = layout.load(lay)
  end

  local spawn = layout.first_tab_args(lay, root)
  spawn.workspace = name
  if spawn.cwd and not util.is_dir(spawn.cwd) then
    log:warn("directory does not exist: %s", spawn.cwd)
    spawn.cwd = nil
  end
  if opts.domain and opts.domain ~= "local" then
    spawn.domain = { DomainName = opts.domain }
  end

  local ok, tab, new_pane, mux_window = pcall(wezterm.mux.spawn_window, spawn)
  if not ok or not tab then
    log:error("could not create workspace %s: %s", name, tab)
    util.notify(window, "Could not create workspace " .. name)
    return false
  end
  if root then
    state.set_workspace_path(name, root)
  end
  if lay then
    layout.apply(lay, {
      name = name,
      root = root,
      domain = opts.domain,
      window = mux_window,
      tab = tab,
      pane = new_pane,
    })
  end

  util.emit("workspace.created", window, pane, { name = name, path = root })
  M.switch(window, pane, name)
  return true
end

---Open (switch to or create) the workspace for directory `p`.
---@param window any
---@param pane any
---@param p string
---@param opts? { name?: string, layout?: any }
---@return boolean
function M.open_dir(window, pane, p, opts)
  opts = opts or {}
  local root = util.clean_path(p)
  if not root then
    return false
  end
  local name = opts.name or naming.unique_name(root, taken_names())

  local cfg = config.get().sources.zoxide
  if cfg.enabled and cfg.add_on_open then
    require("harbor.sources.zoxide").add(cfg, root)
  end
  history.visit_dir(root)
  return M.create(window, pane, name, root, opts)
end

---Open a domain as its own workspace (or a tab in the current one).
---@param window any
---@param pane any
---@param domain string
---@return boolean
function M.open_domain(window, pane, domain)
  local how = config.get().sources.domains.action
  if how == "tab" then
    window:perform_action(act.SpawnCommandInNewTab { domain = { DomainName = domain } }, pane)
    return true
  end
  if M.exists(domain) then
    M.switch(window, pane, domain)
    return true
  end
  return M.create(window, pane, domain, nil, { domain = domain, layout = false })
end

-- ── Rename / merge ─────────────────────────────────────────────────────────

---Rename `old` to `new`; merges into `new` when it already exists.
---@param window any
---@param pane any
---@param old string
---@param new string
---@return boolean
function M.rename(window, pane, old, new)
  new = new and new:gsub("^%s+", ""):gsub("%s+$", "") or ""
  if new == "" or new == old then
    return false
  end
  local merged = M.exists(new)
  if merged then
    for _, win in ipairs(M.windows(old)) do
      pcall(win.set_workspace, win, new)
    end
  else
    local ok, err = pcall(wezterm.mux.rename_workspace, old, new)
    if not ok then
      log:error("rename failed: %s", err)
      return false
    end
  end
  history.rename(old, new)
  state.rename_workspace(old, new)
  local store = require "harbor.session.store"
  if not merged and store.exists(old) then
    store.rename(old, new)
  end
  if M.active() == new and window and pane then
    window:perform_action(act.SwitchToWorkspace { name = new }, pane)
  end
  util.emit("workspace.renamed", window, pane, { from = old, to = new, merged = merged })
  return true
end

-- ── Delete ─────────────────────────────────────────────────────────────────

---Close every pane of workspace `name`. Switches away first when needed.
---@param window any
---@param pane any
---@param name string
---@return boolean
function M.close(window, pane, name)
  if not M.exists(name) then
    return false
  end
  if M.active() == name then
    local target = history.previous()
    if not target or target == name or not M.exists(target) then
      target = nil
      for _, n in ipairs(M.names()) do
        if n ~= name then
          target = n
          break
        end
      end
    end
    if not target then
      util.notify(window, "Cannot close the only workspace")
      return false
    end
    M.switch(window, pane, target)
  end

  local exe = util.wezterm_exe()
  local count = 0
  for _, win in ipairs(M.windows(name)) do
    local tok, tabs = pcall(win.tabs, win)
    for _, tab in ipairs(tok and tabs or {}) do
      local pok, panes = pcall(tab.panes, tab)
      for _, p in ipairs(pok and panes or {}) do
        local ok = process.run(
          { exe, "cli", "kill-pane", "--pane-id", tostring(p:pane_id()) },
          { resolve = false }
        )
        if ok then
          count = count + 1
        end
      end
    end
  end
  history.forget(name)
  state.set_workspace_path(name, nil)
  util.emit("workspace.closed", window, pane, { name = name, panes = count })
  return true
end

-- ── Sessions ───────────────────────────────────────────────────────────────

---Save workspace `name` (default: active).
---@param window any
---@param pane any
---@param name? string
---@param opts? { quiet?: boolean }
---@return boolean
function M.save(window, pane, name, opts)
  name = name or M.active()
  local capture = require "harbor.session.capture"
  local store = require "harbor.session.store"
  local doc, err = capture.workspace(name)
  local ok = doc ~= nil
  if doc then
    ok, err = store.write(doc)
  end
  if not ok then
    store.report("save " .. name, err)
    util.notify(window, "Save failed: " .. tostring(err))
    return false
  end
  state.invalidate "src:saved"
  if not (opts and opts.quiet) then
    util.notify(window, "Saved " .. name)
  end
  util.emit("session.saved", window, pane, { name = name })
  return true
end

---Restore saved session `name` and switch to it.
---@param window any
---@param pane any
---@param name string
---@return boolean
function M.restore(window, pane, name)
  if M.exists(name) then
    M.switch(window, pane, name)
    return true
  end
  local store = require "harbor.session.store"
  local doc, err = store.read(name)
  if not doc then
    store.report("restore " .. name, err)
    util.notify(window, "Restore failed: " .. tostring(err))
    return false
  end
  local ok, rerr = require("harbor.session.restore").workspace(doc)
  if not ok then
    store.report("restore " .. name, rerr)
    return false
  end
  util.emit("session.restored", window, pane, { name = name })
  M.switch(window, pane, name)
  return true
end

---Delete saved session `name`.
---@param window any
---@param pane any
---@param name string
---@return boolean
function M.forget(window, pane, name)
  local store = require "harbor.session.store"
  local ok, err = store.delete(name)
  if not ok then
    store.report("delete " .. name, err)
    return false
  end
  util.emit("session.deleted", window, pane, { name = name })
  return true
end

return M
