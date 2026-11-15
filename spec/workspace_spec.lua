local env = require "spec.support.env"
local mux = require "spec.support.mux"
local wt = require "wezterm"

describe("harbor.workspace reliability", function()
  local ws, fixture, dir, original, process, run, store
  before_each(function()
    dir = env.setup { sessions = { save_on_close = false } }
    ws = require "harbor.workspace"
    store = require "harbor.session.store"
    fixture = mux.new()
    original = {}
    for _, key in ipairs { "all_windows", "spawn_window", "rename_workspace", "set_active_workspace" } do
      original[key] = wt.mux[key]
    end
    wt.mux.all_windows = function()
      return fixture.windows
    end
    wt.mux.spawn_window = fixture.spawn
    wt._workspaces = { "safe", "target" }
    wt._active_workspace = "safe"
    process = require("harbor.deps").warp.process
    run = process.run
    process.run = function(args)
      wt._child_calls[#wt._child_calls + 1] = args
      return true, "", ""
    end
  end)
  after_each(function()
    for _, key in ipairs { "all_windows", "spawn_window", "rename_workspace", "set_active_workspace" } do
      wt.mux[key] = original[key]
    end
    process.run = run
    env.rmdir(dir)
  end)
  local function emitted(name)
    for _, event in ipairs(wt._emitted) do
      if event.name == name then
        return true
      end
    end
    return false
  end
  it("closes exact target IDs across windows without touching active panes", function()
    local _, safe = fixture.spawn { workspace = "safe" }
    local _, first = fixture.spawn { workspace = "target" }
    local second = first:split {}
    local _, third = fixture.spawn { workspace = "target" }
    assert.is_true(ws.close(nil, nil, "target"))
    assert.equal(3, #wt._child_calls)
    for i, p in ipairs { first, second, third } do
      local args = wt._child_calls[i]
      assert.same(
        { "cli", "--no-auto-start", "kill-pane", "--pane-id", tostring(p.id) },
        { args[2], args[3], args[4], args[5], args[6] }
      )
      assert.not_equal(tostring(safe.id), args[6])
    end
    assert.equal("safe", wt._active_workspace)
  end)
  it("switches away before closing active workspace", function()
    fixture.spawn { workspace = "target" }
    wt._active_workspace = "target"
    process.run = function()
      assert.equal("safe", wt._active_workspace)
      return true
    end
    assert.is_true(ws.close(nil, nil, "target"))
  end)
  it("refuses to close the only workspace", function()
    fixture.spawn { workspace = "target" }
    wt._workspaces, wt._active_workspace = { "target" }, "target"
    assert.is_false(ws.close(nil, nil, "target"))
    assert.equal(0, #wt._child_calls)
  end)
  it("keeps metadata and reports failure when a kill fails", function()
    fixture.spawn { workspace = "target" }
    local state = require "harbor.state"
    state.set_workspace_path("target", "/keep")
    process.run = function()
      return false, "", "denied"
    end
    assert.is_false(ws.close(nil, nil, "target"))
    assert.equal("/keep", state.workspace_path "target")
    assert.is_false(emitted "harbor.workspace.closed")
  end)
  it("does not kill anything when enumeration fails", function()
    fixture.spawn { workspace = "target" }
    fixture.fail.tabs = true
    assert.is_false(ws.close(nil, nil, "target"))
    assert.equal(0, #wt._child_calls)
  end)
  it("aborts before killing when a pane ID cannot be inspected", function()
    local _, first = fixture.spawn { workspace = "target" }
    local second = first:split {}
    second.pane_id = function()
      error "pane vanished"
    end
    assert.is_false(ws.close(nil, nil, "target"))
    assert.equal(0, #wt._child_calls)
  end)
  it("aborts active close when switching away fails", function()
    fixture.spawn { workspace = "target" }
    wt._active_workspace = "target"
    wt.mux.set_active_workspace = function()
      error "switch denied"
    end
    assert.is_false(ws.close(nil, nil, "target"))
    assert.equal(0, #wt._child_calls)
    assert.is_false(emitted "harbor.workspace.switched")
  end)
  it("preserves metadata and blocks autosave after a partially successful close", function()
    local _, safe = fixture.spawn { workspace = "safe" }
    local _, first = fixture.spawn { workspace = "target" }
    local second = first:split {}
    local state = require "harbor.state"
    state.set_workspace_path("target", "/keep")
    local targets = {}
    process.run = function(args)
      targets[#targets + 1] = args[6]
      return args[6] == tostring(first.id), "", "kill denied"
    end
    assert.is_false(ws.close(nil, nil, "target"))
    assert.same({ tostring(first.id), tostring(second.id) }, targets)
    assert.not_equal(tostring(safe.id), targets[1])
    assert.equal("/keep", state.workspace_path "target")
    assert.truthy(state.protection "target")
    assert.is_false(ws.save(nil, nil, "target", { quiet = true }))
    assert.is_false(emitted "harbor.workspace.closed")
  end)
  it("keeps destination path on merge", function()
    fixture.spawn { workspace = "target" }
    local state = require "harbor.state"
    state.set_workspace_path("safe", "/safe")
    state.set_workspace_path("target", "/target")
    assert.is_true(ws.rename(nil, nil, "target", "safe"))
    assert.equal("/safe", state.workspace_path "safe")
    assert.is_nil(state.workspace_path "target")
  end)
  it("does not report a failed merge as successful", function()
    fixture.spawn { workspace = "target" }
    fixture.fail.merge = true
    assert.is_false(ws.rename(nil, nil, "target", "safe"))
    assert.is_false(emitted "harbor.workspace.renamed")
  end)
  it("does not move any windows after merge enumeration fails", function()
    local _, _, win = fixture.spawn { workspace = "target" }
    wt.mux.all_windows = function()
      error "mux unavailable"
    end
    assert.is_false(ws.rename(nil, nil, "target", "safe"))
    assert.equal("target", win.workspace)
    assert.is_false(emitted "harbor.workspace.renamed")
  end)
  it("protects both workspaces after a partial merge", function()
    local _, _, first = fixture.spawn { workspace = "target" }
    local _, _, second = fixture.spawn { workspace = "target" }
    second.set_workspace = function()
      error "merge denied"
    end
    assert.is_false(ws.rename(nil, nil, "target", "safe"))
    assert.equal("safe", first.workspace)
    assert.equal("target", second.workspace)
    local state = require "harbor.state"
    assert.truthy(state.protection "safe")
    assert.truthy(state.protection "target")
    assert.is_false(emitted "harbor.workspace.renamed")
  end)
  it("switches to an existing workspace without spawning another", function()
    assert.is_true(ws.create(nil, nil, "safe"))
    assert.equal(0, #fixture.windows)
    assert.equal("safe", wt._active_workspace)
  end)
  it("refuses saved-session collisions before mux rename", function()
    for _, name in ipairs { "target", "new" } do
      assert.is_true(
        store.write { name = name, windows = { { tabs = { { root = { pane = {} } } } } } }
      )
    end
    wt.mux.rename_workspace = function()
      error "must not run"
    end
    assert.is_false(ws.rename(nil, nil, "target", "new"))
    assert.equal("new", assert(store.read "new").name)
  end)
  it("blocks quiet saving of partial restores but permits explicit save", function()
    local state = require "harbor.state"
    state.protect("target", "split failed")
    assert.is_false(ws.save(nil, nil, "target", { quiet = true }))
    assert.equal("split failed", state.protection "target")
  end)

  it("reports saved rename failure without emitting success", function()
    assert.is_true(store.write {
      name = "target",
      windows = { { tabs = { { root = { pane = {} } } } } },
    })
    wt.mux.rename_workspace = function() end
    local rename = store.rename
    store.rename = function()
      return false, "disk error"
    end
    local ok = ws.rename(nil, nil, "target", "new")
    store.rename = rename
    assert.is_false(ok)
    assert.is_false(emitted "harbor.workspace.renamed")
  end)

  it("does not emit restored success or switch on partial restore", function()
    assert.is_true(store.write {
      name = "broken",
      windows = {
        {
          tabs = {
            {
              root = {
                split = "Right",
                size = 0.5,
                first = { pane = {} },
                second = { pane = {} },
              },
            },
          },
        },
      },
    })
    fixture.fail.split = true
    local ok, err = ws.restore(nil, nil, "broken")
    assert.is_false(ok)
    assert.matches("rolled back", err)
    assert.equal("safe", wt._active_workspace)
    assert.is_false(emitted "harbor.session.restored")
    -- the one pane that was spawned is killed again
    assert.equal(1, #wt._child_calls)
    assert.equal(tostring(fixture.windows[1].items[1].first.id), wt._child_calls[1][6])
    assert.is_nil(require("harbor.state").protection "broken")
  end)

  it("keeps protection when a restore rollback cannot kill its panes", function()
    assert.is_true(store.write {
      name = "broken",
      windows = {
        {
          tabs = {
            {
              root = {
                split = "Right",
                size = 0.5,
                first = { pane = {} },
                second = { pane = {} },
              },
            },
          },
        },
      },
    })
    fixture.fail.split = true
    process.run = function()
      return false, "", "denied"
    end
    assert.is_false(ws.restore(nil, nil, "broken"))
    assert.truthy(require("harbor.state").protection "broken")
  end)

  describe("save before close", function()
    local capture, original_capture
    before_each(function()
      require("harbor.config").get().sessions.save_on_close = true
      capture = require "harbor.session.capture"
      original_capture = capture.workspace
      capture.workspace = function(name)
        return { name = name, windows = { { tabs = { { root = { pane = {} } } } } } }
      end
    end)
    after_each(function()
      capture.workspace = original_capture
    end)

    it("saves the workspace before killing its panes", function()
      fixture.spawn { workspace = "target" }
      process.run = function(args)
        assert.is_true(store.exists "target")
        wt._child_calls[#wt._child_calls + 1] = args
        return true, "", ""
      end
      assert.is_true(ws.close(nil, nil, "target"))
      assert.equal(1, #wt._child_calls)
    end)

    it("does not save when refusing to close the only workspace", function()
      fixture.spawn { workspace = "target" }
      wt._workspaces, wt._active_workspace = { "target" }, "target"
      assert.is_false(ws.close(nil, nil, "target"))
      assert.is_false(store.exists "target")
      assert.is_false(emitted "harbor.session.saved")
    end)

    it("aborts the close when the save fails", function()
      fixture.spawn { workspace = "target" }
      capture.workspace = function()
        return nil, "capture failed"
      end
      assert.is_false(ws.close(nil, nil, "target"))
      assert.equal(0, #wt._child_calls)
    end)

    it("closes a protected workspace without overwriting its snapshot", function()
      fixture.spawn { workspace = "target" }
      require("harbor.state").protect("target", "partial")
      assert.is_true(ws.close(nil, nil, "target"))
      assert.is_false(store.exists "target")
      assert.equal(1, #wt._child_calls)
    end)
  end)

  describe("quit", function()
    local function gui()
      local win = { performed = {} }
      function win:perform_action(action)
        self.performed[#self.performed + 1] = action
      end
      return win
    end

    it("saves every unprotected, non-excluded workspace, then quits", function()
      wt._workspaces = { "safe", "target", "skip", "partial" }
      require("harbor.config").get().sessions.autosave.exclude = { "skip" }
      require("harbor.state").protect("partial", "restore failed")
      local saved = {}
      local save = ws.save
      ws.save = function(_, _, name, opts)
        assert.is_true(opts.quiet)
        saved[#saved + 1] = name
        return true
      end
      local win = gui()
      local ok = ws.quit(win, nil)
      ws.save = save
      assert.is_true(ok)
      assert.same({ "safe", "target" }, saved)
      assert.equal("QuitApplication", win.performed[1]._action)
    end)

    it("does not quit when a save fails", function()
      local save = ws.save
      ws.save = function(_, _, name)
        return name ~= "target"
      end
      local win = gui()
      local ok = ws.quit(win, nil)
      ws.save = save
      assert.is_false(ok)
      assert.equal(0, #win.performed)
    end)
  end)

  it("explicit save clears protection only after a successful write", function()
    local capture = require "harbor.session.capture"
    local original_capture = capture.workspace
    capture.workspace = function()
      return { name = "target", windows = { { tabs = { { root = { pane = {} } } } } } }
    end
    local state = require "harbor.state"
    state.protect("target", "partial")
    local saved = ws.save(nil, nil, "target")
    capture.workspace = original_capture
    assert.is_true(saved)
    assert.is_nil(state.protection "target")
  end)
end)
