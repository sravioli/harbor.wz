---@module "harbor.util"
---@author sravioli
---@license GNU-GPLv2

---Small glue helpers on top of warp: path keys, display paths, events,
---protected calls and the data directory.

local wezterm = require "wezterm"

local deps = require "harbor.deps"
local log = require "harbor.logger"

local fs = deps.warp.filesystem
local path = deps.warp.path
local process = deps.warp.process

local M = {}

-- ── Paths ──────────────────────────────────────────────────────────────────

---Normalize a path coming from zoxide, fd, panes or user config.
---
---Expands `~`, strips the drive slash of `file:///C:/...` URLs, then defers
---to `warp.path.normalize` (forward slashes, no trailing separator, `.`/`..`
---resolved, drive/UNC roots and Windows verbatim prefixes preserved).
---@param p string|nil
---@return string|nil
function M.clean_path(p)
  if type(p) ~= "string" or p == "" then
    return nil
  end
  p = path.expand(p)
  p = p:gsub("^[/\\](%a:)$", "%1"):gsub("^[/\\](%a:[/\\])", "%1")
  return path.normalize(p)
end

---Identity key for de-duplication (case-insensitive on Windows).
---@param p string|nil
---@return string|nil
function M.path_key(p)
  local c = M.clean_path(p)
  if c and fs.is_win then
    return c:lower()
  end
  return c
end

---@param p string
---@return string|nil parent, or nil when `p` has no parent component
function M.dirname(p)
  if not p:find "[/\\]" then
    return nil
  end
  return path.dirname(p)
end

---Current directory of `pane`, normalized (nil when unknown).
---
---warp handles Url userdata and legacy `file://host/path` strings,
---including percent-decoding.
---@param pane any
---@return string|nil
function M.pane_cwd(pane)
  if not pane then
    return nil
  end
  local ok, p = pcall(fs.get_cwd, pane)
  if not ok or not p or p == "" then
    return nil
  end
  return M.clean_path(p)
end

---@param p string
---@return boolean
function M.is_dir(p)
  local ok, res = pcall(fs.is_dir, p)
  return ok and res == true
end

---Directory for harbor's persistent files.
---@return string
function M.data_dir()
  local configured = require("harbor.config").get().sessions.dir
  if configured then
    return M.clean_path(configured) --[[@as string]]
  end
  if fs.platform().is_mac then
    -- harbor used Application Support before warp's state_dir; keep it while it exists.
    local legacy = fs.home .. "/Library/Application Support/wezterm/harbor"
    if M.is_dir(legacy) then
      return legacy
    end
  end
  return (fs.state_dir() or ".") .. "/harbor"
end

---Create `dir` (and parents) without a shell.
---@param dir string
---@return boolean ok
function M.mkdir(dir)
  local ok, err = fs.mkdir(dir)
  if not ok then
    log:warn("%s", err)
  end
  return ok
end

-- ── Executables ────────────────────────────────────────────────────────────

---Path to the running wezterm binary (for `wezterm cli`).
---@return string
function M.wezterm_exe()
  local dir = wezterm.executable_dir and wezterm.executable_dir:gsub("\\", "/")
  if dir and dir ~= "" then
    local exe = dir .. "/wezterm" .. (fs.is_win and ".exe" or "")
    return process.which("wezterm", { path = exe }) or exe
  end
  return process.which "wezterm" or "wezterm"
end

-- ── Calls and events ───────────────────────────────────────────────────────

---Call a user hook; log and swallow errors.
---@param label string
---@param f function|nil
---@return boolean ok, any result
function M.try(label, f, ...)
  if type(f) ~= "function" then
    return false, nil
  end
  local ok, res = pcall(f, ...)
  if not ok then
    log:error("%s failed: %s", label, res)
    return false, nil
  end
  return true, res
end

