local env = require "spec.support.env"
local mux = require "spec.support.mux"
local wt = require "wezterm"

describe("harbor workspace counts", function()
  local dir, source, fixture, all_windows

  local function build()
    -- "main": two windows (2 tabs, 3 panes + 1 tab, 1 pane); "other": one window.
    local _, p, w1 = fixture.spawn { workspace = "main" }
    p:split {}
    w1:spawn_tab {}
    local _, _, _ = fixture.spawn { workspace = "main" }
    fixture.spawn { workspace = "other" }
    wt._workspaces = { "main", "other", "empty" }
  end

  before_each(function()
    dir = env.setup()
    source = require "harbor.sources.workspaces"
    fixture = mux.new()
    all_windows = wt.mux.all_windows
    wt.mux.all_windows = function()
      return fixture.windows
    end
  end)

  after_each(function()
    wt.mux.all_windows = all_windows
    env.rmdir(dir)
  end)

  it("counts windows, tabs and panes per workspace", function()
    build()
    local counts = source.counts(fixture.windows)
    assert.are.same({ windows = 2, tabs = 3, panes = 4 }, counts.main)
    assert.are.same({ windows = 1, tabs = 1, panes = 1 }, counts.other)
  end)

  it("attaches counts to live entries only when the workspace has windows", function()
    build()
    local by_name = {}
    for _, e in ipairs(source.collect()) do
      by_name[e.name] = e
    end
    assert.are.equal(2, by_name.main.counts.windows)
    assert.is_nil(by_name.empty.counts)
  end)

  it("skips a window that cannot be inspected", function()
    build()
    fixture.windows[1].tabs = function()
      error "boom"
    end
    local counts = source.counts(fixture.windows)
    assert.are.same({ windows = 1, tabs = 1, panes = 1 }, counts.main)
    assert.are.equal(3, #source.collect())
  end)

  it("is off with picker.counts = false", function()
    build()
    env.setup { picker = { counts = false } }
    for _, e in ipairs(source.collect()) do
      assert.is_nil(e.counts)
    end
  end)

  describe("label", function()
    local picker

    before_each(function()
      picker = require "harbor.picker"
    end)

    it("shows 2w 3t 5p style counts", function()
      local label = picker.label({
        kind = "workspace",
        name = "main",
        counts = { windows = 2, tabs = 3, panes = 5 },
      }, { icons = false, path_width = 40 })
      assert.truthy(label:find("2w 3t 5p", 1, true))
    end)

    it("omits the suffix when there are no counts", function()
      local label = picker.label(
        { kind = "workspace", name = "main" },
        { icons = false, path_width = 40 }
      )
      assert.is_nil(label:find "%dw %dt")
    end)
  end)
end)
