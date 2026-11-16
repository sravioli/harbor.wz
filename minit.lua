---Minimal config for bug reports. Run it in isolation from your own config:
---
---    wezterm --config-file minit.lua
---
---Put your reproduction below the marker. Keep it as small as possible and
---paste the edited file into the bug report.
local wezterm = require "wezterm"
local harbor = wezterm.plugin.require "https://github.com/sravioli/harbor.wz"
local config = wezterm.config_builder()

-- Edit below this line --------------------------------------------------------

harbor.apply_to_config(config)
config.keys = {
  { key = "h", mods = "CTRL|SHIFT", action = harbor.action.pick() },
}

return config
