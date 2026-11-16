---@module "harbor.mosaic.session"
---@author sravioli
---@license GNU-GPLv2

---mosaic integration `harbor.session`: a marker while the active workspace
---has a saved session. mosaic reads this file only when a layout names it.
---
---Options (`options["harbor.session"]`):
---  icon? string|false  glyph (default: md_content_save); false hides it
---  name? boolean       also show the workspace name (default: false)

return {
  api = 1,
  events = {
    "harbor.session.saved",
    "harbor.session.deleted",
    "harbor.workspace.switched",
    "harbor.workspace.renamed",
  },
  new = function(opts)
    local wezterm = require "wezterm"
    local harbor = require "harbor.api"

    local icon = opts.icon
    if icon == nil then
      icon = (wezterm.nerdfonts or {}).md_content_save or ""
    end
    local show_name = opts.name == true

    return function(window)
      local name = window:active_workspace()
      if not harbor.has_session(name) then
        return { enabled = false }
      end
      return {
        enabled = true,
        cond = true,
        can_hide = true,
        padding = { left = 1 },
        accent = 3, -- colour hint; the preset styles the module
        icon = {
          enabled = icon ~= false and icon ~= "",
          value = icon or "",
          padding = show_name and { right = 1 } or 0,
        },
        text = { enabled = show_name, value = name },
      }
    end
  end,
}
