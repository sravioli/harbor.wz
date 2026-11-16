---@module "harbor.sources"
---@author sravioli
---@license GNU-GPLv2

---Source pipeline: collect -> dedupe -> filter -> sort.
---
---@class harbor.Entry
---@field kind         "workspace"|"saved"|"tab"|"window"|"dir"|"domain"
---@field id?          string   Typed picker id (`ws:`, `sv:`, `tab:`, `win:`, `dir:`, `dom:`), set by the pipeline.
---@field source?      string   Origin of a `dir` entry (zoxide, projects, dirs, custom).
---@field name?        string   Workspace / session name.
---@field path?        string   Directory (clean path).
---@field score?       number
---@field file?        string   Saved session file.
---@field saved?       boolean  Live workspace that also has a saved session.
---@field saved_at?    number   Unix time of the last save, when recorded.
---@field current?     boolean  Active workspace.
---@field previous?    boolean  Previously active workspace.
---@field domain?      string
---@field domain_kind? string
---@field label?       string   Pre-rendered label (custom sources).

local config = require "harbor.config"
local history = require "harbor.history"
local log = require "harbor.logger"
local state = require "harbor.state"
local util = require "harbor.util"

local M = {}

local PREFIX =
  { workspace = "ws:", saved = "sv:", tab = "tab:", window = "win:", dir = "dir:", domain = "dom:" }

---@type table<string, { mod: string, cache: boolean }>
local REGISTRY = {
  workspaces = { mod = "harbor.sources.workspaces", cache = false },
  saved = { mod = "harbor.sources.saved", cache = false },
  snapshots = { mod = "harbor.sources.snapshots", cache = false },
  zoxide = { mod = "harbor.sources.zoxide", cache = true },
  projects = { mod = "harbor.sources.projects", cache = true },
  dirs = { mod = "harbor.sources.dirs", cache = false },
  domains = { mod = "harbor.sources.domains", cache = false },
}

---Normalize entries returned by a user-defined source.
---@param list any
---@return harbor.Entry[]
local function from_custom(list)
  local out = {}
  if type(list) ~= "table" then
    return out
  end
  for _, e in ipairs(list) do
    if type(e) == "string" then
      e = { path = e }
    end
    if type(e) == "table" then
      if e.workspace or e.name then
        out[#out + 1] = {
          kind = "workspace",
          name = e.workspace or e.name,
          path = util.clean_path(e.path),
          label = e.label,
        }
      elseif e.path then
        out[#out + 1] = {
          kind = "dir",
          source = e.source or "custom",
          path = util.clean_path(e.path),
          label = e.label,
        }
      end
    end
  end
  return out
end

---Run one named source, honouring its cache.
---@param name string
---@param cfg table
---@return harbor.Entry[]
local function run_source(name, cfg)
  local spec = REGISTRY[name]
  local opts = cfg.sources[name]
  if not spec or not opts or not opts.enabled then
    return {}
  end
  local function produce()
    local mod = require(spec.mod)
    local ok, res = pcall(mod.collect, opts)
    if not ok then
      log:error("source %s failed: %s", name, res)
      return {}
    end
    return res or {}
  end
  if spec.cache then
    return state.cached("src:" .. name, cfg.sources.cache_ttl, produce)
  end
  return produce()
end

---Collect raw entries in configured order (plus custom sources).
---@param cfg table
---@return harbor.Entry[][]
function M.collect_raw(cfg)
  local groups = {}
  for _, name in ipairs(cfg.sources.order) do
    groups[#groups + 1] = run_source(name, cfg)
  end
  for i, fn in ipairs(cfg.sources.custom) do
    local ok, res = util.try(("custom source #%d"):format(i), fn)
    groups[#groups + 1] = ok and from_custom(res) or {}
  end
  return groups
end

---Merge groups: live workspaces win over saved sessions and directories that
---point at the same thing.
---@param groups harbor.Entry[][]
---@param ctx { current?: string, previous?: string }
---@return harbor.Entry[]
function M.dedupe(groups, ctx)
  local live, live_paths = {}, {}
  for _, group in ipairs(groups) do
    for _, e in ipairs(group) do
      if e.kind == "workspace" and e.name then
        live[e.name] = e
        local key = util.path_key(state.workspace_path(e.name))
        if key then
          live_paths[key] = e
        end
      end
    end
  end

  local out, seen = {}, {}
  for _, group in ipairs(groups) do
    for _, e in ipairs(group) do
      local id
      if e.kind == "workspace" or e.kind == "tab" or e.kind == "window" then
        id = e.name
      elseif e.kind == "saved" then
        local w = live[e.name]
        if w then
          w.saved = true
          w.file = e.file
          w.saved_at = e.saved_at
        else
          id = e.name
        end
      elseif e.kind == "dir" then
        local key = util.path_key(e.path)
        if key and not live_paths[key] then
          id = key
        end
      elseif e.kind == "domain" then
        id = e.domain
      end

      local typed = id and (PREFIX[e.kind] or "x:") .. id
      if typed and not seen[typed] then
        seen[typed] = true
        e.id = typed
        e.current = e.kind == "workspace" and e.name == ctx.current or nil
        e.previous = e.kind == "workspace" and e.name == ctx.previous or nil
        out[#out + 1] = e
      end
    end
  end
  return out
end

---Stable sort keeping kinds grouped.
---@param entries harbor.Entry[]
---@param mode "mru"|"alpha"|"none"
---@return harbor.Entry[]
function M.sort(entries, mode)
  if mode == "none" then
    return entries
  end
  local ws_rank = mode == "mru" and history.ranks "workspaces" or {}
  local dir_rank = mode == "mru" and history.ranks "dirs" or {}
  local group = { workspace = 1, saved = 2, tab = 3, window = 4, dir = 5, domain = 6 }

  local function text(e)
    return (e.name or e.path or e.domain or ""):lower()
  end
  local function rank(e)
    if e.previous then
      return 0
    end
    if e.current then
      return math.huge
    end
    if e.kind == "workspace" then
      return ws_rank[e.name] or 1e9
    elseif e.kind == "dir" then
      return dir_rank[util.path_key(e.path) or ""] or 1e9
    end
    return 1e9
  end

  for i, e in ipairs(entries) do
    e._pos = i
  end
  table.sort(entries, function(a, b)
    local ga, gb = group[a.kind] or 9, group[b.kind] or 9
    if ga ~= gb then
      return ga < gb
    end
    if mode == "mru" then
      local ra, rb = rank(a), rank(b)
      if ra ~= rb then
        return ra < rb
      end
      if a.kind == "dir" then
        return a._pos < b._pos
      end
    end
    local ta, tb = text(a), text(b)
    if ta ~= tb then
      return ta < tb
    end
    return a._pos < b._pos
  end)
  for _, e in ipairs(entries) do
    e._pos = nil
  end
  return entries
end

---Full pipeline.
---@param opts? { current?: string, kinds?: table<string, boolean> }
---@return harbor.Entry[]
function M.list(opts)
  opts = opts or {}
  local cfg = config.get()
  local ctx = { current = opts.current, previous = history.previous() }
  local entries = M.dedupe(M.collect_raw(cfg), ctx)

  local out = {}
  for _, e in ipairs(entries) do
    local keep = not (opts.kinds and not opts.kinds[e.kind])
      and not (e.current and not cfg.picker.show_current)
    if keep and cfg.picker.filter then
      local ok, res = util.try("picker.filter", cfg.picker.filter, e)
      keep = not ok or res ~= false
    end
    if keep then
      out[#out + 1] = e
    end
  end
  return M.sort(out, cfg.picker.sort)
end

return M
