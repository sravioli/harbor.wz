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

---Restore `doc` as a new workspace. Does not switch to it.
---@param doc table
---@return boolean ok, string|nil err
function M.workspace(doc)
  local valid, validation_err = require("harbor.session.store").validate(doc)
  if not valid then
    return false, validation_err
  end
  local cfg = config.get().sessions
  local ctx = {
    scrollback = cfg.scrollback.enabled,
    processes = cfg.processes.enabled,
    allow = config.process_allowlist(),
    delay = cfg.processes.delay,
    errors = {},
    name = doc.name,
  }
  local name = doc.name
  require("harbor.state").protect(name, "restore in progress")
  local restored = 0

  for wi, win in ipairs(doc.windows) do
    ctx.location = "window " .. wi
    local tabs = win.tabs or {}
    if #tabs > 0 then
      local opts, opts_err = M.spawn_opts(M.first_leaf(tabs[1].root))
      if not opts then
        failure(ctx, opts_err)
      else
        opts.workspace = name
        local ok, tab, pane, window = pcall(wezterm.mux.spawn_window, opts)
        if ok and tab and pane and window then
          if win.title then
            attempt(ctx, "window title", window.set_title, window, win.title)
          end
          ctx.location = ("window %d tab 1"):format(wi)
          build_tab(tab, pane, tabs[1], ctx)
          local active_tab = tabs[1].active and tab or nil
          for i = 2, #tabs do
            ctx.location = ("window %d tab %d"):format(wi, i)
            local topts, tab_err = M.spawn_opts(M.first_leaf(tabs[i].root))
            local tok, t, p
            if topts then
              tok, t, p = pcall(window.spawn_tab, window, topts)
            else
              t = tab_err
            end
            if tok and t and p then
              build_tab(t, p, tabs[i], ctx)
              if tabs[i].active then
                active_tab = t
              end
            else
              failure(ctx, "spawn_tab failed: " .. tostring(t))
            end
          end
          if active_tab then
            attempt(ctx, "active tab", active_tab.activate, active_tab)
          end
          restored = restored + 1
        else
          failure(ctx, "spawn_window failed: " .. tostring(tab))
        end
      end
    end
  end

  if #ctx.errors > 0 then
    local err = table.concat(ctx.errors, "; ")
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
