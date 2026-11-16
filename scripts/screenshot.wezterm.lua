-- Minimal WezTerm config for `scripts/screenshots.sh`: a window with a small
-- bar from mosaic.wz (https://github.com/sravioli/mosaic.wz) in the kanagawa
-- scheme ($HARBOR_KANAGAWA: "wave" dark, "lotus" light) of the kanagawa plugin
-- (https://github.com/kanagawa-community/wezterm) and the scene named by $HARBOR_SCENE open. Settings come from the
-- environment so the script stays the only place that knows the defaults.
local wezterm = require "wezterm"
local act = wezterm.action

local repo = assert(os.getenv "HARBOR_REPO", "HARBOR_REPO is not set")
local scene = assert(os.getenv "HARBOR_SCENE", "HARBOR_SCENE is not set")
-- Bar-only scenes: an undecorated one-row window the script crops to the bar.
local bar_only = scene:match "^%s$" ~= nil
for _, name in ipairs { "mosaic", "warp", "log", "warden", "sigil", "ribbon", "memo" } do
  local base = repo .. "/../" .. name .. ".wz/plugin/"
  package.path = base .. "?.lua;" .. base .. "?/init.lua;" .. package.path
end
package.path = repo .. "/plugin/?.lua;" .. repo .. "/plugin/?/init.lua;" .. package.path

local kanagawa = wezterm.plugin.require "https://github.com/kanagawa-community/wezterm"

local harbor = require "harbor.api"
local mosaic = require "mosaic.api"
mosaic.setup {
  preset = "minimal",
  position = "top",
  layout = { left = { "workspace", "harbor.session" }, right = { "clock" } },
  options = { ["harbor.session"] = { name = true } },
}
-- Only demo data: no zoxide history or saved sessions of the machine the shots
-- are taken on, and sessions go to a throwaway dir.
harbor.setup {
  sessions = { dir = assert(os.getenv "HARBOR_SESSIONS", "HARBOR_SESSIONS is not set") },
  sources = {
    zoxide = { enabled = false },
    projects = { roots = { assert(os.getenv "HARBOR_DEMO", "HARBOR_DEMO is not set") } },
    dirs = { paths = { "/usr/share", "/usr/lib", "/etc" } }, -- they must exist
  },
}

local config = wezterm.config_builder()
config.font = wezterm.font_with_fallback {
  os.getenv "HARBOR_FONT" or "FiraCode Nerd Font",
  "Symbols Nerd Font",
}
config.font_size = tonumber(os.getenv "HARBOR_FONT_SIZE" or 14)
config.initial_cols = tonumber(os.getenv "HARBOR_COLS" or 100)
config.initial_rows = tonumber(os.getenv "HARBOR_ROWS" or 30)
config.enable_wayland = false -- XWayland: KDE draws the frame and title bar
config.window_decorations = "TITLE | RESIZE"
config.window_padding = { left = 8, right = 8, top = 8, bottom = 8 }
config.enable_scroll_bar = false
config.use_fancy_tab_bar = false
config.hide_tab_bar_if_only_one_tab = false
config.tab_max_width = 24
config.check_for_updates = false
-- The scheme first: mosaic draws the new-tab button in the scheme set when it is applied.
kanagawa.apply_to_config(config, { scheme = os.getenv "HARBOR_KANAGAWA" or "wave" })
mosaic.apply_to_config(config)
harbor.apply_to_config(config)
config.ssh_domains = {
  { name = "homelab", remote_address = "homelab.example.com" },
  { name = "workstation", remote_address = "workstation.example.com" },
}

if bar_only then
  config.window_decorations = "NONE"
  config.initial_cols = tonumber(os.getenv "HARBOR_BAR_COLS" or 140)
  config.initial_rows = 1 -- the bar plus one row; the script keeps only the bar
  config.window_padding = { left = 0, right = 0, top = 0, bottom = 0 }
end

-- The title bar names the feature on show.
wezterm.on("format-window-title", function()
  return "harbor: " .. scene
end)

-- Pane content that stays open: fastfetch with a config that prints a logo and
-- colour blocks only, so nothing about the machine the shots are taken on shows.
local demo = { "sh", "-c", ("fastfetch -c %q; exec sleep 100000"):format(repo .. "/scripts/fastfetch.jsonc") }

-- scene name -> function(window, pane) that opens it.
local scenes = {
  pick = function(w, p) w:perform_action(harbor.action.pick(), p) end,
  workspaces = function(w, p) w:perform_action(harbor.action.workspaces(), p) end,
  projects = function(w, p) w:perform_action(harbor.action.projects(), p) end,
  domains = function(w, p) w:perform_action(harbor.action.domains(), p) end,
  -- Save the workspace first, so there is a session to list.
  sessions = function(w, p)
    w:perform_action(harbor.action.save(), p)
    wezterm.time.call_after(1, function()
      w:perform_action(harbor.action.sessions(), p)
    end)
  end,
}

wezterm.on("gui-startup", function()
  for _, name in ipairs { "dev", "notes" } do
    wezterm.mux.spawn_window { workspace = name, cwd = wezterm.home_dir }
  end
  local tab, pane, window = wezterm.mux.spawn_window({ args = demo, workspace = "default", cwd = wezterm.home_dir })
  tab:set_title "dotfiles"
  -- A split with some output behind the overlay, and two more tabs for the bar.
  if not bar_only then
    pane:split { direction = "Right", args = demo }
  end
  pane:activate()
  for _, title in ipairs { "notes", "build" } do
    window:spawn_tab({ cwd = wezterm.home_dir }):set_title(title)
  end
  tab:activate()
  -- The GUI window exists only after startup returns.
  wezterm.time.call_after(1, function()
    scenes[scene](window:gui_window(), pane)
  end)
end)

return config
