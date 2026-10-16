---@module "harbor.layout"
---@author sravioli
---@license GNU-GPLv3

---Workspace layouts applied when harbor creates a workspace from a directory.
---
---A layout is either a function `fn(ctx)` or a table:
---
---```lua
---{
---  tabs = {
---    { title = "edit", cmd = "nvim ." },
---    { title = "run", cwd = "app", splits = {
---      { direction = "Right", size = 0.4, cmd = "npm run dev" },
---    } },
---  },
---}
---```
---
---`cwd` is relative to the workspace root, `cmd` is typed into the shell,
---`args` replaces the shell entirely.

local config = require "harbor.config"
local deps = require "harbor.deps"
local log = require "harbor.logger"
local util = require "harbor.util"

local w = deps.warden

local M = {}

local pane_fields = {
  cwd = w.string():optional(),
  cmd = w.string():optional(),
  args = w.array(w.string()):optional(),
  env = w.map(w.string(), w.string()):optional(),
}

local split_schema
split_schema = w.object({
  direction = w.enum({ "Right", "Left", "Bottom", "Top" }):default "Right",
  size = w.number():range(0.05, 0.95):default(0.5),
  cwd = pane_fields.cwd,
  cmd = pane_fields.cmd,
  args = pane_fields.args,
  env = pane_fields.env,
  splits = w.array(w.any()):optional(),
}):unknown "warn"

local tab_schema = w.object({
  title = w.string():optional(),
  cwd = pane_fields.cwd,
  cmd = pane_fields.cmd,
  args = pane_fields.args,
  env = pane_fields.env,
  splits = w.array(split_schema):optional(),
  active = w.boolean():optional(),
}):unknown "warn"

M.schema = w.object({
  tabs = w.array(tab_schema):min(1),
}):unknown "warn"

-- ── Resolution ─────────────────────────────────────────────────────────────

---@param file string
---@return any
local function load_file(file)
  local fh = io.open(file, "r")
  if not fh then
    return nil
  end
  fh:close()
  local ok, res = pcall(dofile, file)
  if not ok then
    log:error("layout %s failed to load: %s", file, res)
    return nil
  end
  return res
end

---Turn a layout reference (name, table or function) into a layout value.
---@param ref any
---@return table|function|nil
function M.load(ref)
  if type(ref) == "table" or type(ref) == "function" then
    return ref
  end
  if type(ref) ~= "string" then
    return nil
  end
  local dir = config.get().layouts.dir
  if not dir then
    log:warn("layout %q requested but layouts.dir is not set", ref)
    return nil
  end
  return load_file(util.clean_path(dir) .. "/" .. ref .. ".lua")
end

---Pick the layout for a new workspace rooted at `root`.
---@param root string|nil
---@param name string
---@return table|function|nil
function M.resolve(root, name)
  local cfg = config.get().layouts
  if root and cfg.trust_project_files and cfg.project_file ~= "" then
    local project = load_file(root .. "/" .. cfg.project_file)
    if project then
      return project
    end
  end
  for _, rule in ipairs(cfg.rules) do
    local hit
    if type(rule.match) == "function" then
      local ok, res = util.try("layouts.rules.match", rule.match, root, name)
      hit = ok and res
    elseif root then
      local ok, res = pcall(string.find, root, rule.match)
      hit = ok and res
    end
    if hit then
      return M.load(rule.layout)
    end
  end
  return cfg.default and M.load(cfg.default) or nil
end

-- ── Application ────────────────────────────────────────────────────────────

---@param root string|nil
---@param rel string|nil
---@return string|nil
local function join_cwd(root, rel)
  if not rel then
    return root
  end
  rel = util.clean_path(rel) or rel
  if not root or deps.warp.path.is_absolute(rel) then
    return rel
  end
  return root .. "/" .. rel
end

---@param spec table
---@param root string|nil
---@param domain string|nil
---@return table
local function spawn_args(spec, root, domain)
  local args =
    { cwd = join_cwd(root, spec.cwd), args = spec.args, set_environment_variables = spec.env }
  if domain and domain ~= "local" then
    args.domain = { DomainName = domain }
  end
  return args
end

---@param pane any
---@param cmd string|nil
local function type_cmd(pane, cmd)
  if cmd and cmd ~= "" then
    pcall(pane.send_text, pane, cmd .. "\r")
  end
end

---@param pane any
---@param splits table[]|nil
---@param root string|nil
---@param domain string|nil
local function apply_splits(pane, splits, root, domain)
  for _, raw in ipairs(splits or {}) do
    local res = split_schema:safe_parse(raw)
    if not res.ok then
      res:log()
    else
      local s = res.value
      local args = spawn_args(s, root, domain)
      args.direction, args.size = s.direction, s.size
      local ok, new = pcall(pane.split, pane, args)
      if ok and new then
        if not s.args then
          type_cmd(new, s.cmd)
        end
        apply_splits(new, s.splits, root, domain)
      else
        log:warn("layout split failed: %s", new)
      end
    end
  end
end

---Apply `layout` to a freshly spawned workspace.
---@param layout table|function
---@param ctx { name: string, root?: string, domain?: string, window: any, tab: any, pane: any }
---@return boolean ok
function M.apply(layout, ctx)
  if type(layout) == "function" then
    local ok = util.try("layout function", layout, ctx)
    return ok
  end
  local res = M.schema:safe_parse(layout)
  if not res.ok then
    res:log()
    return false
  end

  local active
  for i, tab_spec in ipairs(res.value.tabs) do
    local tab, pane = ctx.tab, ctx.pane
    if i > 1 then
      local ok, t, p =
        pcall(ctx.window.spawn_tab, ctx.window, spawn_args(tab_spec, ctx.root, ctx.domain))
      if ok and t then
        tab, pane = t, p
      else
        log:warn("layout tab failed: %s", t)
        tab, pane = nil, nil
      end
    end
    if tab and pane then
      if tab_spec.title then
        pcall(tab.set_title, tab, tab_spec.title)
      end
      if not tab_spec.args then
        type_cmd(pane, tab_spec.cmd)
      end
      apply_splits(pane, tab_spec.splits, ctx.root, ctx.domain)
      pcall(pane.activate, pane)
      if tab_spec.active then
        active = tab
      end
    end
  end
  pcall((active or ctx.tab).activate, active or ctx.tab)
  return true
end

---Spawn args (cwd/args/env) for the first tab of `layout`, so the initial
---window can be spawned directly with them.
---@param layout table|function|nil
---@param root string|nil
---@return table
function M.first_tab_args(layout, root)
  if type(layout) ~= "table" or type(layout.tabs) ~= "table" or type(layout.tabs[1]) ~= "table" then
    return { cwd = root }
  end
  local t = layout.tabs[1]
  return { cwd = join_cwd(root, t.cwd), args = t.args, set_environment_variables = t.env }
end

return M
