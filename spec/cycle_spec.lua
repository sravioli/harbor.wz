local env = require "spec.support.env"
local wt = require "wezterm"

describe("harbor workspace cycling", function()
  local ws, dir

  before_each(function()
    dir = env.setup()
    ws = require "harbor.workspace"
    wt._workspaces = { "zeta", "alpha", "mid" }
    wt._active_workspace = "mid"
  end)

  after_each(function()
    env.rmdir(dir)
  end)

  it("moves to the next workspace alphabetically", function()
    assert.is_true(ws.cycle(nil, nil, 1))
    assert.are.equal("zeta", wt._active_workspace)
  end)

  it("wraps around in both directions", function()
    wt._active_workspace = "zeta"
    assert.is_true(ws.cycle(nil, nil, 1))
    assert.are.equal("alpha", wt._active_workspace)
    assert.is_true(ws.cycle(nil, nil, -1))
    assert.are.equal("zeta", wt._active_workspace)
  end)

  it("goes back one step", function()
    assert.is_true(ws.cycle(nil, nil, -1))
    assert.are.equal("alpha", wt._active_workspace)
  end)

  it("does nothing with a single workspace", function()
    wt._workspaces = { "only" }
    wt._active_workspace = "only"
    assert.is_false(ws.cycle(nil, nil, 1))
    assert.are.equal("only", wt._active_workspace)
  end)

  it("records the switch in history", function()
    ws.cycle(nil, nil, 1)
    assert.are.equal("mid", require("harbor.history").previous())
  end)

  it("exposes cycle and the next/prev actions", function()
    local api = require "harbor.api"
    assert.is_function(api.cycle)
    assert.is_not_nil(api.action.next())
    assert.is_not_nil(api.action.prev())
  end)
end)
