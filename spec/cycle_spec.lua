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

  it("exposes cycle and the cycle_next/cycle_prev actions", function()
    local api = require "harbor.api"
    assert.is_function(api.cycle)
    assert.is_not_nil(api.action.cycle_next())
    assert.is_not_nil(api.action.cycle_prev())
  end)

  it("keeps next/prev as aliases that warn once", function()
    local api = require "harbor.api"
    local wezterm = require "wezterm"
    local function warnings()
      local n = 0
      for _, call in ipairs(wezterm._calls or {}) do
        if call.fn == "log_warn" and tostring(call.args[1]):find("deprecated", 1, true) then
          n = n + 1
        end
      end
      return n
    end
    local before = warnings()
    assert.is_not_nil(api.action.next())
    assert.is_not_nil(api.action.next())
    assert.is_not_nil(api.action.prev())
    assert.are.equal(before + 2, warnings())
  end)
end)

describe("harbor switch events", function()
  local dir

  before_each(function()
    dir = env.setup()
    wt._workspaces = { "a", "b" }
    wt._active_workspace = "a"
  end)

  after_each(function()
    env.rmdir(dir)
  end)

  it("emits switching before switched, with the outgoing workspace", function()
    require("harbor.workspace").switch(nil, nil, "b")
    local names = {}
    for _, event in ipairs(wt._emitted) do
      names[#names + 1] = event.name
    end
    assert.are.same({ "harbor.workspace.switching", "harbor.workspace.switched" }, names)
    assert.are.same({ name = "b", from = "a" }, wt._emitted[1].args[3])
  end)

  it("stays quiet when already on the workspace", function()
    require("harbor.workspace").switch(nil, nil, "a")
    assert.are.equal(0, #wt._emitted)
  end)

  it("lists every emitted event name", function()
    local listed = {}
    for _, name in ipairs(require("harbor.api").events) do
      listed[name] = true
    end
    for _, name in ipairs {
      "harbor.workspace.switching",
      "harbor.workspace.forked",
      "harbor.session.branch_mismatch",
      "harbor.picker.opened",
      "harbor.picker.selected",
      "harbor.picker.canceled",
    } do
      assert.is_true(listed[name], name)
    end
  end)
end)
