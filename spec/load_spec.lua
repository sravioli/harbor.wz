describe("harbor modules", function()
  local mods = {
    "harbor.deps",
    "harbor.logger",
    "harbor.config",
    "harbor.util",
    "harbor.naming",
    "harbor.history",
    "harbor.state",
    "harbor.layout",
    "harbor.workspace",
    "harbor.picker",
    "harbor.sources",
    "harbor.sources.zoxide",
    "harbor.sources.projects",
    "harbor.sources.dirs",
    "harbor.sources.saved",
    "harbor.sources.domains",
    "harbor.sources.workspaces",
    "harbor.session.store",
    "harbor.session.capture",
    "harbor.session.restore",
    "harbor.session.auto",
    "harbor.api",
  }
  for _, m in ipairs(mods) do
    it("loads " .. m .. " without spawning processes", function()
      local wezterm = require "wezterm"
      wezterm._child_calls = {}
      assert.is_table(require(m))
      assert.are.equal(0, #wezterm._child_calls)
    end)
  end
end)
