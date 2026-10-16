---@module "harbor.naming"
---@author sravioli
---@license GNU-GPLv3

---Workspace names derived from paths, and reversible file names for
---session documents.

local config = require "harbor.config"
local deps = require "harbor.deps"
local util = require "harbor.util"

local M = {}

---Base workspace name for `p` according to `naming.style`.
---@param p string
---@return string
function M.base_name(p)
  local opts = config.get().naming
  p = util.clean_path(p) or p

  if opts.fn then
    local ok, res = util.try("naming.fn", opts.fn, p)
    if ok and type(res) == "string" and res ~= "" then
      return res
    end
  end

  local name
  if opts.style == "tilde" then
    name = util.tilde(p)
  elseif opts.style == "path" then
    name = p
  else
    name = util.basename(p)
    if name == "" then
      name = p
    end
  end
  if opts.replace_dots then
    name = name:gsub("%.", "_")
  end
  -- width-aware and UTF-8 safe; never splits a multibyte character
  name = deps.warp.string.truncate_right(name, opts.max_length)
  return name
end

---Pick a workspace name for `p` that does not collide with workspaces that
---belong to a different directory.
---
---@param p     string
---@param taken table<string, string|true>  name -> owning path key (or true if unknown)
---@return string
function M.unique_name(p, taken)
  local key = util.path_key(p)
  local name = M.base_name(p)

  local function free(n)
    local owner = taken[n]
    return owner == nil or owner == key
  end

  if free(name) then
    return name
  end

  local parent = util.dirname(util.clean_path(p) or p)
  if parent then
    local qualified = ("%s (%s)"):format(name, util.basename(parent))
    if free(qualified) then
      return qualified
    end
  end

  local i = 2
  while not free(("%s (%d)"):format(name, i)) do
    i = i + 1
  end
  return ("%s (%d)"):format(name, i)
end

-- ── File names ─────────────────────────────────────────────────────────────

local MAX_FILE_STEM = 120

---Encode an arbitrary name into a portable file stem (percent encoding).
---@param name string
---@return string
function M.encode(name)
  local enc = name:gsub("[^%w%-_ ]", function(c)
    return ("%%%02X"):format(c:byte())
  end)
  enc = enc:gsub(" ", "+")
  if #enc > MAX_FILE_STEM then
    -- Keep it unique and reversible via the name stored inside the document.
    local h = 0
    for i = 1, #name do
      h = (h * 31 + name:byte(i)) % 4294967296
    end
    enc = ("%s~%08x"):format(enc:sub(1, MAX_FILE_STEM - 9), h)
  end
  return enc
end

---Decode a stem produced by `encode` (best effort for truncated stems).
---@param stem string
---@return string
function M.decode(stem)
  stem = stem:gsub("~%x+$", "")
  stem = stem:gsub("%+", " ")
  return (stem:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

return M
