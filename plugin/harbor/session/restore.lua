---@module "harbor.session.restore"
---@author sravioli
---@license GNU-GPLv2

---Rebuild a workspace from a session document.

local wezterm = require "wezterm"

local config = require "harbor.config"
local deps = require "harbor.deps"
local log = require "harbor.logger"
local util = require "harbor.util"

local process = deps.warp.process

local M = {}

local function failure(ctx, message)
  local detail = (ctx.location or "restore") .. ": " .. message
  ctx.errors[#ctx.errors + 1] = detail
  log:warn("%s", detail)
end

local function attempt(ctx, label, fn, ...)
  local ok, result = pcall(fn, ...)
  if not ok then
    failure(ctx, label .. ": " .. tostring(result))
  end
  return ok, result
end

---First leaf of a tree (where the tab's initial pane lives).
---@param node table
---@return table
function M.first_leaf(node)
  while node and not node.pane do
    node = node.first
  end
  return node and node.pane or {}
end

---Spawn options shared by windows, tabs and splits.
---@param leaf table
---@return table|nil, string|nil
function M.spawn_opts(leaf)
  local opts = { domain = { DomainName = leaf.domain or "local" } }
  local remote = leaf.domain and leaf.domain ~= "local"
  if leaf.domain and leaf.domain ~= "local" then
    local ok, dom = pcall(wezterm.mux.get_domain, leaf.domain)
    if ok and dom then
      opts.domain = { DomainName = leaf.domain }
    else
      return nil, "domain is not available: " .. leaf.domain
    end
  end
  if leaf.cwd then
    if not remote and not util.is_dir(leaf.cwd) then
      return nil, "directory does not exist: " .. leaf.cwd
    end
    opts.cwd = leaf.cwd
  end
  return opts
end

---Shell quoting style for whatever is running in `pane` now.
---@param pane any
---@return string
local function shell_style(pane)
  local ok, info = pcall(pane.get_foreground_process_info, pane)
  local shell = ok and info and (info.executable or info.name)
  if not shell then
    return deps.warp.filesystem.is_win and "powershell" or "posix"
  end
  return process.style_for(shell)
end

---Apply leaf content (scrollback, process) to a freshly spawned pane.
---@param pane any
---@param leaf table
---@param ctx table
local function fill(pane, leaf, ctx)
  if leaf.scrollback and ctx.scrollback then
    local sanitized = require("harbor.session.capture").sanitize(leaf.scrollback)
    local text = sanitized:gsub("\r?\n", "\r\n")
    attempt(ctx, "scrollback", pane.inject_output, pane, text .. "\r\n\27[0m")
  end
  if
    leaf.process
    and ctx.processes
    and (not leaf.domain or leaf.domain == "local")
    and ctx.allow[leaf.process.name or ""]
  then
    local argv = leaf.process.argv or {}
    if #argv > 0 then
      local location = ctx.location
      attempt(ctx, "schedule process replay", util.later, ctx.delay, function()
        if ctx.rolled_back then
          return
        end
        local ok, err = pcall(function()
          local line = process.join(argv, shell_style(pane))
          log:info("relaunching %s", leaf.process.name)
          pane:send_text(line .. "\r")
        end)
        if not ok then
          require("harbor.state").protect(ctx.name, "process replay failed")
          failure(
            { location = location, errors = ctx.errors },
            "process replay failed: " .. tostring(err)
          )
        end
      end)
    end
  end
  if leaf.active then
    ctx.active_pane = pane
  end
  if leaf.zoomed then
    ctx.zoomed = true
  end
end

---Remember a pane this restore created, for rollback.
---@param ctx table
---@param pane any
local function track(ctx, pane)
  local ok, id = pcall(pane.pane_id, pane)
  if ok and id ~= nil then
    ctx.spawned[#ctx.spawned + 1] = id
  end
end

---Recursively rebuild `node` inside `pane`.
---@param node table
---@param pane any
---@param ctx table
function M.node(node, pane, ctx, path)
  path = path or "root"
  if node.pane then
    local location = ctx.location
    ctx.location = (location or "restore") .. " pane " .. path
    fill(pane, node.pane, ctx)
    ctx.location = location
    return
  end
  local args, spawn_err = M.spawn_opts(M.first_leaf(node.second))
  if not args then
    failure(ctx, "pane " .. path .. ".second: " .. spawn_err)
    M.node(node.first, pane, ctx, path .. ".first")
    return
  end
  args.direction = node.split == "Bottom" and "Bottom" or "Right"
  args.size = tonumber(node.size) or 0.5
  local ok, new = pcall(pane.split, pane, args)
  if ok and new then
    track(ctx, new)
  end
  M.node(node.first, pane, ctx, path .. ".first")
  if ok and new then
    M.node(node.second, new, ctx, path .. ".second")
  else
    failure(ctx, "pane " .. path .. ": split failed: " .. tostring(new))
  end
end

---@param tab any
---@param pane any
---@param data table
---@param ctx table
local function build_tab(tab, pane, data, ctx)
  ctx.active_pane, ctx.zoomed = nil, false
  M.node(data.root, pane, ctx)
  if data.title then
    attempt(ctx, "tab title", tab.set_title, tab, data.title)
  end
  if ctx.active_pane then
    attempt(ctx, "active pane", ctx.active_pane.activate, ctx.active_pane)
  end
  if ctx.zoomed then
    attempt(ctx, "zoom", tab.set_zoomed, tab, true)
  end
end

---Close the panes a failed restore created. Returns true when all are gone.
---@param ctx table
---@return boolean
local function rollback(ctx)
  ctx.rolled_back = true
  if #ctx.spawned == 0 then
    return true
  end
  local _, errors = require("harbor.workspace").kill_panes(ctx.spawned)
  if #errors > 0 then
    log:error("restore rollback incomplete for %s: %s", ctx.name, table.concat(errors, "; "))
    return false
  end
  return true
end

---Spawn and build one extra tab inside `window`. Failures are recorded on
---`ctx`; returns the new tab, or nil.
---@param window any mux window
---@param data table tab document
---@param ctx table
---@return any|nil tab
function M.tab_into(window, data, ctx)
  local topts, tab_err = M.spawn_opts(M.first_leaf(data.root))
  local ok, tab, pane
  if topts then
    ok, tab, pane = pcall(window.spawn_tab, window, topts)
  else
    tab = tab_err
  end
  if ok and tab and pane then
    track(ctx, pane)
    build_tab(tab, pane, data, ctx)
    return tab
  end
  failure(ctx, "spawn_tab failed: " .. tostring(tab))
end

---Spawn a window from `win` in `workspace` and rebuild its tabs.
---@param win table window document
---@param index integer window position, for error locations
---@param ctx table
---@param workspace string
---@return boolean restored
function M.window(win, index, ctx, workspace)
  ctx.location = "window " .. index
  local tabs = win.tabs or {}
  if #tabs == 0 then
    return false
  end
  local spawn, spawn_err = M.spawn_opts(M.first_leaf(tabs[1].root))
  if not spawn then
    failure(ctx, spawn_err)
    return false
  end
  spawn.workspace = workspace
  local ok, tab, pane, window = pcall(wezterm.mux.spawn_window, spawn)
  if not (ok and tab and pane and window) then
    failure(ctx, "spawn_window failed: " .. tostring(tab))
    return false
  end
  track(ctx, pane)
  if win.title then
    attempt(ctx, "window title", window.set_title, window, win.title)
  end
  ctx.location = ("window %d tab 1"):format(index)
  build_tab(tab, pane, tabs[1], ctx)
  local active_tab = tabs[1].active and tab or nil
  for i = 2, #tabs do
    ctx.location = ("window %d tab %d"):format(index, i)
    local t = M.tab_into(window, tabs[i], ctx)
    if t and tabs[i].active then
      active_tab = t
    end
  end
  if active_tab then
    attempt(ctx, "active tab", active_tab.activate, active_tab)
  end
  return true
end

---Panes whose repository is on a different branch than when saved.
---@param doc table
---@return { path: string, saved: string, current: string }[]
function M.branch_mismatches(doc)
  local out = {}
  if not config.get().sessions.git_branch then
    return out
  end
  local capture = require "harbor.session.capture"
  local cache = {}
  local function walk(node)
    if node.pane then
      local leaf = node.pane
      local local_pane = leaf.domain == nil or leaf.domain == "local"
      if leaf.branch and leaf.cwd and local_pane then
        local current = capture.branch(leaf.cwd, cache)
        if current and current ~= leaf.branch then
          out[#out + 1] = { path = leaf.cwd, saved = leaf.branch, current = current }
        end
      end
    else
      walk(node.first)
      walk(node.second)
    end
  end
  for _, win in ipairs(doc.windows or {}) do
    for _, tab in ipairs(win.tabs or {}) do
      walk(tab.root)
    end
  end
  return out
end

---Fresh restore context; `name` is the workspace panes are built into.
---@param name string
---@return table
function M.context(name)
  local cfg = config.get().sessions
  return {
    scrollback = cfg.scrollback.enabled,
    processes = cfg.processes.enabled,
    allow = config.process_allowlist(),
    delay = cfg.processes.delay,
    errors = {},
    spawned = {},
    name = name,
  }
end

---Load a window or tab snapshot into the existing workspace `workspace`.
---A failed load closes every pane it created, so nothing half-built stays.
---@param kind "window"|"tab"
---@param doc table
---@param mux_window any target window (tabs are added to it)
---@param workspace string
---@return boolean ok, string|nil err
function M.snapshot(kind, doc, mux_window, workspace)
  local valid, validation_err = require("harbor.session.store").validate(doc, kind)
  if not valid then
    return false, validation_err
  end
  local ctx = M.context(workspace)
  if kind == "tab" then
    ctx.location = "tab"
    local tab = M.tab_into(mux_window, doc.windows[1].tabs[1], ctx)
    if tab then
      attempt(ctx, "active tab", tab.activate, tab)
    end
  else
    M.window(doc.windows[1], 1, ctx, workspace)
  end
  if #ctx.errors > 0 then
    local err = table.concat(ctx.errors, "; ")
    log:error("%s snapshot load failed: %s", kind, err)
    return false, err .. (rollback(ctx) and " (rolled back)" or "")
  end
  return true
end

---Restore `doc` as a new workspace. Does not switch to it.
---
---With `opts.rollback`, a partial restore closes every pane it created;
---without it, healthy panes stay open for inspection.
---@param doc table
---@param opts? { rollback?: boolean }
---@return boolean ok, string|nil err
function M.workspace(doc, opts)
  local valid, validation_err = require("harbor.session.store").validate(doc)
  if not valid then
    return false, validation_err
  end
  local ctx = M.context(doc.name)
  local name = doc.name
  require("harbor.state").protect(name, "restore in progress")
  local restored = 0

  for wi, win in ipairs(doc.windows) do
    if M.window(win, wi, ctx, name) then
      restored = restored + 1
    end
  end

  if #ctx.errors > 0 then
    local err = table.concat(ctx.errors, "; ")
    log:error("restore of %s failed: %s", name, err)
    if opts and opts.rollback and rollback(ctx) then
      require("harbor.state").unprotect(name)
      return false, err .. " (rolled back)"
    end
    require("harbor.state").protect(name, err)
    return false, err
  end

  if restored == 0 then
    return false, "nothing restored for " .. name
  end
  if doc.path then
    require("harbor.state").set_workspace_path(name, doc.path)
  end
  require("harbor.state").unprotect(name)
  return true
end

return M
