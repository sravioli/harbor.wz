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
---@return table
function M.spawn_opts(leaf)
  local opts = {}
  local remote = leaf.domain and leaf.domain ~= "local"
  if leaf.domain then
    local ok, dom = pcall(wezterm.mux.get_domain, leaf.domain)
    if ok and dom then
      opts.domain = { DomainName = leaf.domain }
    else
      log:warn("domain %s is not available; using default", leaf.domain)
      remote = false
    end
  end
  if leaf.cwd and (remote or util.is_dir(leaf.cwd)) then
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
    local text = leaf.scrollback:gsub("\r?\n", "\r\n")
    local ok, err = pcall(pane.inject_output, pane, text .. "\r\n\27[0m")
    if not ok then
      log:debug("inject_output failed: %s", err)
    end
  end
  if leaf.process and ctx.processes and ctx.allow[leaf.process.name or ""] then
    local argv = leaf.process.argv or {}
    if #argv > 0 then
      util.later(ctx.delay, function()
        local line = process.join(argv, shell_style(pane))
        log:info("relaunching %s", leaf.process.name)
        pane:send_text(line .. "\r")
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
function M.node(node, pane, ctx)
  if node.pane then
    fill(pane, node.pane, ctx)
    return
  end
  local args = M.spawn_opts(M.first_leaf(node.second))
  args.direction = node.split == "Bottom" and "Bottom" or "Right"
  args.size = tonumber(node.size) or 0.5
  local ok, new = pcall(pane.split, pane, args)
  M.node(node.first, pane, ctx)
  if ok and new then
    M.node(node.second, new, ctx)
  else
    log:warn("split failed: %s", new)
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
    pcall(tab.set_title, tab, data.title)
  end
  if ctx.active_pane then
    pcall(ctx.active_pane.activate, ctx.active_pane)
  end
  if ctx.zoomed then
    pcall(tab.set_zoomed, tab, true)
  end
end

---Restore `doc` as a new workspace. Does not switch to it.
---@param doc table
---@return boolean ok, string|nil err
function M.workspace(doc)
  local cfg = config.get().sessions
  local ctx = {
    scrollback = cfg.scrollback.enabled,
    processes = cfg.processes.enabled,
    allow = config.process_allowlist(),
    delay = cfg.processes.delay,
  }
  local name = doc.name
  local restored = 0

  for _, win in ipairs(doc.windows) do
    local tabs = win.tabs or {}
    if #tabs > 0 then
      local opts = M.spawn_opts(M.first_leaf(tabs[1].root))
      opts.workspace = name
      local ok, tab, pane, window = pcall(wezterm.mux.spawn_window, opts)
      if ok and tab then
        build_tab(tab, pane, tabs[1], ctx)
        local active_tab = tabs[1].active and tab or nil
        for i = 2, #tabs do
          local topts = M.spawn_opts(M.first_leaf(tabs[i].root))
          local tok, t, p = pcall(window.spawn_tab, window, topts)
          if tok and t then
            build_tab(t, p, tabs[i], ctx)
            if tabs[i].active then
              active_tab = t
            end
          else
            log:warn("spawn_tab failed: %s", t)
          end
        end
        if active_tab then
          pcall(active_tab.activate, active_tab)
        end
        restored = restored + 1
      else
        log:error("spawn_window failed: %s", tab)
      end
    end
  end

  if restored == 0 then
    return false, "nothing restored for " .. name
  end
  if doc.path then
    require("harbor.state").set_workspace_path(name, doc.path)
  end
  return true
end

return M
