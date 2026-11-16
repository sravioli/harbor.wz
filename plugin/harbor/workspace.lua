---@module "harbor.workspace"
---@author sravioli
---@license GNU-GPLv2

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
---@return any[]|nil, string|nil
function M.windows(name)
  local out = {}
  local ok, windows = pcall(wezterm.mux.all_windows)
  if not ok then
    return nil, "cannot enumerate workspace windows: " .. tostring(windows)
  end
  for _, win in ipairs(windows) do
    local wok, ws = pcall(win.get_workspace, win)
    if not wok then
      return nil, "cannot inspect workspace: " .. tostring(ws)
    end
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
---@return boolean
function M.switch(window, pane, name)
  local from = M.active()
  local ok, err
  if window and pane then
    ok, err = pcall(window.perform_action, window, act.SwitchToWorkspace { name = name }, pane)
  else
    ok, err = pcall(wezterm.mux.set_active_workspace, name)
  end
  if not ok then
    log:error("workspace switch failed: %s", err)
    util.notify(window, "Cannot switch to workspace " .. name)
    return false
  end
  if from ~= name then
    history.visit(name, from)
    util.emit("workspace.switched", window, pane, { name = name, from = from })
  end
  return true
end

---Switch to the previously active workspace.
---@param window any
---@param pane any
---@return boolean
function M.previous(window, pane)
  local prev = history.previous()
  if prev and prev ~= M.active() and M.exists(prev) then
    return M.switch(window, pane, prev)
  end
  util.notify(window, "No previous workspace")
  return false
end

