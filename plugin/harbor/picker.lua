---@module "harbor.picker"
---@author sravioli
---@license GNU-GPLv2

---Fuzzy picker over all sources, with in-picker actions.
---
---In-picker actions use a key table that stays active while the
---InputSelector is open: each action key records the pending action and
---sends Enter, so the selector callback receives the
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

local sessions = {}
local adapter
local key_table_config, key_table_entries

---Install or replace an optional host adapter before apply_to_config().
---Its open(window, pane, session) callback may return a cleanup function.
---Extra native `keys` are registered alongside the picker action keys.
---@param value? { keys?: table[], open: function }
function M.set_adapter(value)
  adapter = value
  key_table_config, key_table_entries = nil, nil
end

local function close(window, pane, session)
  local wid = window:window_id()
  if sessions[wid] ~= session then
    return
  end
  sessions[wid] = nil
  if session.owns_table then
    util.try("picker pop key table", function()
      if window:active_key_table() == session.key_table then
        window:perform_action(act.PopKeyTable, pane)
      end
    end)
  end
  if session.cleanup then
    util.try("picker adapter cleanup", session.cleanup)
  end
end

-- ── Labels ─────────────────────────────────────────────────────────────────

local FALLBACK = { workspace = "W", saved = "S", tab = "T", window = "[]", dir = "D", domain = "@" }

---@param kind string
---@return string
local ICONS = {
  workspace = { "Workspace", "cod_briefcase" },
  saved = { "Session.saved", "md_content_save" },
  tab = { "Status.tab", "md_tab" },
  window = { "Session.window", "md_window_maximize" },
  dir = { "Folder", "md_folder" },
  domain = { "Hostname", "md_server_network" },
}

