---@module "harbor.session.store"
---@author sravioli
---@license GNU-GPLv2

---Session documents on disk: one JSON file per workspace, written atomically
---via memo.state.write_atomic, versioned and migrated on load.

local wezterm = require "wezterm"

local config = require "harbor.config"
local deps = require "harbor.deps"
local log = require "harbor.logger"
local naming = require "harbor.naming"
local util = require "harbor.util"

local M = {}

M.SCHEMA_VERSION = 1

local function array(value)
  if type(value) ~= "table" or #value == 0 then
    return false
  end
  local count = 0
  for key in pairs(value) do
    count = count + 1
    if type(key) ~= "number" or key < 1 or key > #value or key % 1 ~= 0 then
      return false
    end
  end
  return count == #value
end

local function valid_tree(node, depth)
  if type(node) ~= "table" or depth > 64 then
    return false
  end
  if node.pane then
    local leaf = node.pane
    if type(leaf) ~= "table" or node.split or node.first or node.second then
      return false
    end
    for _, key in ipairs { "cwd", "domain", "title", "scrollback" } do
      if leaf[key] ~= nil and type(leaf[key]) ~= "string" then
        return false
      end
    end
    for _, key in ipairs { "active", "zoomed" } do
      if leaf[key] ~= nil and type(leaf[key]) ~= "boolean" then
        return false
      end
    end
    if leaf.process then
      local proc = leaf.process
      if type(proc) ~= "table" or type(proc.name) ~= "string" or not array(proc.argv) then
        return false
      end
      for _, arg in ipairs(proc.argv) do
        if type(arg) ~= "string" or arg:find "%z" then
          return false
        end
      end
      if require("harbor.session.capture").process_name(proc.argv[1]) ~= proc.name then
        return false
      end
    end
    return true
  end
  return (node.split == "Right" or node.split == "Bottom")
    and type(node.size) == "number"
    and node.size > 0
    and node.size < 1
    and valid_tree(node.first, depth + 1)
    and valid_tree(node.second, depth + 1)
end

---Migrations keyed by the version they upgrade *from*.
---@type table<integer, fun(doc: table): table>
M.migrations = {
  -- [1] = function(doc) ... doc.schema_version = 2; return doc end,
}

---@return string
function M.dir()
  return util.data_dir() .. "/sessions"
end

---@param name string
---@return string
function M.path_for(name)
  return M.dir() .. "/" .. naming.encode(name) .. ".json"
end

-- ── Validation ─────────────────────────────────────────────────────────────

---Validate document structure and pane trees before any restore side effects.
---@param doc any
---@return boolean ok, string|nil err
function M.validate(doc)
  if type(doc) ~= "table" then
    return false, "document is not an object"
  end
  if type(doc.name) ~= "string" or doc.name == "" then
    return false, "missing workspace name"
  end
  if doc.path ~= nil and type(doc.path) ~= "string" then
    return false, "invalid workspace path"
  end
  if doc.schema_version ~= nil then
    local version = tonumber(doc.schema_version)
    if not version or version < 1 or version % 1 ~= 0 then
      return false, "invalid schema version"
    end
    if version > M.SCHEMA_VERSION then
      return false, "session was written by a newer harbor"
    end
  end
  if not array(doc.windows) then
    return false, "missing windows"
  end
  for i, win in ipairs(doc.windows) do
    if type(win) ~= "table" or not array(win.tabs) then
      return false, ("window %d has no tabs"):format(i)
    end
    for j, tab in ipairs(win.tabs) do
      if type(tab) ~= "table" or not valid_tree(tab.root, 0) then
        return false, ("window %d tab %d has no pane tree"):format(i, j)
      end
      if
        (tab.title ~= nil and type(tab.title) ~= "string")
        or (tab.active ~= nil and type(tab.active) ~= "boolean")
      then
        return false, ("window %d tab %d has invalid metadata"):format(i, j)
      end
    end
    if win.title ~= nil and type(win.title) ~= "string" then
      return false, ("window %d has invalid title"):format(i)
    end
  end
  return true
end

