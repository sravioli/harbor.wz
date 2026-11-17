---@module "harbor.session.capture"
---@author sravioli
---@license GNU-GPLv2

---Snapshot a workspace into a plain, JSON-safe document.

local wezterm = require "wezterm"

local config = require "harbor.config"
local deps = require "harbor.deps"
local log = require "harbor.logger"
local util = require "harbor.util"

local M = {}

-- ── Text helpers ───────────────────────────────────────────────────────────

---Keep printable text and SGR colour sequences; drop every other escape
---(OSC, DCS, cursor movement, mode switches, ...) so restoring a session
---can never replay hostile terminal sequences.
---@param text string
---@return string
function M.sanitize(text)
  if type(text) ~= "string" or text == "" then
    return ""
  end
  local out, i, n = {}, 1, #text
  while i <= n do
    local esc = text:find("\27", i, true)
    local chunk = text:sub(i, (esc or n + 1) - 1)
    -- C0 controls except tab / newline / carriage return, and DEL.
    out[#out + 1] = chunk:gsub("[%z\1-\8\11\12\14-\26\28-\31\127]", "")
    if not esc then
      break
    end
    local kind = text:sub(esc + 1, esc + 1)
    if kind == "[" then
      -- CSI: params 0x30-0x3F, intermediates 0x20-0x2F, final 0x40-0x7E.
      local params, inter, final, stop = text:match("^([0-?]*)([ -/]*)([@-~])()", esc + 2)
      if not final then
        break -- truncated sequence at the end
      end
      if final == "m" and inter == "" and params:match "^[%d;:]*$" then
        out[#out + 1] = "\27[" .. params .. "m"
      end
      i = stop
    elseif kind == "]" or kind == "P" or kind == "_" or kind == "^" or kind == "X" then
      -- String sequences end with BEL or ST (ESC \).
      local bel = text:find("\7", esc + 2, true)
      local st = text:find("\27\\", esc + 2, true)
      local stop = bel and (not st or bel < st) and bel + 1 or st and st + 2
      if not stop then
        break
      end
      i = stop
    else
      -- nF / Fp / Fe / Fs: intermediates 0x20-0x2F then one final byte.
      local stop = text:match("^[ -/]*[0-~]()", esc + 1)
      i = stop or esc + 1
    end
  end
  return table.concat(out)
end

---Trim trailing blank lines and keep at most `max_bytes` from the end.
---@param text string
---@param max_bytes integer
---@return string
function M.trim(text, max_bytes)
  while text ~= "" do
    local last = text:match "([^\n]*)$"
    if last:gsub("\27%[[%d;:]*m", ""):match "^%s*$" then
      text = #last == #text and "" or text:sub(1, #text - #last - 1)
    else
      break
    end
  end
  if max_bytes > 0 and #text > max_bytes then
    text = text:sub(-max_bytes)
    local nl = text:find "\n"
    if nl then
      text = text:sub(nl + 1)
    end
  end
  return text
end

-- ── Pane tree ──────────────────────────────────────────────────────────────

---Try to split `panes` with a single straight divider.
---@param panes table[] items with left/top/width/height
---@param axis "x"|"y"
---@return table[]|nil first, table[]|nil second
local function try_split(panes, axis)
  local pos = axis == "x" and "left" or "top"
  local len = axis == "x" and "width" or "height"
  local cuts = {}
  for _, p in ipairs(panes) do
    cuts[#cuts + 1] = p[pos] + p[len]
  end
  table.sort(cuts)
  for _, cut in ipairs(cuts) do
    local a, b, ok = {}, {}, true
    for _, p in ipairs(panes) do
      if p[pos] + p[len] <= cut then
        a[#a + 1] = p
      elseif p[pos] >= cut then
        b[#b + 1] = p
      else
        ok = false
        break
      end
    end
    if ok and #a > 0 and #b > 0 then
      return a, b
    end
  end
  return nil
end

---@param panes table[]
---@return number left, number top, number right, number bottom
local function bbox(panes)
  local l, t, r, b = math.huge, math.huge, -math.huge, -math.huge
  for _, p in ipairs(panes) do
    l = math.min(l, p.left)
    t = math.min(t, p.top)
    r = math.max(r, p.left + p.width)
    b = math.max(b, p.top + p.height)
  end
  return l, t, r, b
end

---Build a binary split tree from `panes_with_info()`-shaped items.
---
---Leaves are `{ pane = <leaf data> }`; nodes are
---`{ split = "Right"|"Bottom", size = <fraction of the new pane>, first, second }`.
---Panes that cannot be expressed as a straight split (should not happen with
---WezTerm layouts) are stacked to the right as a fallback.
---@param panes table[]
---@param leaf fun(item: table): table
---@return table
function M.tree(panes, leaf)
  if #panes == 1 then
    return { pane = leaf(panes[1]) }
  end
  for _, axis in ipairs { "x", "y" } do
    local a, b = try_split(panes, axis)
    if a then
      local l, t, r, bt = bbox(panes)
      local _, _, ar, ab = bbox(a)
      local total = axis == "x" and (r - l) or (bt - t)
      local first = axis == "x" and (ar - l) or (ab - t)
      local size = total > 0 and (total - first) / total or 0.5
      return {
        split = axis == "x" and "Right" or "Bottom",
        size = math.max(0.05, math.min(0.95, size)),
        first = M.tree(a, leaf),
        second = M.tree(b, leaf),
      }
    end
  end
  log:warn "irregular pane layout; falling back to stacked splits"
  table.sort(panes, function(x, y)
    return x.left == y.left and x.top < y.top or x.left < y.left
  end)
  local rest = {}
  for i = 2, #panes do
    rest[#rest + 1] = panes[i]
  end
  return {
    split = "Right",
    size = (#panes - 1) / #panes,
    first = { pane = leaf(panes[1]) },
    second = M.tree(rest, leaf),
  }
end

-- ── Panes ──────────────────────────────────────────────────────────────────

---Whether `cwd` or a parent holds a `.git` entry. Checked first so panes
---outside repositories (or on slow mounts) never spawn git.
---@param cwd string
---@return boolean
function M.in_repo(cwd)
  local dir = cwd
  while dir do
    if util.is_dir(dir .. "/.git") then
      return true
    end
    local fh = io.open(dir .. "/.git", "rb") -- worktrees and submodules: a file
    if fh then
      fh:close()
      return true
    end
    local parent = util.dirname(dir)
    -- `.` is what a drive root (`C:/`) climbs to: WezTerm's own directory,
    -- not a parent of the pane's.
    dir = parent ~= dir and parent ~= "." and parent or nil
  end
  return false
end

---Current git branch of `cwd`, or nil outside a repository or on a detached
---HEAD. Results are cached in `cache` (one capture pass), including misses.
---@param cwd string
---@param cache? table<string, string|false>
---@return string|nil
function M.branch(cwd, cache)
  if cache and cache[cwd] ~= nil then
    return cache[cwd] or nil
  end
  local ok, out = false, ""
  if M.in_repo(cwd) then
    ok, out = deps.warp.process.run { "git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD" }
  end
  local branch = ok and deps.warp.string.trim(out) or ""
  if branch == "" or branch == "HEAD" then
    branch = false
  end
  if cache then
    cache[cwd] = branch
  end
  return branch or nil
end

---Executable basename without extension, lowercase.
---@param exe string|nil
---@return string|nil
function M.process_name(exe)
  if type(exe) ~= "string" or exe == "" then
    return nil
  end
  local base = deps.warp.filesystem.basename(exe:gsub("\\", "/")):lower()
  return (base:gsub("%.exe$", ""))
end

---Capture one pane.
---@param item table panes_with_info item
---@param opts { scrollback: table, processes: table, allow: table<string, true> }
---@return table
function M.pane(item, opts)
  local pane = item.pane
  local data = {
    cwd = util.pane_cwd(pane),
    active = item.is_active or nil,
    zoomed = item.is_zoomed or nil,
  }
  local dok, domain = pcall(pane.get_domain_name, pane)
  data.domain = dok and domain or nil
  local tok, title = pcall(pane.get_title, pane)
  data.title = tok and title or nil

  local is_local = data.domain == nil or data.domain == "local"
  if opts.git_branch and is_local and data.cwd then
    opts.branches = opts.branches or {}
    data.branch = M.branch(data.cwd, opts.branches)
  end
  local aok, alt = pcall(pane.is_alt_screen_active, pane)
  alt = aok and alt

  if opts.processes.enabled and is_local then
    local pok, info = pcall(pane.get_foreground_process_info, pane)
    local name = pok and info and M.process_name(info.executable or info.name)
    if name and opts.allow[name] then
      local argv = {}
      for i, a in ipairs(info.argv or {}) do
        argv[i] = tostring(a)
      end
      if #argv == 0 then
        argv[1] = info.executable or name
      end
      data.process = { name = name, argv = argv }
      log:debug("captured process %s", name)
    end
  end

  local sb = opts.scrollback
  if sb.enabled and sb.max_lines > 0 and not alt and (is_local or sb.remote) then
    local ok, text = pcall(pane.get_lines_as_escapes, pane, sb.max_lines)
    if ok and type(text) == "string" then
      text = M.trim(M.sanitize(text), sb.max_pane_bytes)
      if text ~= "" then
        data.scrollback = text
      end
    end
  end
  return data
end

---@param tab any
---@param opts table
---@return table|nil, string|nil
function M.tab(tab, opts)
  local items = {}
  local ok, infos = pcall(tab.panes_with_info, tab)
  if not ok or type(infos) ~= "table" or #infos == 0 then
    return nil, "cannot enumerate tab panes"
  end
  for _, i in ipairs(infos) do
    items[#items + 1] = {
      left = i.left,
      top = i.top,
      width = i.width,
      height = i.height,
      is_active = i.is_active,
      is_zoomed = i.is_zoomed,
      pane = i.pane,
    }
  end
  local tok, title = pcall(tab.get_title, tab)
  return {
    title = tok and title ~= "" and title or nil,
    root = M.tree(items, function(item)
      return M.pane(item, opts)
    end),
  }
end

---Capture one mux window: its tabs and title.
---@param win any
---@param opts table
---@return table|nil entry, string|nil err
function M.window(win, opts)
  local entry = { tabs = {} }
  local tabs_ok, tabs = pcall(win.tabs_with_info, win)
  if not tabs_ok or type(tabs) ~= "table" or #tabs == 0 then
    return nil, "cannot enumerate workspace tabs"
  end
  for _, t in ipairs(tabs) do
    local captured, capture_err = M.tab(t.tab, opts)
    if not captured then
      return nil, capture_err
    end
    captured.active = t.is_active or nil
    entry.tabs[#entry.tabs + 1] = captured
  end
  local gok, title = pcall(win.get_title, win)
  entry.title = gok and title or nil
  return entry
end

---Capture options built once per pass from the session config.
---@return table
function M.options()
  local cfg = config.get().sessions
  return {
    scrollback = cfg.scrollback,
    processes = cfg.processes,
    allow = config.process_allowlist(),
    git_branch = cfg.git_branch,
    branches = {},
  }
end

---Capture every window that belongs to `name`.
---@param name string
---@return table|nil doc, string|nil err
function M.workspace(name)
  local opts = M.options()
  local ok, windows = pcall(wezterm.mux.all_windows)
  if not ok then
    return nil, "cannot enumerate windows"
  end

  local doc = {
    name = name,
    saved_at = os.time(),
    path = require("harbor.state").workspace_path(name),
    windows = {},
  }
  for _, win in ipairs(windows) do
    local wok, ws = pcall(win.get_workspace, win)
    if not wok then
      return nil, "cannot inspect workspace window"
    end
    if ws == name then
      local entry, err = M.window(win, opts)
      if not entry then
        return nil, err
      end
      doc.windows[#doc.windows + 1] = entry
    end
  end
  if #doc.windows == 0 then
    return nil, "workspace has no windows: " .. name
  end
  return doc
end

---Snapshot of one window (all its tabs).
---@param name string
---@param win any mux window
---@return table|nil doc, string|nil err
function M.window_doc(name, win)
  local entry, err = M.window(win, M.options())
  if not entry then
    return nil, err
  end
  return { name = name, saved_at = os.time(), windows = { entry } }
end

---Snapshot of one tab (all its panes).
---@param name string
---@param tab any mux tab
---@return table|nil doc, string|nil err
function M.tab_doc(name, tab)
  local captured, err = M.tab(tab, M.options())
  if not captured then
    return nil, err
  end
  return { name = name, saved_at = os.time(), windows = { { tabs = { captured } } } }
end

---Cheap structural signature used by autosave to skip unchanged workspaces.
---@param name string
---@return string
function M.signature(name)
  local parts = { name }
  local branches = config.get().sessions.git_branch and {} or nil
  local ok, windows = pcall(wezterm.mux.all_windows)
  if not ok then
    return name
  end
  for _, win in ipairs(windows) do
    local wok, ws = pcall(win.get_workspace, win)
    if wok and ws == name then
      local tabs_ok, tabs = pcall(win.tabs, win)
      for _, tab in ipairs(tabs_ok and tabs or {}) do
        local tok, title = pcall(tab.get_title, tab)
        parts[#parts + 1] = "T" .. (tok and title or "")
        local pok, infos = pcall(tab.panes_with_info, tab)
        for _, i in ipairs(pok and infos or {}) do
          local cwd = util.pane_cwd(i.pane)
          local fok, info = pcall(i.pane.get_foreground_process_info, i.pane)
          parts[#parts + 1] = table.concat({
            i.left,
            i.top,
            i.width,
            i.height,
            cwd or "",
            fok and info and M.process_name(info.executable or info.name) or "",
            branches and cwd and M.branch(cwd, branches) or "",
          }, ",")
        end
      end
    end
  end
  return table.concat(parts, "|")
end

return M