local function icon(kind)
  local spec = ICONS[kind]
  local glyph = spec and util.icon(spec[1], spec[2]) or ""
  if glyph ~= "" then
    return glyph
  end
  return FALLBACK[kind] or "?"
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
      local age = util.ago(e.saved_at)
      tags[#tags + 1] = age and ("saved " .. age) or "saved"
    end
    if #tags > 0 then
      push(DIM)
      push { Text = "  [" .. table.concat(tags, ", ") .. "]" }
      push "ResetAttributes"
    end
    if e.counts then
      push(DIM)
      push { Text = ("  %dw %dt %dp"):format(e.counts.windows, e.counts.tabs, e.counts.panes) }
      push "ResetAttributes"
    end
    if e.path then
      push(DIM)
      push { Text = "  " .. deps.warp.path.shorten_to(deps.warp.path.tilde(e.path), cfg.path_width) }
      push "ResetAttributes"
    end
  elseif e.kind == "saved" then
    push { Text = e.name }
    push(DIM)
    local age = util.ago(e.saved_at)
    push { Text = "  [restore" .. (age and (", " .. age) or "") .. "]" }
    push "ResetAttributes"
  elseif e.kind == "tab" or e.kind == "window" then
    push { Text = e.name }
    push(DIM)
    push { Text = "  [" .. e.kind .. " snapshot]" }
    push "ResetAttributes"
  elseif e.kind == "dir" then
    push { Text = deps.warp.path.shorten_to(deps.warp.path.tilde(e.path), cfg.path_width) }
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
function M.hints(cfg, bindings)
  local parts = {}
  for _, k in ipairs(bindings or M.key_table(cfg)) do
    local mods = k.mods and k.mods ~= "" and (k.mods:gsub("|", "+") .. "+") or ""
    parts[#parts + 1] = ("%s%s %s"):format(mods, k.key, k.desc)
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
function M.key_table(cfg)
  cfg = cfg or config.get().picker
  if key_table_config == cfg then
    return key_table_entries
  end
  local entries = {}
  for _, name in ipairs(M.ACTIONS) do
    local k = cfg.keys[name]
    if k then
      entries[#entries + 1] = {
        key = k.key,
        mods = k.mods,
        desc = name:gsub("_", " "),
        action = wezterm.action_callback(function(window, pane)
          local session = sessions[window:window_id()]
          if not session or not session.owns_table or session.key_table ~= cfg.key_table then
            return
          end
          session.pending = name
          local ok = util.try(
            "picker action key",
            window.perform_action,
            window,
            act.SendKey { key = "Enter" },
            pane
          )
          if not ok then
            close(window, pane, session)
          end
        end),
      }
    end
  end
  if adapter and cfg.hints and cfg.hint_position == "status" then
    for _, entry in ipairs(adapter.keys or {}) do
      entries[#entries + 1] = entry
    end
  end
  key_table_config, key_table_entries = cfg, entries
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
  elseif e.kind == "tab" or e.kind == "window" then
    workspace.load_snapshot(e.kind, window, pane, e.name)
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
    local default = e and e.path and deps.warp.path.tilde(e.path) or nil
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
    local run, ask
    if e.kind == "workspace" then
      ask = {
        title = "harbor: close workspace",
        question = ("Close workspace %q?"):format(e.name),
        yes = "Close " .. e.name,
        yes_hint = e.saved and "ends its panes; the saved session is kept"
          or "ends all its tabs and panes",
        no = "Cancel",
        no_hint = "keep it open",
      }
      run = function(w, p)
        workspace.close(w, p, e.name)
      end
    elseif e.kind == "saved" then
      ask = {
        title = "harbor: delete saved session",
        question = ("Delete saved session %q?"):format(e.name),
        yes = "Delete " .. e.name,
        yes_hint = "removes the session file; this cannot be undone",
        no = "Cancel",
        no_hint = "keep the session",
      }
      run = function(w, p)
        workspace.forget(w, p, e.name)
      end
    elseif e.kind == "tab" or e.kind == "window" then
      ask = {
        title = "harbor: delete snapshot",
        question = ("Delete %s snapshot %q?"):format(e.kind, e.name),
        yes = "Delete " .. e.name,
        yes_hint = "removes the snapshot file; this cannot be undone",
        no = "Cancel",
        no_hint = "keep the snapshot",
      }
      run = function(w, p)
        workspace.forget_snapshot(e.kind, w, p, e.name)
      end
    else
      -- The selector already closed (actions send Enter); reopen it with the
      -- reason on top instead of a toast that is easy to miss.
      local what = e.kind == "dir" and "a directory" or ("a " .. tostring(e.kind))
      local target = e.kind == "dir" and deps.warp.path.tilde(e.path or "")
        or tostring(e.domain or e.name or "?")
      local again = {}
      for k, v in pairs(opts or {}) do
        again[k] = v
      end
      local reason = "Only workspaces, saved sessions and snapshots can be deleted."
      again.notice = ("Can't delete %s: it is %s. %s"):format(target, what, reason)
      reopen(window, pane, again)
      return
    end
    local function done(w, p)
      reopen(w, p, opts)
    end
    if config.get().picker.confirm then
      util.confirm(window, pane, ask, function(w, p)
        run(w, p)
        done(w, p)
      end, done)
    else
      run(window, pane)
      done(window, pane)
    end
  elseif action == "rename" then
    if e.kind == "workspace" or e.kind == "saved" or e.kind == "tab" or e.kind == "window" then
      prompt(window, pane, "Rename " .. e.name, e.name, function(new)
        if e.kind == "workspace" then
          workspace.rename(window, pane, e.name, new)
        else
          local ok, err = require("harbor.session.store").rename(
            e.name,
            new,
            (e.kind == "tab" or e.kind == "window") and e.kind or nil
          )
          if not ok then
            log:warn("rename failed: %s", err)
            util.notify(window, "Rename failed: " .. tostring(err))
          elseif e.kind == "saved" then
            -- `has_session` caches by name for 30 s.
            local state = require "harbor.state"
            state.invalidate("session:" .. e.name)
            state.invalidate("session:" .. new)
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
---@param opts? { kinds?: table<string, boolean>, title?: string, actions?: boolean, notice?: string }
function M.open(window, pane, opts)
  opts = opts or {}
  local cfg = config.get().picker
  local wid = window:window_id()
  if sessions[wid] then
    close(window, pane, sessions[wid])
  end
  local session = { key_table = cfg.key_table }
  sessions[wid] = session
  local ok = util.try("picker open", function()
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
    if use_actions and window.effective_config then
      local tables = window:effective_config().key_tables
      use_actions = tables ~= nil and tables[cfg.key_table] ~= nil
    end
    local bindings = {
      { key = "Enter", mods = "", desc = "open", action = act.SendKey { key = "Enter" } },
    }
    if use_actions then
      for _, binding in ipairs(M.key_table(cfg)) do
        bindings[#bindings + 1] = binding
      end
    end
    bindings[#bindings + 1] = {
      key = "Escape",
      mods = "",
      desc = "cancel",
      action = act.SendKey { key = "Escape" },
    }
    local description = cfg.description
    if not description and cfg.hints and cfg.hint_position == "top" then
      description = M.hints(cfg, bindings)
    end
    if opts.notice then
      -- One-shot: later reopens from this picker must not repeat it.
      description = opts.notice .. (description and ("   |   " .. description) or "")
      opts.notice = nil
    end

    if use_actions then
      window:perform_action(act.ActivateKeyTable { name = cfg.key_table, one_shot = false }, pane)
      session.owns_table = true
    end
    if adapter and use_actions and cfg.hints and cfg.hint_position == "status" then
      session.bindings = bindings
      session.cleanup = adapter.open(window, pane, session)
    end

    util.emit("picker.opened", window, pane, { title = opts.title or cfg.title, count = #choices })
    window:perform_action(
      act.InputSelector {
        title = opts.title or cfg.title,
        fuzzy = cfg.fuzzy,
        description = description,
        fuzzy_description = "Search: ",
        choices = choices,
        action = wezterm.action_callback(function(w, p, id)
          if sessions[wid] ~= session then
            return
          end
          local action = session.pending
          close(w, p, session)
          local e = id and by_id[id] or nil
          if action then
            util.try("picker dispatch", M.dispatch, action, w, p, e, opts)
          elseif e then
            util.emit("picker.selected", w, p, { entry = e })
            util.try("picker accept", M.open_entry, w, p, e)
          else
            util.emit("picker.canceled", w, p, {})
          end
        end),
      },
      pane
    )
  end)
  if not ok then
    close(window, pane, session)
  end
end

return M
