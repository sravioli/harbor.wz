---@module "harbor.picker"
---@author sravioli
---@license GNU-GPLv2

---Fuzzy picker over all sources, with in-picker actions.
---
---In-picker actions use a key table that stays active while the
---InputSelector is open: each action key records the pending action, pops
---the table and sends Enter, so the selector callback receives the
---highlighted item (technique from workspace-manager.wezterm).

local wezterm = require "wezterm"

local config = require "harbor.config"
local deps = require "harbor.deps"
local log = require "harbor.logger"
local sources = require "harbor.sources"
local util = require "harbor.util"
local workspace = require "harbor.workspace"

local act = wezterm.action

local M = {}

M.ACTIONS = { "delete", "rename", "new", "new_at_path", "save" }

---Pending action per GUI window id.
---@type table<any, string>
local pending = {}

-- ── Labels ─────────────────────────────────────────────────────────────────

local FALLBACK = { workspace = "W", saved = "S", dir = "D", domain = "@" }

---@param kind string
---@return string
local function icon(kind)
  local sigil = deps.sigil
  if sigil then
    local key = ({ workspace = "Workspace", dir = "Folder", domain = "Hostname" })[kind]
    local ok, sym = pcall(function()
      return key and sigil.symbol(key)
    end)
    if ok and type(sym) == "string" then
      return sym
    end
  end
  local nf = wezterm.nerdfonts or {}
  local glyph = ({
    workspace = "cod_briefcase",
    saved = "md_content_save",
    dir = "md_folder",
    domain = "md_server_network",
  })[kind]
  return (glyph and nf[glyph]) or FALLBACK[kind] or "?"
end

local DIM = { Attribute = { Intensity = "Half" } }