---Upgrade `doc` to the current schema.
---@param doc table
---@return table|nil doc, string|nil err
function M.migrate(doc)
  local v = doc.schema_version == nil and 1 or tonumber(doc.schema_version)
  if not v or v < 1 or v % 1 ~= 0 then
    return nil, "invalid schema version"
  end
  if v > M.SCHEMA_VERSION then
    return nil, ("session was written by a newer harbor (schema %d)"):format(v)
  end
  while v < M.SCHEMA_VERSION do
    local step = M.migrations[v]
    if not step then
      return nil, ("no migration from schema %d"):format(v)
    end
    local ok, migrated = pcall(step, doc)
    if not ok or type(migrated) ~= "table" then
      return nil, "migration failed from schema " .. v
    end
    doc = migrated
    local next_version = tonumber(doc.schema_version)
    if not next_version or next_version ~= v + 1 then
      return nil, "migration did not advance schema " .. v
    end
    v = next_version
  end
  doc.schema_version = M.SCHEMA_VERSION
  return doc
end

-- ── I/O ────────────────────────────────────────────────────────────────────

---Write a captured document.
---@param doc table
---@return boolean ok, string|nil err
function M.write(doc)
  local ok, err = M.validate(doc)
  if not ok then
    return false, err
  end
  if not (wezterm.serde and wezterm.serde.json_encode) then
    return false, "wezterm.serde is unavailable"
  end
  doc.schema_version = M.SCHEMA_VERSION
  local eok, json = pcall(wezterm.serde.json_encode, doc)
  if not eok then
    return false, "encode failed: " .. tostring(json)
  end
  local limit = config.get().sessions.max_file_bytes
  if #json > limit then
    return false, ("session is %d bytes (limit %d)"):format(#json, limit)
  end
  if not util.mkdir(M.dir()) then
    return false, "cannot create " .. M.dir()
  end
  local path = M.path_for(doc.name)
  if not deps.memo.state.write_atomic(path, json, { backup = config.get().sessions.backup }) then
    return false, "write failed: " .. path
  end
  return true
end

---Read and migrate a session by workspace name or file path.
---@param name_or_path string
---@param opts? { backup?: boolean }
---@return table|nil doc, string|nil err
function M.read(name_or_path, opts)
  local path = name_or_path:match "%.json$" and name_or_path or M.path_for(name_or_path)
  if opts and opts.backup then
    path = path .. ".bak"
  end
  local content = deps.warp.filesystem.read_file(path)
  if not content then
    return nil, "no saved session: " .. name_or_path
  end
  if content == "" then
    return nil, "empty session file: " .. path
  end
  local limit = config.get().sessions.max_file_bytes
  if #content > limit then
    return nil, ("session file is %d bytes (limit %d): %s"):format(#content, limit, path)
  end
  local ok, doc = pcall(wezterm.serde.json_decode, content)
  if not ok then
    return nil, "invalid JSON in " .. path
  end
  local vok, verr = M.validate(doc)
  if not vok then
    return nil, verr
  end
  local migrated, err = M.migrate(doc)
  if not migrated then
    return nil, err
  end
  local valid, validation_err = M.validate(migrated)
  return valid and migrated or nil, validation_err
end

---@param name string
---@return boolean
function M.exists(name)
  local fh = io.open(M.path_for(name), "rb")
  if fh then
    fh:close()
    return true
  end
  return false
end

---Saved sessions (name + file), sorted by name. Does not parse documents.
---@return { name: string, file: string }[]
function M.list()
  local ok, entries = pcall(wezterm.read_dir, M.dir())
  if not ok or type(entries) ~= "table" then
    return {}
  end
  local out = {}
  for _, entry in ipairs(entries) do
    local file = entry:gsub("\\", "/")
    local stem = util.basename(file):match "^(.*)%.json$"
    if stem then
      out[#out + 1] = { name = naming.decode(stem), file = file }
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

---@param name string
---@return boolean ok, string|nil err
function M.delete(name)
  local path = M.path_for(name)
  local ok, err = os.remove(path)
  if not ok then
    return false, err
  end
  local backup = io.open(path .. ".bak", "rb")
  if backup then
    backup:close()
    local removed, remove_err = os.remove(path .. ".bak")
    if not removed then
      return false, "primary deleted but backup removal failed: " .. tostring(remove_err)
    end
  end
  return true
end

---Rename a saved session file (and the name stored inside it).
---@param old string
---@param new string
---@return boolean ok, string|nil err
function M.rename(old, new)
  if old == new then
    return true
  end
  if M.exists(new) then
    return false, "saved session already exists: " .. new
  end
  local doc, err = M.read(old)
  if not doc then
    return false, err
  end
  doc.name = new
  local ok, werr = M.write(doc)
  if not ok then
    return false, werr
  end
  return M.delete(old)
end

---Log helper for callers.
---@param what string
---@param err string|nil
function M.report(what, err)
  log:warn("%s: %s", what, err or "unknown error")
end

return M
