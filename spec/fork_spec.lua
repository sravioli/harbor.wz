local env = require "spec.support.env"
local mux = require "spec.support.mux"
local wt = require "wezterm"

describe("harbor fork", function()
  local dir, ws, capture, store, fixture, spawn, workspace_capture

  local function source_doc()
    return {
      name = "src",
      path = "/srv/src",
      windows = { { title = "w", tabs = { { title = "t", root = { pane = {} } } } } },
    }
  end

  before_each(function()
    dir = env.setup()
    ws = require "harbor.workspace"
    capture = require "harbor.session.capture"
    store = require "harbor.session.store"
    fixture = mux.new()
    spawn = wt.mux.spawn_window
    wt.mux.spawn_window = fixture.spawn
    workspace_capture = capture.workspace
    capture.workspace = function(name)
      local doc = source_doc()
      doc.name = name
      return doc
    end
    wt._workspaces = { "src" }
    wt._active_workspace = "src"
  end)

  after_each(function()
    capture.workspace = workspace_capture
    wt.mux.spawn_window = spawn
    env.rmdir(dir)
  end)

  it("duplicates the active layout into a new workspace and switches", function()
    assert.is_true(ws.fork(nil, nil, "copy"))
    assert.are.equal("copy", fixture.windows[1].workspace)
    assert.are.equal("w", fixture.windows[1].title)
    assert.are.equal("copy", wt._active_workspace)
  end)

  it("defaults the name to <active>-fork", function()
    assert.is_true(ws.fork(nil, nil))
    assert.are.equal("src-fork", fixture.windows[1].workspace)
  end)

  it("writes no session file and keeps the source untouched", function()
    ws.fork(nil, nil, "copy")
    assert.is_false(store.exists "copy")
    assert.is_false(store.exists "src")
  end)

  it("emits workspace.forked", function()
    ws.fork(nil, nil, "copy")
    local payload
    for _, event in ipairs(wt._emitted) do
      if event.name == "harbor.workspace.forked" then
        payload = event.args and event.args[3]
      end
    end
    assert.truthy(payload)
    assert.are.same({ from = "src", to = "copy" }, payload)
  end)

  it("refuses a name that is live or already saved", function()
    wt._workspaces = { "src", "taken" }
    local ok, err = ws.fork(nil, nil, "taken")
    assert.is_false(ok)
    assert.truthy(err)
    store.write(source_doc())
    local ok2 = ws.fork(nil, nil, "src")
    assert.is_false(ok2)
    assert.are.equal(0, #fixture.windows)
  end)

  it("reports a capture failure without spawning", function()
    capture.workspace = function()
      return nil, "boom"
    end
    local ok, err = ws.fork(nil, nil, "copy")
    assert.is_false(ok)
    assert.are.equal("boom", err)
    assert.are.equal(0, #fixture.windows)
  end)

  it("rolls back when the restore fails", function()
    local kill = ws.kill_panes
    ws.kill_panes = function(ids)
      return #ids, {}
    end
    fixture.fail.tab = true
    capture.workspace = function(name)
      local doc = source_doc()
      doc.name = name
      doc.windows[1].tabs[2] = { root = { pane = {} } }
      return doc
    end
    local ok, err = ws.fork(nil, nil, "copy")
    ws.kill_panes = kill
    assert.is_false(ok)
    assert.truthy(err:find("rolled back", 1, true))
    assert.are.equal("src", wt._active_workspace)
  end)

  it("exposes fork and its action", function()
    local api = require "harbor.api"
    assert.is_function(api.fork)
    assert.is_not_nil(api.action.fork())
  end)
end)