---Default label for an entry (wezterm.format string).
---@param e harbor.Entry
---@param cfg table picker config
---@return string
function M.label(e, cfg)
  if e.label then
    return e.label
  end
  local items = {}
  local function push(item)
    items[#items + 1] = item
  end
  if cfg.icons then
    push { Text = icon(e.kind) .. "  " }
  end

  if e.kind == "workspace" then
    push { Attribute = { Intensity = e.current and "Bold" or "Normal" } }
    push { Text = e.name }
    push "ResetAttributes"
    local tags = {}
    if e.current then
      tags[#tags + 1] = "current"
    elseif e.previous then
      tags[#tags + 1] = "previous"
    end
    if e.saved then
      tags[#tags + 1] = "saved"
    end
    if #tags > 0 then
      push(DIM)
      push { Text = "  [" .. table.concat(tags, ", ") .. "]" }
      push "ResetAttributes"
    end
    if e.path then
      push(DIM)
      push { Text = "  " .. deps.warp.path.shorten_to(util.tilde(e.path), cfg.path_width) }
      push "ResetAttributes"
    end
  elseif e.kind == "saved" then
    push { Text = e.name }
    push(DIM)
    push { Text = "  [restore]" }
    push "ResetAttributes"
  elseif e.kind == "dir" then
    push { Text = deps.warp.path.shorten_to(util.tilde(e.path), cfg.path_width) }
    push(DIM)
    push { Text = "  " .. (e.source or "dir") }
    push "ResetAttributes"
  elseif e.kind == "domain" then
    push { Text = e.domain }
    push(DIM)
    push { Text = "  " .. (e.domain_kind or "domain") }
    push "ResetAttributes"
  end

  local ok, s = pcall(function()
    if deps.ribbon then
      return deps.ribbon.new("harbor", false):append_items(items):format()
    end
    return wezterm.format(items)
  end)
  return ok and s or (e.name or e.path or e.domain or "?")
end

---Hint line built from the same key config as the key table.
---@param cfg table picker config
---@return string
function M.hints(cfg)
  local parts = {}
  for _, name in ipairs(M.ACTIONS) do
    local k = cfg.keys[name]
    if k then
      local mods = k.mods and k.mods ~= "" and (k.mods:gsub("|", "+") .. "+") or ""
      parts[#parts + 1] = ("%s%s %s"):format(mods, k.key, (name:gsub("_", " ")))
    end
  end
  return table.concat(parts, "  ")
end

-- ── Key table ──────────────────────────────────────────────────────────────

---Key table entries for in-picker actions (register via apply_to_config).
---
---Action keys record the pending action and send Enter to the selector.
---The selector callback (which runs on accept *and* cancel) pops the table
---exactly once, so Enter/Escape/Ctrl+G/clicks need no entries here.
---@return table[]
function M.key_table()
  local cfg = config.get().picker
  local entries = {}
  for _, name in ipairs(M.ACTIONS) do
    local k = cfg.keys[name]
    if k then
      entries[#entries + 1] = {
        key = k.key,
        mods = k.mods,
        action = wezterm.action_callback(function(window, pane)
          pending[window:window_id()] = name
          window:perform_action(act.SendKey { key = "Enter" }, pane)
        end),
      }
    end
  end
  return entries
end

-- ── Dispatch ───────────────────────────────────────────────────────────────

---Re-open the picker shortly (after an overlay closed).
---@param window any
---@param pane any
---@param opts table
local function reopen(window, pane, opts)
  util.later(0.1, function()
    M.open(window, pane, opts)
  end)
end

---@param window any
---@param pane any
---@param title string
---@param default string|nil
---@param fn fun(text: string)
---@param on_cancel? fun()
local function prompt(window, pane, title, default, fn, on_cancel)
  window:perform_action(
    act.PromptInputLine {
      description = title,
      initial_value = default,
      action = wezterm.action_callback(function(w, p, line)
        if line and line ~= "" then
          util.try("prompt action", fn, line, w, p)
        elseif on_cancel then
          on_cancel()
        end
      end),
    },
    pane
  )
end

---Default (Enter) action for an entry.
---@param window any
---@param pane any
---@param e harbor.Entry
function M.open_entry(window, pane, e)
  if e.kind == "workspace" then
    workspace.switch(window, pane, e.name)
  elseif e.kind == "saved" then
    workspace.restore(window, pane, e.name)
  elseif e.kind == "dir" then
    workspace.open_dir(window, pane, e.path)
  elseif e.kind == "domain" then
    workspace.open_domain(window, pane, e.domain)
  end
end

---Run an in-picker action.
---@param action string
---@param window any
---@param pane any
---@param e harbor.Entry|nil
---@param opts table picker opts (for reopening)
function M.dispatch(action, window, pane, e, opts)
  if action == "new" then
    prompt(window, pane, "New workspace name", nil, function(name)
      workspace.create(window, pane, name)
    end, function()
      reopen(window, pane, opts)
    end)
    return
  elseif action == "new_at_path" then
    local default = e and e.path and util.tilde(e.path) or nil
    prompt(window, pane, "Open workspace at path", default, function(p)
      workspace.open_dir(window, pane, p)
    end, function()
      reopen(window, pane, opts)
    end)
    return
  end

  if not e then
    reopen(window, pane, opts)
    return
  end

  if action == "delete" then
    if e.kind == "workspace" then
      workspace.close(window, pane, e.name)
    elseif e.kind == "saved" then
      workspace.forget(window, pane, e.name)
    else
      util.notify(window, "Nothing to delete")
    end
    reopen(window, pane, opts)
  elseif action == "rename" then
    if e.kind == "workspace" or e.kind == "saved" then
      prompt(window, pane, "Rename " .. e.name, e.name, function(new)
        if e.kind == "workspace" then
          workspace.rename(window, pane, e.name, new)
        else
          local ok, err = require("harbor.session.store").rename(e.name, new)
          if not ok then
            log:warn("rename failed: %s", err)
          end
        end
        reopen(window, pane, opts)
      end, function()
        reopen(window, pane, opts)
      end)
    else
      reopen(window, pane, opts)
    end
  elseif action == "save" then
    if e.kind == "workspace" then
      workspace.save(window, pane, e.name)
    end
    reopen(window, pane, opts)
  else
    M.open_entry(window, pane, e)
  end
end

-- ── Open ───────────────────────────────────────────────────────────────────

---Open the picker.
---@param window any
---@param pane any
---@param opts? { kinds?: table<string, boolean>, title?: string, actions?: boolean }
function M.open(window, pane, opts)
  opts = opts or {}
  local cfg = config.get().picker
  local entries = sources.list { current = workspace.active(), kinds = opts.kinds }

  local by_id, choices = {}, {}
  for _, e in ipairs(entries) do
    by_id[e.id] = e
    local label = M.label(e, cfg)
    if cfg.format then
      local ok, res = util.try("picker.format", cfg.format, e, label)
      if ok and type(res) == "string" then
        label = res
      end
    end
    choices[#choices + 1] = { id = e.id, label = label }
  end

  local use_actions = opts.actions ~= false and require("harbor.state").key_table_ready
  local description = cfg.description
  if not description and use_actions and cfg.hints then
    description = "Enter open  " .. M.hints(cfg) .. "  Esc cancel"
  end

  local wid = window:window_id()
  pending[wid] = nil

  window:perform_action(
    act.InputSelector {
      title = opts.title or cfg.title,
      fuzzy = cfg.fuzzy,
      description = description,
      fuzzy_description = description and (description .. "\n> ") or nil,
      choices = choices,
      action = wezterm.action_callback(function(w, p, id)
        local action = pending[wid]
        pending[wid] = nil
        if use_actions then
          pcall(w.perform_action, w, act.PopKeyTable, p)
        end
        local e = id and by_id[id] or nil
        if action then
          M.dispatch(action, w, p, e, opts)
        elseif e then
          M.open_entry(w, p, e)
        end
      end),
    },
    pane
  )

  if use_actions then
    window:perform_action(act.ActivateKeyTable { name = cfg.key_table, one_shot = false }, pane)
  end
end

return M
