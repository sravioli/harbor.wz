---@module "harbor.config"
---@author sravioli
---@license GNU-GPLv3

---Option schema (warden) with defaults, plus the live config accessor.
---
---Invalid options never abort the WezTerm config: issues are logged and the
---offending fields fall back to their defaults.

local deps = require "harbor.deps"
local log = require "harbor.logger"

local w = deps.warden
local tbl = deps.warp.table

local M = {}

-- ── Schema helpers ─────────────────────────────────────────────────────────

---@return Warden.Schema
local function fn()
  return w.any():optional():refine(function(v)
    return type(v) == "function"
  end, "Expected function")
end

---@param key string
---@param mods string
---@return Warden.Schema
local function keybind(key, mods)
  return w.object({
    key = w.string():not_empty(),
    mods = w.string():optional(),
  })
    :default({ key = key, mods = mods })
    :unknown "warn"
end

---@param fields table<string, Warden.Schema>
---@return Warden.Schema
local function section(fields)
  return w.object(fields):default({}):unknown "warn"
end

---@type string[]
M.SOURCES = { "workspaces", "saved", "zoxide", "projects", "dirs", "domains" }

-- Foreground programs relaunched on restore when they were running at save
-- time. Matched against the executable basename (lowercase, no `.exe`).
---@type string[]
M.DEFAULT_PROCESSES = {
  "vi",
  "vim",
  "nvim",
  "hx",
  "helix",
  "kak",
  "emacs",
  "nano",
  "micro",
  "less",
  "more",
  "man",
  "top",
  "htop",
  "btop",
  "btm",
  "glances",
  "lazygit",
  "gitui",
  "tig",
  "lazydocker",
  "k9s",
  "yazi",
  "lf",
  "ranger",
  "nnn",
  "broot",
  "ncdu",
  "gdu",
}

-- ── Schema ─────────────────────────────────────────────────────────────────

M.schema = w.object({
  default_workspace = w.string():not_empty():default "default",

  naming = section {
    style = w.enum({ "basename", "tilde", "path" }):default "basename",
    replace_dots = w.boolean():default(false),
    max_length = w.integer():range(8, 256):default(64),
    fn = fn(),
  },

  sources = section {
    order = w.array(w.enum(M.SOURCES)):default(M.SOURCES),
    cache_ttl = w.number():min(0):default(30),

    workspaces = section {
      enabled = w.boolean():default(true),
    },
    saved = section {
      enabled = w.boolean():default(true),
    },
    zoxide = section {
      enabled = w.boolean():default(true),
      path = w.string():optional(),
      min_score = w.number():default(0),
      limit = w.integer():min(0):default(300),
      add_on_open = w.boolean():default(true),
    },
    projects = section {
      enabled = w.boolean():default(true),
      roots = w.array(w.union {
        w.string():not_empty(),
        w.object({
          path = w.string():not_empty(),
          max_depth = w.integer():range(1, 16):optional(),
        }):unknown "warn",
      }):default {},
      max_depth = w.integer():range(1, 16):default(4),
      exclude = w.array(w.string()):default {
        "node_modules",
        ".cache",
        ".venv",
        "venv",
        "target",
        "vendor",
        "dist",
        "build",
      },
      fd_path = w.string():optional(),
      include_roots = w.boolean():default(false),
    },
    dirs = section {
      enabled = w.boolean():default(true),
      paths = w.array(w.string():not_empty()):default {},
    },
    domains = section {
      enabled = w.boolean():default(true),
      kinds = w.array(w.enum { "ssh", "sshmux", "wsl", "unix", "tls", "local", "other" })
        :default { "ssh", "sshmux", "wsl", "unix", "tls", "other" },
      ignore = w.array(w.string()):default {},
      ignore_patterns = w.array(w.string()):default {},
      action = w.enum({ "workspace", "tab" }):default "workspace",
    },
    custom = w.array(fn()):default {},
  },

  picker = section {
    title = w.string():default "Harbor",
    fuzzy = w.boolean():default(true),
    description = w.string():optional(),
    show_current = w.boolean():default(true),
    icons = w.boolean():default(true),
    sort = w.enum({ "mru", "alpha", "none" }):default "mru",
    path_width = w.integer():range(10, 200):default(60),
    hints = w.boolean():default(true),
    filter = fn(),
    format = fn(),
    key_table = w.string():not_empty():default "harbor_picker",
    -- Ctrl+N/P/J/K navigate and Ctrl+G/C quit inside InputSelector.
    keys = section {
      delete = keybind("d", "CTRL"),
      rename = keybind("r", "CTRL"),
      new = keybind("a", "CTRL"),
      new_at_path = keybind("o", "CTRL"),
      save = keybind("s", "CTRL"),
    },
  },

  layouts = section {
    dir = w.string():optional(),
    default = w.union({ w.string(), w.table() }):optional(),
    rules = w.array(w.object({
      match = w.union { w.string(), fn() },
      layout = w.union { w.string(), w.table() },
    }):unknown "warn"):default {},
    project_file = w.string():default ".harbor.lua",
    trust_project_files = w.boolean():default(false),
  },

  sessions = section {
    dir = w.string():optional(),
    backup = w.boolean():default(true),
    max_file_bytes = w.integer():min(1024):default(32 * 1024 * 1024),
    scrollback = section {
      enabled = w.boolean():default(true),
      max_lines = w.integer():min(0):default(3500),
      max_pane_bytes = w.integer():min(0):default(512 * 1024),
      remote = w.boolean():default(false),
    },
    processes = section {
      enabled = w.boolean():default(true),
      allow = w.array(w.string():not_empty()):default {},
      mode = w.enum({ "extend", "replace" }):default "extend",
      delay = w.number():range(0, 10):default(0.3),
    },
    autosave = section {
      enabled = w.boolean():default(false),
      interval = w.number():min(10):default(300),
      on_focus_lost = w.boolean():default(false),
      scope = w.enum({ "all", "active" }):default "all",
      exclude = w.array(w.string()):default {},
    },
    restore_on_startup = w.union({ w.boolean(), w.string():not_empty() }):default(false),
  },
}):unknown "warn"

