---@module "harbor.state"
---@author sravioli
---@license GNU-GPLv2

---Session-scoped (in-memory, survives config reloads) bookkeeping kept in
---`wezterm.GLOBAL`. Restore protection is separate from the evictable cache.

local deps = require "harbor.deps"
local wezterm = require "wezterm"

local M = {}

---Set by `apply_to_config` once the picker key table is registered.
---@type boolean
M.key_table_ready = false

local ns

local function cache()
  if not ns then
    ns = deps.memo.cache.namespace "harbor"
  end
  return ns
end

---@param name string
---@param reason string
function M.protect(name, reason)
  local protected = deps.memo.cache.plain(wezterm.GLOBAL.harbor_restore_protection or {})
  protected[name] = reason
  wezterm.GLOBAL.harbor_restore_protection = protected
end

---@param name string
---@return string|nil
function M.protection(name)
  local protected = wezterm.GLOBAL.harbor_restore_protection
  return protected and protected[name]
end

---@param name string
function M.unprotect(name)
  local protected = deps.memo.cache.plain(wezterm.GLOBAL.harbor_restore_protection or {})
  protected[name] = nil
  wezterm.GLOBAL.harbor_restore_protection = protected
end

-- ── Workspace → root path ──────────────────────────────────────────────────

---@param name string
---@return string|nil
function M.workspace_path(name)
  local map = cache().get "ws_paths"
  return map and map[name] or nil
end

---@param name string
---@param p string|nil
function M.set_workspace_path(name, p)
  local map = {}
  local cur = cache().get "ws_paths"
  if cur then
    for k, v in pairs(cur) do
      map[k] = v
    end
  end
  map[name] = p
  cache().set("ws_paths", map, { force = true })
end

---@param old string
---@param new string
function M.rename_workspace(old, new)
  local p = M.workspace_path(old)
  local reason = M.protection(old)
  M.set_workspace_path(old, nil)
  if p then
    M.set_workspace_path(new, p)
  end
  if reason then
    M.protect(new, reason)
    M.unprotect(old)
  end
end

-- ── Generic TTL cache ──────────────────────────────────────────────────────

---Deep-copy a (possibly GLOBAL-backed) value into plain Lua tables.
M.plain = deps.memo.cache.plain

---Cached `producer()` result for `key` (seconds `ttl`, 0 disables).
---Returns plain tables; nil results are never cached.
---@param key string
---@param ttl number
---@param producer fun(): any
---@return any
function M.cached(key, ttl, producer)
  return cache().fetch(key, producer, { ttl = (ttl and ttl > 0) and ttl or 0, plain = true })
end

---Drop cached source results.
---@param key? string
function M.invalidate(key)
  if key then
    cache().delete(key)
  else
    cache().clear { prefix = "src:" }
  end
end

---Testing hook.
function M._reset()
  ns = nil
  M.key_table_ready = false
end

return M