---Emit `harbor.<name>` with a consistent `(window, pane, payload)` shape.
---@param name    string
---@param window  any
---@param pane    any
---@param payload table|nil
function M.emit(name, window, pane, payload)
  local ok, err = pcall(wezterm.emit, "harbor." .. name, window, pane, payload or {})
  if not ok then
    log:error("event harbor.%s handler failed: %s", name, err)
  end
end

---Show a short toast when a GUI window is available.
---@param window any
---@param msg string
function M.notify(window, msg)
  if window and window.toast_notification then
    pcall(window.toast_notification, window, "harbor", msg, nil, 3000)
  end
end

---@class harbor.Confirm
---@field question string  One line shown above the choices (plain text).
---@field title?    string  Window title while the selector is open.
---@field yes?      string  Label of the confirming choice (default "Yes").
---@field yes_hint? string  Dimmed consequence shown after `yes`.
---@field no?       string  Label of the declining choice (default "Cancel").
---@field no_hint?  string  Dimmed note shown after `no`.

---Render one confirm choice; falls back to plain text when formatting fails.
---@param glyph string|nil
---@param text string
---@param hint string|nil
---@param danger boolean
---@return string
local function choice_label(glyph, text, hint, danger)
  local items = { { Text = " " .. (glyph and (glyph .. "  ") or "") } }
  if danger then
    items[#items + 1] = { Foreground = { AnsiColor = "Red" } }
    items[#items + 1] = { Attribute = { Intensity = "Bold" } }
  end
  items[#items + 1] = { Text = text }
  items[#items + 1] = "ResetAttributes"
  if hint then
    items[#items + 1] = { Attribute = { Intensity = "Half" } }
    items[#items + 1] = { Text = "  " .. hint }
    items[#items + 1] = "ResetAttributes"
  end
  local ok, s = pcall(wezterm.format, items)
  return ok and s or (text .. (hint and ("  " .. hint) or ""))
end

---Ask a yes/no question in a selector. The safe choice comes first so a
---stray Enter is harmless; Escape also counts as no.
---@param window any
---@param pane any
---@param spec string|harbor.Confirm  A plain question, or a full spec.
---@param on_yes fun(window: any, pane: any)
---@param on_no? fun(window: any, pane: any)
function M.confirm(window, pane, spec, on_yes, on_no)
  if type(spec) == "string" then
    spec = { question = spec }
  end
  local nf = wezterm.nerdfonts or {}
  window:perform_action(
    wezterm.action.InputSelector {
      title = spec.title or spec.question,
      description = spec.question .. "   Enter: choose   Esc: cancel",
      fuzzy = false,
      choices = {
        {
          id = "no",
          label = choice_label(nf.md_arrow_u_left_top, spec.no or "Cancel", spec.no_hint, false),
        },
        {
          id = "yes",
          label = choice_label(nf.md_delete, spec.yes or "Yes", spec.yes_hint, true),
        },
      },
      action = wezterm.action_callback(function(w, p, id)
        if id == "yes" then
          M.try("confirmed action", on_yes, w, p)
        elseif on_no then
          M.try("declined action", on_no, w, p)
        end
      end),
    },
    pane
  )
end

---Compact age of a unix timestamp ("just now", "5m ago", "3d ago").
---@param at number|nil
---@param now? number
---@return string|nil
function M.ago(at, now)
  if type(at) ~= "number" or at <= 0 then
    return nil
  end
  local d = math.max(0, (now or os.time()) - at)
  if d < 60 then
    return "just now"
  elseif d < 3600 then
    return ("%dm ago"):format(math.floor(d / 60))
  elseif d < 86400 then
    return ("%dh ago"):format(math.floor(d / 3600))
  end
  return ("%dd ago"):format(math.floor(d / 86400))
end

---Schedule `f` without ever raising into WezTerm.
---@param delay number
---@param f function
function M.later(delay, f)
  if wezterm.time and wezterm.time.call_after then
    wezterm.time.call_after(delay, function()
      M.try("scheduled task", f)
    end)
  else
    M.try("scheduled task", f)
  end
end

return M
