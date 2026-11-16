---@module "harbor.api"
---@author sravioli
---@license GNU-GPLv2

---Public API for harbor.wz.
---
---```lua
---local harbor = wezterm.plugin.require "https://github.com/sravioli/harbor.wz"
---harbor.setup { sources = { projects = { roots = { "~/dev" } } } }
---harbor.apply_to_config(config)
---table.insert(config.keys, { key = "s", mods = "LEADER", action = harbor.action.pick() })
---```
---
---Nothing here spawns processes or touches the disk at require/setup time;
---all work happens when an action runs.

local wezterm = require "wezterm"

local config = require "harbor.config"
local state = require "harbor.state"

---@class Harbor
local M = {}

M.VERSION = "0.2.0"

---Events emitted as `(window, pane, payload)`.
M.events = {
  "harbor.workspace.switching",
  "harbor.workspace.switched",
  "harbor.workspace.created",
  "harbor.workspace.renamed",
  "harbor.workspace.closed",
  "harbor.workspace.forked",
  "harbor.session.saved",
  "harbor.session.restored",
  "harbor.session.deleted",
  "harbor.session.branch_mismatch",
  "harbor.picker.opened",
  "harbor.picker.selected",
  "harbor.picker.canceled",
}

---Install an optional picker host adapter. No Chord dependency is required.
---Call before apply_to_config(), including on config reload.
---@param adapter? { keys?: table[], open: function }
function M.set_picker_adapter(adapter)
  require("harbor.picker").set_adapter(adapter)
end

---@type boolean
local registered = false

---Configure harbor. Safe to call on every config reload.
---@param opts? table
---@return table config
function M.setup(opts)
  local cfg = config.setup(opts)
  registered = true
  require("harbor.session.auto").register()
  return cfg
end

---Register harbor's key table (needed for in-picker actions).
---
---Does not add any key bindings. Bind `harbor.action.*` yourself.
---@param c table WezTerm config builder/table
---@return table c
function M.apply_to_config(c)
  if not registered then
    M.setup()
  end
  local name = config.get().picker.key_table
  c.key_tables = c.key_tables or {}
  c.key_tables[name] = require("harbor.picker").key_table()
  state.key_table_ready = true
  return c
end

---Whether workspace `name` has a saved session. Cached for 30 s and
---refreshed on save, delete and rename, so it is cheap enough to call from
---`update-status`.
---@param name string
---@return boolean
function M.has_session(name)
  if type(name) ~= "string" or name == "" then
    return false
  end
  return state.cached("session:" .. name, 30, function()
    return require("harbor.session.store").exists(name)
  end) == true
end

-- ── Imperative API (inside callbacks) ──────────────────────────────────────

---Open the picker.
---@param window any
---@param pane any
---@param opts? { kinds?: string[]|table<string, boolean>, title?: string, actions?: boolean }
function M.pick(window, pane, opts)
  opts = opts or {}
  if opts.kinds and opts.kinds[1] then
    local set = {}
    for _, k in ipairs(opts.kinds) do
      set[k] = true
    end
    opts.kinds = set
  end
  require("harbor.picker").open(window, pane, opts)
end

---@return harbor.Entry[]
function M.list(opts)
  return require("harbor.sources").list(opts)
end

function M.switch(window, pane, name)
  return require("harbor.workspace").switch(window, pane, name)
end

function M.open_dir(window, pane, path, opts)
  return require("harbor.workspace").open_dir(window, pane, path, opts)
end

function M.create(window, pane, name, root, opts)
  return require("harbor.workspace").create(window, pane, name, root, opts)
end

function M.rename(window, pane, old, new)
  return require("harbor.workspace").rename(window, pane, old, new)
end

function M.close(window, pane, name)
  return require("harbor.workspace").close(window, pane, name)
end

function M.previous(window, pane)
  return require("harbor.workspace").previous(window, pane)
end

---Switch to the next (`step = 1`) or previous (`step = -1`) workspace in
---alphabetical order, wrapping around. `previous()` is the last-visited toggle.
---@param step integer
function M.cycle(window, pane, step)
  return require("harbor.workspace").cycle(window, pane, step)
end

---Duplicate the active workspace's layout into a new workspace and switch to
---it. `name` defaults to `<active>-fork`. Nothing is saved to disk.
---@return boolean, string|nil
function M.fork(window, pane, name)
  return require("harbor.workspace").fork(window, pane, name)
end

function M.save(window, pane, name)
  return require("harbor.workspace").save(window, pane, name)
end

function M.restore(window, pane, name, opts)
  return require("harbor.workspace").restore(window, pane, name, opts)
end

---Save every live workspace, then quit WezTerm. Refuses to quit on failure.
function M.quit(window, pane)
  return require("harbor.workspace").quit(window, pane)
end

---Save the active tab as a snapshot (`name` defaults to its title).
function M.save_tab(window, pane, name)
  return require("harbor.workspace").save_snapshot("tab", window, pane, name)
end

---Save the window as a snapshot (`name` defaults to its title).
function M.save_window(window, pane, name)
  return require("harbor.workspace").save_snapshot("window", window, pane, name)
end

---Add a saved tab snapshot to the current window.
---@return boolean, string|nil
function M.load_tab(window, pane, name)
  return require("harbor.workspace").load_snapshot("tab", window, pane, name)
end

---Open a saved window snapshot in the active workspace.
---@return boolean, string|nil
function M.load_window(window, pane, name)
  return require("harbor.workspace").load_snapshot("window", window, pane, name)