---Switch to the next (`step = 1`) or previous (`step = -1`) live workspace in
---alphabetical order, wrapping around.
---@param window any
---@param pane any
---@param step integer
---@return boolean
function M.cycle(window, pane, step)
  local names = {}
  for _, n in ipairs(M.names()) do
    names[#names + 1] = n
  end
  table.sort(names)
  if #names < 2 then
    util.notify(window, "No other workspace")
    return false
  end
  local active, index = M.active(), 0
  for i, n in ipairs(names) do
    if n == active then
      index = i
      break
    end
  end
  return M.switch(window, pane, names[(index - 1 + step) % #names + 1])
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
    return M.switch(window, pane, name)
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
  return M.switch(window, pane, name)
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
    return M.switch(window, pane, domain)
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
  local store = require "harbor.session.store"
  if not merged and store.exists(old) and store.exists(new) then
    util.notify(window, "Saved session already exists: " .. new)
    return false
  end
  if merged then
    local windows, windows_err = M.windows(old)
    if not windows or #windows == 0 then
      log:error("merge failed: %s", windows_err or "no source windows")
      return false
    end
    for _, win in ipairs(windows) do
      local ok, err = pcall(win.set_workspace, win, new)
      if not ok then
        log:error("merge incomplete: %s", err)
        state.protect(new, "workspace merge incomplete")
        state.protect(old, "workspace merge incomplete")
        util.notify(window, "Workspace merge incomplete: " .. tostring(err))
        return false
      end
    end
  else
    local ok, err = pcall(wezterm.mux.rename_workspace, old, new)
    if not ok then
      log:error("rename failed: %s", err)
      return false
    end
  end
  if not merged and store.exists(old) then
    local ok, err = store.rename(old, new)
    if not ok then
      log:error("saved session rename failed: %s", err)
      util.notify(window, "Workspace renamed, but saved session rename failed: " .. tostring(err))
      history.rename(old, new)
      state.rename_workspace(old, new)
      return false
    end
  end
  state.invalidate("session:" .. old)
  state.invalidate("session:" .. new)
  history.rename(old, new)
  if merged then
    state.set_workspace_path(old, nil)
    if state.protection(old) then
      state.protect(new, state.protection(old))
      state.unprotect(old)
    end
  else
    state.rename_workspace(old, new)
  end
  if M.active() == new and window and pane then
    window:perform_action(act.SwitchToWorkspace { name = new }, pane)
  end
  util.emit("workspace.renamed", window, pane, { from = old, to = new, merged = merged })
  return true
end

-- ── Delete ─────────────────────────────────────────────────────────────────

---Kill panes by ID through `wezterm cli`.
---@param ids (string|integer)[]
---@return integer killed, string[] errors
function M.kill_panes(ids)
  local exe = util.wezterm_exe()
  local count, errors = 0, {}
  for _, id in ipairs(ids) do
    id = tostring(id)
    local killed, _, err = process.run(
      { exe, "cli", "--no-auto-start", "kill-pane", "--pane-id", id },
      { resolve = false }
    )
    if killed then
      count = count + 1
    else
      errors[#errors + 1] = id .. ": " .. tostring(err)
    end
  end
  return count, errors
end

---Close every pane of workspace `name`. Switches away first when needed.
---@param window any
---@param pane any
---@param name string
---@return boolean
function M.close(window, pane, name)
  if not M.exists(name) then
    return false
  end
  local targets = {}
  local ok, windows = pcall(wezterm.mux.all_windows)
  if not ok then
    util.notify(window, "Cannot enumerate workspace windows")
    return false
  end
  for _, win in ipairs(windows) do
    local wok, ws = pcall(win.get_workspace, win)
    if not wok then
      log:error("cannot inspect workspace: %s", ws)
      return false
    end
    if ws == name then
      local tok, tabs = pcall(win.tabs, win)
      if not tok then
        log:error("cannot enumerate tabs: %s", tabs)
        return false
      end
      for _, tab in ipairs(tabs) do
        local pok, panes = pcall(tab.panes, tab)
        if not pok then
          log:error("cannot enumerate panes: %s", panes)
          return false
        end
        for _, target in ipairs(panes) do
          local id_ok, id = pcall(target.pane_id, target)
          if not id_ok or type(id) ~= "number" or id < 0 or id % 1 ~= 0 then
            log:error("cannot inspect pane ID: %s", id)
            return false
          end
          targets[#targets + 1] = tostring(id)
        end
      end
    end
  end
  if #targets == 0 then
    util.notify(window, "No panes found for " .. name)
    return false
  end
  local target
  if M.active() == name then
    target = history.previous()
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
  end
  if config.get().sessions.save_on_close then
    if state.protection(name) then
      -- A partial snapshot must not replace the good one on disk.
      log:warn("not saving protected workspace %s before close: %s", name, state.protection(name))
    elseif not M.save(window, pane, name, { quiet = true }) then
      util.notify(window, "Close aborted: could not save " .. name)
      return false
    end
  end
  if target and not M.switch(window, pane, target) then
    return false
  end

  local count, errors = M.kill_panes(targets)
  if #errors > 0 then
    if count > 0 then
      state.protect(name, "workspace close incomplete")
    end
    log:error("close incomplete for %s: %s", name, table.concat(errors, "; "))
    util.notify(window, "Close incomplete for " .. name)
    return false
  end
  history.forget(name)
  state.set_workspace_path(name, nil)
  state.unprotect(name)
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
  if opts and opts.quiet and state.protection(name) then
    log:warn("autosave blocked for protected workspace %s: %s", name, state.protection(name))
    return false
  end
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
  state.invalidate("session:" .. name)
  state.unprotect(name)
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
---@param opts? { backup?: boolean }
---@return boolean, string|nil
function M.restore(window, pane, name, opts)
  if M.exists(name) then
    return M.switch(window, pane, name)
  end
  local store = require "harbor.session.store"
  local doc, err = store.read(name, opts)
  if not doc then
    store.report("restore " .. name, err)
    util.notify(window, "Restore failed: " .. tostring(err))
    return false, err
  end
  local ok, rerr = require("harbor.session.restore").workspace(doc, { rollback = true })
  if not ok then
    store.report("restore " .. name, rerr)
    util.notify(window, "Restore incomplete: " .. tostring(rerr))
    return false, rerr
  end
  util.emit("session.restored", window, pane, { name = name })
  return M.switch(window, pane, name)
end

---Save every live workspace except `sessions.autosave.exclude`. Protected
---(partially restored or closed) workspaces are skipped, not overwritten.
---@param window any
---@param pane any
---@return boolean ok, string[] failed
function M.save_all(window, pane)
  local exclude = {}
  for _, n in ipairs(config.get().sessions.autosave.exclude) do
    exclude[n] = true
  end
  local failed = {}
  for _, name in ipairs(M.names()) do
    if exclude[name] then
      log:debug("save all: %s excluded", name)
    elseif state.protection(name) then
      log:warn("save all: skipping protected %s: %s", name, state.protection(name))
    elseif not M.save(window, pane, name, { quiet = true }) then
      failed[#failed + 1] = name
    end
  end
  return #failed == 0, failed
end

---Save all workspaces, then quit. Refuses to quit when a save fails.
---@param window any
---@param pane any
---@return boolean
function M.quit(window, pane)
  local ok, failed = M.save_all(window, pane)
  if not ok then
    util.notify(window, "Not quitting; save failed for " .. table.concat(failed, ", "))
    return false
  end
  window:perform_action(act.QuitApplication, pane)
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
  state.invalidate("session:" .. name)
  util.emit("session.deleted", window, pane, { name = name })
  return true
end

-- ── Window and tab snapshots ───────────────────────────────────────────────

---@param window any GuiWindow
---@return any|nil MuxWindow
local function mux_window(window)
  local ok, win = pcall(function()
    return window:mux_window()
  end)
  return ok and win or nil
end

---Snapshot the window (`kind = "window"`) or the active tab (`"tab"`).
---Defaults the name to the window/tab title.
---@param kind "window"|"tab"
---@param window any
---@param pane any
---@param name? string
---@return boolean
function M.save_snapshot(kind, window, pane, name)
  local capture = require "harbor.session.capture"
  local store = require "harbor.session.store"
  local win = window and mux_window(window)
  local tab
  if kind == "tab" then
    local ok, t = pcall(function()
      return pane:tab()
    end)
    tab = ok and t or nil
  end
  local source = kind == "tab" and tab or win
  if not source then
    util.notify(window, "Nothing to save")
    return false
  end
  if not name or name == "" then
    local ok, title = pcall(source.get_title, source)
    name = ok and title or ""
  end
  if name == "" then
    util.notify(window, "Save failed: a name is required")
    return false
  end

  local doc, err
  if kind == "tab" then
    doc, err = capture.tab_doc(name, tab)
  else
    doc, err = capture.window_doc(name, win)
  end
  local ok = doc ~= nil
  if doc then
    ok, err = store.write(doc, kind)
  end
  if not ok then
    store.report("save " .. kind .. " " .. name, err)
    util.notify(window, "Save failed: " .. tostring(err))
    return false
  end
  util.notify(window, ("Saved %s %s"):format(kind, name))
  util.emit("session.saved", window, pane, { name = name, kind = kind })
  return true
end

---Load a saved tab into `window`, or a saved window into the active
---workspace. Never touches the workspace session of the same name.
---@param kind "window"|"tab"
---@param window any
---@param pane any
---@param name string
---@return boolean, string|nil
function M.load_snapshot(kind, window, pane, name)
  local store = require "harbor.session.store"
  local doc, err = store.read(name, { kind = kind })
  if not doc then
    store.report(("load %s %s"):format(kind, name), err)
    util.notify(window, "Load failed: " .. tostring(err))
    return false, err
  end
  local win = kind == "tab" and window and mux_window(window) or nil
  if kind == "tab" and not win then
    util.notify(window, "Load failed: no window to add the tab to")
    return false, "no window"
  end
  local ok, rerr = require("harbor.session.restore").snapshot(kind, doc, win, M.active())
  if not ok then
    store.report(("load %s %s"):format(kind, name), rerr)
    util.notify(window, "Load failed: " .. tostring(rerr))
    return false, rerr
  end
  util.emit("session.restored", window, pane, { name = name, kind = kind })
  return true
end

---Delete a saved tab or window snapshot.
---@param kind "window"|"tab"
---@param window any
---@param pane any
---@param name string
---@return boolean
function M.forget_snapshot(kind, window, pane, name)
  local store = require "harbor.session.store"
  local ok, err = store.delete(name, kind)
  if not ok then
    store.report(("delete %s %s"):format(kind, name), err)
    return false
  end
  util.emit("session.deleted", window, pane, { name = name, kind = kind })
  return true
end

return M
