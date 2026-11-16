local env = require "spec.support.env"
local mux = require "spec.support.mux"
local wt = require "wezterm"

describe("harbor.workspace paths", function()
  local ws, store, dir, fixture, saved

  ---Replace `module[key]` for the length of one test.
  local function patch(module, key, value)
    saved[#saved + 1] = { module, key, module[key] }
    module[key] = value
  end

  before_each(function()
    dir = env.setup { sessions = { save_on_close = false } }
    ws = require "harbor.workspace"
    store = require "harbor.session.store"
    fixture = mux.new()
    saved = {}
    patch(wt.mux, "all_windows", function()
      return fixture.windows
    end)
    patch(wt.mux, "spawn_window", fixture.spawn)
    wt._workspaces = { "a", "b" }
    wt._active_workspace = "a"
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      saved[i][1][saved[i][2]] = saved[i][3]
    end
    env.rmdir(dir)
  end)

  local function window(extra)
    local w = { performed = {}, toasts = {} }
    function w:perform_action(action)
      self.performed[#self.performed + 1] = action
    end
    function w:toast_notification(_, msg)
      self.toasts[#self.toasts + 1] = msg
    end
    for k, v in pairs(extra or {}) do
      w[k] = v
    end
    return w
  end

  describe("windows and switching", function()
    it("reports a window listing or workspace lookup that fails", function()
      wt.mux.all_windows = function()
        error "no windows"
      end
      local list, err = ws.windows "a"
      assert.is_nil(list)
      assert.matches("cannot enumerate workspace windows", err)

      wt.mux.all_windows = function()
        return {
          {
            get_workspace = function()
              error "no ws"
            end,
          },
        }
      end
      list, err = ws.windows "a"
      assert.is_nil(list)
      assert.matches("cannot inspect workspace", err)
    end)

    it("switches without a window through the mux, and reports a failure", function()
      assert.is_true(ws.switch(nil, nil, "b"))
      assert.equal("b", wt._active_workspace)

      local w = window {
        perform_action = function()
          error "denied"
        end,
      }
      assert.is_false(ws.switch(w, "pane", "a"))
      assert.same({ "Cannot switch to workspace a" }, w.toasts)
    end)

    it("goes back to the previous workspace once there is one", function()
      local w = window()
      assert.is_false(ws.previous(w, "pane"))
      ws.switch(w, "pane", "b")
      wt._active_workspace = "b"
      assert.is_true(ws.previous(w, "pane"))
      assert.equal("a", w.performed[#w.performed].args.name)
    end)

    it("cycles through the workspaces and wraps, or says there is no other", function()
      local w = window()
      assert.is_true(ws.cycle(w, "pane", 1))
      assert.equal("b", w.performed[#w.performed].args.name)
      assert.is_true(ws.cycle(w, "pane", -1))
      assert.equal("b", w.performed[#w.performed].args.name) -- wraps below the first

      wt._workspaces = { "only" }
      assert.is_false(ws.cycle(w, "pane", 1))
      assert.same({ "No other workspace" }, { w.toasts[#w.toasts] })
    end)
  end)

  describe("create and open", function()
    it("creates a workspace with an explicit layout, domain and root", function()
      local spawned
      wt.mux.spawn_window = function(args)
        spawned = args
        return fixture.spawn(args)
      end
      local w = window()
      local layout = { tabs = { { title = "main", cwd = dir } } }
      assert.is_true(ws.create(w, "pane", "new", dir, { layout = layout, domain = "remote" }))
      assert.equal("new", spawned.workspace)
      assert.same({ DomainName = "remote" }, spawned.domain)
      assert.equal("new", w.performed[#w.performed].args.name)
      assert.equal(dir, require("harbor.state").workspace_path "new")
    end)

    it("drops a working directory that does not exist", function()
      local spawned
      wt.mux.spawn_window = function(args)
        spawned = args
        return fixture.spawn(args)
      end
      assert.is_true(
        ws.create(window(), "pane", "ghost", "/no/such/dir/at/all", { layout = false })
      )
      assert.is_nil(spawned.cwd)
    end)

    it("reports a workspace that could not be spawned", function()
      wt.mux.spawn_window = function()
        error "no window"
      end
      local w = window()
      assert.is_false(ws.create(w, "pane", "broken", nil, { layout = false }))
      assert.same({ "Could not create workspace broken" }, w.toasts)
    end)

    it("opens a directory, adding it to zoxide and the history", function()
      local added
      local zoxide = require "harbor.sources.zoxide"
      patch(zoxide, "add", function(_, path)
        added = path
      end)
      require("harbor.config").setup {
        sessions = { dir = dir },
        sources = { zoxide = { enabled = true, add_on_open = true } },
      }
      assert.is_false(ws.open_dir(window(), "pane", nil))
      assert.is_true(ws.open_dir(window(), "pane", dir, { layout = false }))
      assert.equal(dir, added)
    end)

    it("opens a domain as a tab, switches to a live one, or creates it", function()
      local w = window()
      require("harbor.config").setup {
        sessions = { dir = dir },
        sources = { domains = { action = "tab" } },
      }
      assert.is_true(ws.open_domain(w, "pane", "remote"))
      assert.same({ DomainName = "remote" }, w.performed[1].args.domain)

      require("harbor.config").setup {
        sessions = { dir = dir },
        sources = { domains = { action = "workspace" } },
      }
      wt._workspaces = { "a", "remote" }
      assert.is_true(ws.open_domain(w, "pane", "remote"))
      assert.equal("remote", w.performed[#w.performed].args.name)

      wt._workspaces = { "a" }
      assert.is_true(ws.open_domain(w, "pane", "fresh"))
    end)
  end)

  describe("rename", function()
    it("ignores an empty or unchanged name", function()
      assert.is_false(ws.rename(window(), "pane", "a", "  "))
      assert.is_false(ws.rename(window(), "pane", "a", "a"))
    end)

    it("refuses to rename onto a saved session that already exists", function()
      patch(store, "exists", function()
        return true
      end)
      local w = window()
      assert.is_false(ws.rename(w, "pane", "a", "fresh"))
      assert.same({ "Saved session already exists: fresh" }, w.toasts)
    end)

    it("reports a rename the mux refuses", function()
      patch(wt.mux, "rename_workspace", function()
        error "refused"
      end)
      assert.is_false(ws.rename(window(), "pane", "a", "fresh"))
    end)

    it("keeps the new name when only the saved session cannot be renamed", function()
      patch(wt.mux, "rename_workspace", function() end)
      patch(store, "exists", function(name)
        return name == "a"
      end)
      patch(store, "rename", function()
        return false, "disk full"
      end)
      local w = window()
      assert.is_false(ws.rename(w, "pane", "a", "fresh"))
      assert.matches("saved session rename failed: disk full", w.toasts[1])
    end)

    it("merges into an existing workspace and moves its protection along", function()
      local state = require "harbor.state"
      local _, _, source = fixture.spawn { workspace = "a" }
      state.protect("a", "partial")
      wt._active_workspace = "b"
      local w = window()
      assert.is_true(ws.rename(w, "pane", "a", "b"))
      assert.equal("b", source.workspace)
      assert.equal("partial", state.protection "b")
      assert.is_nil(state.protection "a")
      assert.equal("b", w.performed[#w.performed].args.name)
    end)

    it("fails a merge without source windows or whose windows cannot move", function()
      local w = window()
      assert.is_false(ws.rename(w, "pane", "a", "b")) -- no window in "a"

      local _, _, source = fixture.spawn { workspace = "a" }
      source.set_workspace = function()
        error "locked"
      end
      assert.is_false(ws.rename(w, "pane", "a", "b"))
      assert.matches("merge incomplete", w.toasts[#w.toasts])
      assert.is_truthy(require("harbor.state").protection "a")
    end)
  end)

  describe("close", function()
    local function close_fixture()
      local _, _, win = fixture.spawn { workspace = "b" }
      return win
    end

    it("fails when windows, tabs or panes cannot be inspected", function()
      local w = window()
      wt.mux.all_windows = function()
        error "gone"
      end
      assert.is_false(ws.close(w, "pane", "b"))

      wt.mux.all_windows = function()
        return {
          {
            get_workspace = function()
              error "gone"
            end,
          },
        }
      end
      assert.is_false(ws.close(w, "pane", "b"))

      wt.mux.all_windows = function()
        return {
          {
            get_workspace = function()
              return "b"
            end,
            tabs = function()
              error "gone"
            end,
          },
        }
      end
      assert.is_false(ws.close(w, "pane", "b"))

      wt.mux.all_windows = function()
        return {
          {
            get_workspace = function()
              return "b"
            end,
            tabs = function()
              return {
                {
                  panes = function()
                    error "gone"
                  end,
                },
              }
            end,
          },
        }
      end
      assert.is_false(ws.close(w, "pane", "b"))

      wt.mux.all_windows = function()
        return {
          {
            get_workspace = function()
              return "b"
            end,
            tabs = function()
              return {
                {
                  panes = function()
                    return {
                      {
                        pane_id = function()
                          return -1
                        end,
                      },
                    }
                  end,
                },
              }
            end,
          },
        }
      end
      assert.is_false(ws.close(w, "pane", "b"))
    end)

    it("says when the workspace has no panes", function()
      local w = window()
      wt.mux.all_windows = function()
        return {}
      end
      assert.is_false(ws.close(w, "pane", "b"))
      assert.same({ "No panes found for b" }, w.toasts)
    end)

    it("will not close the only workspace", function()
      wt._workspaces = { "a" }
      wt._active_workspace = "a"
      fixture.spawn { workspace = "a" }
      local w = window()
      assert.is_false(ws.close(w, "pane", "a"))
      assert.same({ "Cannot close the only workspace" }, w.toasts)
    end)

    it("falls back to another workspace when there is no usable previous one", function()
      close_fixture()
      wt._active_workspace = "b"
      local w = window()
      patch(ws, "kill_panes", function()
        return 1, {}
      end)
      assert.is_true(ws.close(w, "pane", "b"))
      assert.equal("a", w.performed[#w.performed].args.name)
    end)

    it("saves before closing, aborting when that fails, and skips a protected one", function()
      require("harbor.config").setup { sessions = { dir = dir, save_on_close = true } }
      close_fixture()
      local w = window()
      patch(ws, "save", function()
        return false
      end)
      assert.is_false(ws.close(w, "pane", "b"))
      assert.matches("Close aborted", w.toasts[#w.toasts])

      patch(ws, "kill_panes", function()
        return 1, {}
      end)
      require("harbor.state").protect("b", "partial")
      assert.is_true(ws.close(w, "pane", "b"))
    end)

    it("protects a workspace whose panes only partly closed", function()
      close_fixture()
      patch(ws, "kill_panes", function()
        return 1, { "7: failed" }
      end)
      assert.is_false(ws.close(window(), "pane", "b"))
      assert.equal("workspace close incomplete", require("harbor.state").protection "b")
    end)
  end)

  describe("save, restore and forget", function()
    local capture, restore

    before_each(function()
      capture = require "harbor.session.capture"
      restore = require "harbor.session.restore"
    end)

    it("reports a save that captures or writes nothing", function()
      local w = window()
      patch(capture, "workspace", function()
        return nil, "cannot capture"
      end)
      assert.is_false(ws.save(w, "pane", "a"))
      assert.matches("Save failed: cannot capture", w.toasts[1])

      patch(capture, "workspace", function()
        return { name = "a" }
      end)
      patch(store, "write", function()
        return false, "read-only"
      end)
      assert.is_false(ws.save(w, "pane", "a"))
      assert.matches("read%-only", w.toasts[2])
    end)

    it("blocks a quiet save of a protected workspace", function()
      require("harbor.state").protect("a", "partial")
      assert.is_false(ws.save(window(), "pane", "a", { quiet = true }))
    end)

    it("reports a restore that cannot read or rebuild the session", function()
      local w = window()
      patch(store, "read", function()
        return nil, "unreadable"
      end)
      local ok, err = ws.restore(w, "pane", "gone")
      assert.is_false(ok)
      assert.equal("unreadable", err)

      patch(store, "read", function()
        return { name = "gone" }
      end)
      patch(restore, "workspace", function()
        return false, "half done"
      end)
      ok, err = ws.restore(w, "pane", "gone")
      assert.is_false(ok)
      assert.equal("half done", err)
      assert.matches("Restore incomplete", w.toasts[#w.toasts])
    end)

    it("does not quit when a save fails, and quits when they all work", function()
      local w = window()
      patch(ws, "save_all", function()
        return false, { "a", "b" }
      end)
      assert.is_false(ws.quit(w, "pane"))
      assert.matches("save failed for a, b", w.toasts[1])

      ws.save_all = function()
        return true
      end
      assert.is_true(ws.quit(w, "pane"))
      assert.equal("QuitApplication", w.performed[#w.performed]._action)
    end)

    it("reports a session that cannot be deleted", function()
      patch(store, "delete", function()
        return false, "busy"
      end)
      assert.is_false(ws.forget(window(), "pane", "a"))
      assert.is_false(ws.forget_snapshot("tab", window(), "pane", "a"))
    end)
  end)

  describe("snapshots", function()
    local capture, restore

    before_each(function()
      capture = require "harbor.session.capture"
      restore = require "harbor.session.restore"
    end)

    local function snapshot_window()
      local _, p, mw = fixture.spawn { workspace = "a" }
      local w = window {
        mux_window = function()
          return mw
        end,
      }
      p.tab = function()
        return mw.items[1]
      end
      mw.get_title = function()
        return "titled"
      end
      mw.items[1].get_title = function()
        return "tab titled"
      end
      return w, p, mw
    end

    it("has nothing to save without a window or tab", function()
      local w = window()
      assert.is_false(ws.save_snapshot("window", w, "pane", "n"))
      assert.is_false(ws.save_snapshot("tab", w, "pane", "n"))
      assert.same({ "Nothing to save", "Nothing to save" }, w.toasts)
    end)

    it("names an unnamed snapshot after its title, and needs a name", function()
      local w, p, mw = snapshot_window()
      patch(capture, "window_doc", function(name)
        return { name = name }
      end)
      patch(capture, "tab_doc", function(name)
        return { name = name }
      end)
      local written = {}
      patch(store, "write", function(doc, kind)
        written[#written + 1] = { doc.name, kind }
        return true
      end)
      assert.is_true(ws.save_snapshot("window", w, p))
      assert.is_true(ws.save_snapshot("tab", w, p, ""))
      assert.same({ { "titled", "window" }, { "tab titled", "tab" } }, written)

      mw.get_title = function()
        return ""
      end
      assert.is_false(ws.save_snapshot("window", w, p))
      assert.matches("a name is required", w.toasts[#w.toasts])
    end)

    it("reports a snapshot that cannot be captured or written", function()
      local w, p = snapshot_window()
      patch(capture, "window_doc", function()
        return nil, "no capture"
      end)
      assert.is_false(ws.save_snapshot("window", w, p, "n"))
      patch(capture, "tab_doc", function()
        return { name = "n" }
      end)
      patch(store, "write", function()
        return false, "no disk"
      end)
      assert.is_false(ws.save_snapshot("tab", w, p, "n"))
      assert.matches("no disk", w.toasts[#w.toasts])
    end)

    it("reports a snapshot that cannot be loaded", function()
      local w = window()
      patch(store, "read", function()
        return nil, "missing"
      end)
      local ok, err = ws.load_snapshot("window", w, "pane", "n")
      assert.is_false(ok)
      assert.equal("missing", err)

      patch(store, "read", function()
        return { name = "n" }
      end)
      ok, err = ws.load_snapshot("tab", w, "pane", "n") -- no mux window to add it to
      assert.is_false(ok)
      assert.equal("no window", err)

      patch(restore, "snapshot", function()
        return false, "bad layout"
      end)
      ok, err = ws.load_snapshot("window", w, "pane", "n")
      assert.is_false(ok)
      assert.equal("bad layout", err)
    end)
  end)
end)

describe("harbor.workspace remaining paths", function()
  local ws, dir

  before_each(function()
    dir = env.setup { sessions = { save_on_close = false } }
    ws = require "harbor.workspace"
    wt._workspaces = { "a", "b" }
    wt._active_workspace = "a"
  end)

  after_each(function()
    env.rmdir(dir)
  end)

  it("resolves the layout itself when none is given", function()
    local fixture = mux.new()
    local spawn = wt.mux.spawn_window
    wt.mux.spawn_window = fixture.spawn
    assert.is_true(ws.create(nil, nil, "plain", nil))
    wt.mux.spawn_window = spawn
  end)

  it("renames a workspace the mux knows", function()
    local rename = wt.mux.rename_workspace
    local renamed
    wt.mux.rename_workspace = function(old, new)
      renamed = old .. ">" .. new
    end
    assert.is_true(ws.rename(nil, nil, "a", "fresh"))
    wt.mux.rename_workspace = rename
    assert.equal("a>fresh", renamed)
  end)

  it("does not close a workspace that does not exist", function()
    assert.is_false(ws.close(nil, nil, "nope"))
  end)

  it("switches to a workspace that is already live instead of restoring it", function()
    assert.is_true(ws.restore(nil, nil, "b"))
    assert.equal("b", wt._active_workspace)
  end)
end)