end

---Saved tab or window snapshots on disk.
---@param kind "tab"|"window"
---@return { name: string, file: string }[]
function M.snapshots(kind)
  return require("harbor.session.store").list(kind)
end

---Save every live workspace (protected and excluded ones are skipped).
---@return boolean ok, string[] failed
function M.save_all(window, pane)
  return require("harbor.workspace").save_all(window, pane)
end

function M.delete_session(window, pane, name)
  return require("harbor.workspace").forget(window, pane, name)
end

---Saved sessions on disk.
---@return { name: string, file: string }[]
function M.sessions()
  return require("harbor.session.store").list()
end

---Drop cached source results (zoxide, projects, saved).
function M.refresh()
  state.invalidate()
end

-- ── Key assignments ────────────────────────────────────────────────────────

---@param fn fun(window: any, pane: any)
---@return any
local function cb(fn)
  return wezterm.action_callback(function(window, pane)
    local ok, err = pcall(fn, window, pane)
    if not ok then
      require("harbor.logger"):error("action failed: %s", err)
    end
  end)
end

local function prompt(description, initial, fn)
  return cb(function(window, pane)
    local initial_value = initial
    if type(initial) == "function" then
      initial_value = initial(window) -- may be nil: never fall back to the function
    end
    window:perform_action(
      wezterm.action.PromptInputLine {
        description = description,
        initial_value = initial_value,
        action = wezterm.action_callback(function(w, p, line)
          if line and line ~= "" then
            fn(w, p, line)
          end
        end),
      },
      pane
    )
  end)
end

---Key actions. Bind them in `config.keys`, for example
---`harbor.action.pick()`.
---@class Harbor.Actions
M.action = {}

---Picker over all (or selected) sources.
---@param opts? { kinds?: string[], title?: string, actions?: boolean }
function M.action.pick(opts)
  return cb(function(window, pane)
    M.pick(
      window,
      pane,
      opts and { kinds = opts.kinds, title = opts.title, actions = opts.actions }
    )
  end)
end

function M.action.workspaces()
  return M.action.pick { kinds = { "workspace" }, title = "Workspaces" }
end

function M.action.projects()
  return M.action.pick { kinds = { "dir" }, title = "Projects" }
end

function M.action.sessions()
  return M.action.pick { kinds = { "saved", "workspace" }, title = "Sessions" }
end

function M.action.domains()
  return M.action.pick { kinds = { "domain" }, title = "Domains", actions = false }
end

function M.action.previous()
  return cb(M.previous)
end

---Next workspace in alphabetical order, wrapping.
function M.action.next()
  return cb(function(window, pane)
    M.cycle(window, pane, 1)
  end)
end

---Previous workspace in alphabetical order, wrapping (not the last-visited toggle).
function M.action.prev()
  return cb(function(window, pane)
    M.cycle(window, pane, -1)
  end)
end

---Prompt for a name (default `<active>-fork`) and fork the active workspace.
function M.action.fork()
  return prompt("Fork workspace as", function(window)
    return window:active_workspace() .. "-fork"
  end, function(w, p, name)
    M.fork(w, p, name)
  end)
end

---Save the active workspace.
function M.action.save()
  return cb(function(window, pane)
    M.save(window, pane)
  end)
end

---Restore a saved session by name (prompted).
function M.action.restore()
  return prompt("Restore session", nil, function(w, p, name)
    M.restore(w, p, name)
  end)
end

---Prompt for a name (default: the active tab title) and save the tab.
function M.action.save_tab()
  return prompt("Save tab as", function(window)
    local ok, title = pcall(function()
      return window:active_tab():get_title()
    end)
    return ok and title or nil
  end, function(w, p, name)
    M.save_tab(w, p, name)
  end)
end

---Prompt for a name (default: the window title) and save the window.
function M.action.save_window()
  return prompt("Save window as", function(window)
    local ok, title = pcall(function()
      return window:mux_window():get_title()
    end)
    return ok and title or nil
  end, function(w, p, name)
    M.save_window(w, p, name)
  end)
end

---Picker over saved tab snapshots. Enter adds one to this window.
function M.action.load_tab()
  return M.action.pick { kinds = { "tab" }, title = "Tabs" }
end

---Picker over saved window snapshots. Enter opens one.
function M.action.load_window()
  return M.action.pick { kinds = { "window" }, title = "Windows" }
end

function M.action.new()
  return prompt("New workspace name", nil, function(w, p, name)
    M.create(w, p, name)
  end)
end

function M.action.new_at_path()
  return prompt("Open workspace at path", nil, function(w, p, path)
    M.open_dir(w, p, path)
  end)
end

function M.action.rename()
  return prompt("Rename workspace", function(window)
    return window:active_workspace()
  end, function(w, p, name)
    M.rename(w, p, w:active_workspace(), name)
  end)
end

---Close the active workspace, asking first unless `picker.confirm` is false.
function M.action.close()
  return cb(function(window, pane)
    local name = window:active_workspace()
    if not config.get().picker.confirm then
      M.close(window, pane, name)
      return
    end
    require("harbor.util").confirm(window, pane, "Close workspace " .. name .. "?", function(w, p)
      M.close(w, p, name)
    end)
  end)
end

---Save every live workspace, then quit. Bind it in place of QuitApplication.
function M.action.quit()
  return cb(M.quit)
end

function M.action.refresh()
  return cb(M.refresh)
end

return M