-- ── Live config ────────────────────────────────────────────────────────────

---@type table|nil
local current

---Remove the value at `path` from `t`. Returns false if nothing was removed.
---@param t table
---@param path any[]
---@return boolean
local function drop(t, path)
  if type(path) ~= "table" or #path == 0 then
    return false
  end
  local node = t
  for i = 1, #path - 1 do
    node = type(node) == "table" and node[path[i]] or nil
  end
  if type(node) ~= "table" or node[path[#path]] == nil then
    return false
  end
  node[path[#path]] = nil
  return true
end

---Parse `opts`, log any issues, and fall back to defaults for invalid fields.
---
---Warden rejects the whole value when any field is invalid, so offending
---paths are removed and the rest is parsed again: one typo never discards
---every other option.
---@param opts? table
---@return table config
function M.parse(opts)
  local defaults = M.schema:safe_parse({}).value
  if opts == nil then
    return defaults
  end
  if type(opts) ~= "table" then
    log:error("setup() expects a table, got %s; using defaults", type(opts))
    return defaults
  end

  local work = tbl.deepcopy(opts)
  local result = M.schema:safe_parse(work)
  if not result.ok or #result.warnings > 0 then
    result:log()
  end
  for _ = 1, 32 do
    if result.ok then
      break
    end
    local removed = false
    for _, issue in ipairs(result.issues or {}) do
      removed = drop(work, issue.path) or removed
    end
    if not removed then
      break
    end
    result = M.schema:safe_parse(work)
  end
  if not result.ok then
    log:error "invalid harbor options; using defaults"
    return defaults
  end
  return tbl.deep_extend("force", defaults, result.value or {})
end

---Replace the active config.
---@param opts? table
---@return table config
function M.setup(opts)
  current = M.parse(opts)
  return current
end

---Return the active config, initialising defaults on first use.
---@return table
function M.get()
  if not current then
    current = M.parse()
  end
  return current
end

---Allowlisted process names, honouring `processes.mode`.
---@return table<string, true>
function M.process_allowlist()
  local p = M.get().sessions.processes
  local set = {}
  if p.mode == "extend" then
    for _, name in ipairs(M.DEFAULT_PROCESSES) do
      set[name] = true
    end
  end
  for _, name in ipairs(p.allow) do
    set[name:lower()] = true
  end
  return set
end

return M
