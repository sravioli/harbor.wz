---@module "harbor.sources.domains"
---@author sravioli
---@license GNU-GPLv3

---Spawnable mux domains (SSH, WSL, unix, TLS, ...).

local wezterm = require "wezterm"

local M = {}

---Classify a domain by its name.
---@param name string
---@return string
function M.kind(name)
  if name == "local" then
    return "local"
  end
  local prefix = name:match "^(%u+):"
  if prefix == "SSHMUX" then
    return "sshmux"
  elseif prefix == "SSH" then
    return "ssh"
  elseif prefix == "WSL" then
    return "wsl"
  elseif prefix == "TLS" then
    return "tls"
  elseif name:lower():match "^unix" then
    return "unix"
  end
  return "other"
end

---@param name string
---@param opts table `sources.domains`
---@return boolean
function M.allowed(name, opts)
  local kinds = {}
  for _, k in ipairs(opts.kinds) do
    kinds[k] = true
  end
  if not kinds[M.kind(name)] then
    return false
  end
  for _, ignored in ipairs(opts.ignore) do
    if ignored == name then
      return false
    end
  end
  for _, pat in ipairs(opts.ignore_patterns) do
    local ok, hit = pcall(string.find, name, pat)
    if ok and hit then
      return false
    end
  end
  return true
end

---@param opts table `sources.domains`
---@return harbor.Entry[]
function M.collect(opts)
  local ok, domains = pcall(wezterm.mux.all_domains)
  if not ok or type(domains) ~= "table" then
    return {}
  end
  local out = {}
  for _, d in ipairs(domains) do
    local nok, name = pcall(d.name, d)
    local sok, spawnable = pcall(d.is_spawnable, d)
    if nok and name and (not sok or spawnable) and M.allowed(name, opts) then
      out[#out + 1] = { kind = "domain", domain = name, domain_kind = M.kind(name) }
    end
  end
  return out
end

return M
