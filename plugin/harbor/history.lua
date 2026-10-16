---@module "harbor.history"
---@author sravioli
---@license GNU-GPLv3

---Most-recently-used workspaces and directories, persisted with memo.state.

local deps = require "harbor.deps"
local util = require "harbor.util"

local M = {}

local MAX_ENTRIES = 200

---@type memo.state.Store|nil
local store

---@return memo.state.Store|nil
local function get_store()
  if store then
    return store
  end
  local dir = util.data_dir()
  if not util.mkdir(dir) then
    return nil
  end
  store = deps.memo.state.new {
    path = dir .. "/history.json",
    atomic = true,
    async = true,
    auto_save = false,
  }
  return store
end

---Replace `key` wholesale (no deep-merge) and flush.
---@param s memo.state.Store
---@param key string
---@param value any
local function put(s, key, value)
  if value == nil then
    s:delete(key)
  else
    s:set(key, value, { replace = true })
  end
  s:save()
end

---Copy a (possibly GLOBAL-backed) list into a plain Lua table.
---@param list any
---@return table
local function plain(list)
  local out = list and deps.memo.cache.plain(list)
  return type(out) == "table" and out or {}
end

---@param key string
---@return table entries `{ id, at }` most recent first
local function read(key)
  local s = get_store()
  local raw = s and s:get(key)
  local out = {}
  if raw then
    for _, e in ipairs(raw) do
      if e and e.id then
        out[#out + 1] = { id = e.id, at = tonumber(e.at) or 0 }
      end
    end
  end
  return out
end

---@param key string
---@param id string
local function touch(key, id)
  local s = get_store()
  if not s or type(id) ~= "string" or id == "" then
    return
  end
  local entries = read(key)
  local out = { { id = id, at = os.time() } }
  for _, e in ipairs(entries) do
    if e.id ~= id and #out < MAX_ENTRIES then
      out[#out + 1] = e
    end
  end
  put(s, key, out)
end

-- ── Workspaces ─────────────────────────────────────────────────────────────

---Record that `name` became the active workspace.
---@param name string
---@param from? string workspace that was active before
function M.visit(name, from)
  local current = from or M.current()
  if current ~= name then
    local s = get_store()
    if s and current then
      s:set("previous", current)
    end
  end
  local s = get_store()
  if s then
    s:set("current", name)
  end
  touch("workspaces", name)
end

---@return string|nil
function M.current()
  local s = get_store()
  return s and s:get "current" or nil
end

---@return string|nil
function M.previous()
  local s = get_store()
  return s and s:get "previous" or nil
end

---Rename a workspace in history.
---@param old string
---@param new string
function M.rename(old, new)
  local s = get_store()
  if not s then
    return
  end
  local entries = read "workspaces"
  for _, e in ipairs(entries) do
    if e.id == old then
      e.id = new
    end
  end
  deps.warp.list.unique(entries, function(e)
    return e.id
  end)
  if s:get "previous" == old then
    s:set("previous", new)
  end
  if s:get "current" == old then
    s:set("current", new)
  end
  put(s, "workspaces", entries)
end

---Forget a workspace.
---@param name string
function M.forget(name)
  local s = get_store()
  if not s then
    return
  end
  local out = {}
  for _, e in ipairs(read "workspaces") do
    if e.id ~= name then
      out[#out + 1] = e
    end
  end
  if s:get "previous" == name then
    s:delete "previous"
  end
  put(s, "workspaces", out)
end

-- ── Directories ────────────────────────────────────────────────────────────

---@param p string
function M.visit_dir(p)
  local key = util.path_key(p)
  if key then
    touch("dirs", key)
  end
end

---Rank lookup: `id -> position` (1 = most recent).
---@param kind "workspaces"|"dirs"
---@return table<string, integer>
function M.ranks(kind)
  local out = {}
  for i, e in ipairs(read(kind)) do
    out[e.id] = i
  end
  return out
end

---Raw list (most recent first).
---@param kind "workspaces"|"dirs"
---@return table
function M.list(kind)
  return plain(read(kind))
end

---Testing hook.
function M._reset()
  store = nil
end

return M
