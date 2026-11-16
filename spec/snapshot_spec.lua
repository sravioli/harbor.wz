local env = require "spec.support.env"
local mux = require "spec.support.mux"
local wt = require "wezterm"

describe("harbor tab and window snapshots", function()
  local dir, store, ws, capture, restore, fixture, spawn
  local function leaf(opts)
    return { pane = opts or {} }
  end
  local function tab_doc(name)
    return { name = name, windows = { { tabs = { { title = "t", root = leaf { cwd = dir } } } } } }
  end
  local function window_doc(name)
    return {
      name = name,
      windows = {
        { title = "w", tabs = { { root = leaf() }, { root = leaf(), active = true } } },
      },
    }
  end
  local function source_pane(cwd)
    return {
      get_current_working_dir = function()
        return "file://localhost/" .. cwd
      end,
      get_domain_name = function()
        return "local"
      end,
      get_title = function()
        return "pane"
      end,
      is_alt_screen_active = function()
        return false
      end,
      get_lines_as_escapes = function()
        return "out\n"
      end,
      get_foreground_process_info = function()
        return { executable = "bash" }
      end,
    }
  end
  local function source_tab(title)
    return {
      panes_with_info = function()
        return {
          { left = 0, top = 0, width = 80, height = 24, pane = source_pane(dir), is_active = true },
        }
      end,
      get_title = function()
        return title
      end,
    }
  end

  before_each(function()
    dir = env.setup()
    store = require "harbor.session.store"
    ws = require "harbor.workspace"
    capture = require "harbor.session.capture"
    restore = require "harbor.session.restore"
    fixture = mux.new()
    spawn = wt.mux.spawn_window
    wt.mux.spawn_window = fixture.spawn
  end)

  after_each(function()
    wt.mux.spawn_window = spawn
    env.rmdir(dir)
  end)

  describe("store kinds", function()
    it("keeps each kind in its own directory", function()
      assert.is_true(store.write(tab_doc "dev", "tab"))
      assert.is_true(store.write(window_doc "dev", "window"))
      assert.is_true(store.exists("dev", "tab"))
      assert.is_true(store.exists("dev", "window"))
      assert.is_false(store.exists "dev")
      assert.are_not.equal(store.path_for("dev", "tab"), store.path_for("dev", "window"))
      assert.are_not.equal(store.path_for "dev", store.path_for("dev", "tab"))
    end)

    it("lists snapshots per kind and leaves workspace listing alone", function()
      wt._dirs[store.dir "tab"] = { store.path_for("a", "tab") }
      wt._dirs[store.dir()] = { store.path_for "w", store.dir "tab", store.dir "window" }
      assert.are.same({ "a" }, { store.list("tab")[1].name })
      assert.are.same({ "w" }, { store.list()[1].name })
      assert.are.equal(1, #store.list())
      assert.are.equal(0, #store.list "window")
    end)

    it("enforces the shape of each kind", function()
      assert.is_false(store.validate(window_doc "w", "tab"))
      assert.is_true(store.validate(window_doc "w", "window"))
      assert.is_true(store.validate(tab_doc "t", "tab"))
      local two = tab_doc "t"
      two.windows[2] = two.windows[1]
      assert.is_false(store.validate(two, "window"))
      assert.is_false(store.write(window_doc "w", "tab"))
    end)

    it("does not touch workspace saved-time history", function()
      local history = require "harbor.history"
      store.write(tab_doc "dev", "tab")
      assert.is_nil(history.saved_times()["dev"])
      store.write { name = "dev", saved_at = 5, windows = tab_doc("dev").windows }
      assert.truthy(history.saved_times()["dev"])
      assert.is_true(store.delete("dev", "tab"))
      assert.truthy(history.saved_times()["dev"])
    end)

    it("renames within a kind", function()
      store.write(tab_doc "old", "tab")
      assert.is_true(store.rename("old", "new", "tab"))
      assert.is_false(store.exists("old", "tab"))
      assert.are.equal("new", store.read("new", { kind = "tab" }).name)
    end)

    it("rejects a document of the wrong shape on read", function()
      store.write(window_doc "w", "window")
      local path = store.path_for("w", "window")
      local copy = store.path_for("w", "tab")
      os.execute(('cp "%s" "%s"'):format(path, copy))
      local doc, err = store.read("w", { kind = "tab" })
      assert.is_nil(doc)
      assert.truthy(err)
    end)
  end)

  describe("capture", function()
    it("captures a tab as a one-window one-tab document", function()
      local doc = assert(capture.tab_doc("mine", source_tab "build"))
      assert.are.equal("mine", doc.name)
      assert.are.equal(1, #doc.windows)
      assert.are.equal("build", doc.windows[1].tabs[1].title)
      assert.are.equal(dir, doc.windows[1].tabs[1].root.pane.cwd)
      assert.is_true(store.validate(doc, "tab"))
    end)

    it("captures a window with all its tabs", function()
      local win = {
        get_title = function()
          return "main"
        end,
        tabs_with_info = function()
          return { { tab = source_tab "a" }, { tab = source_tab "b", is_active = true } }
        end,
      }
      local doc = assert(capture.window_doc("w", win))
      assert.are.equal("main", doc.windows[1].title)
      assert.are.equal(2, #doc.windows[1].tabs)
      assert.is_true(doc.windows[1].tabs[2].active)
      assert.is_true(store.validate(doc, "window"))
    end)
  end)

  describe("restore.snapshot", function()
    it("adds a tab to an existing window", function()
      local _, _, win = fixture.spawn { workspace = "live" }
      assert.is_true(restore.snapshot("tab", tab_doc "t", win, "live"))
      assert.equal(2, #win.items)
      assert.equal("t", win.items[2].title)
    end)

    it("opens a window snapshot in the target workspace", function()
      assert.is_true(restore.snapshot("window", window_doc "w", nil, "live"))
      local win = fixture.windows[1]
      assert.equal("live", win.workspace)
      assert.equal("w", win.title)
      assert.equal(2, #win.items)
    end)

    it("never protects or re-roots the target workspace on success", function()
      restore.snapshot("window", window_doc "w", nil, "live")
      assert.is_nil(require("harbor.state").protection "live")
      assert.is_nil(require("harbor.state").workspace_path "live")
    end)

    it("does not protect the live workspace when a replay fails", function()
      local _, _, win = fixture.spawn { workspace = "live" }
      local doc = tab_doc "t"
      doc.windows[1].tabs[1].root = leaf { process = { name = "nvim", argv = { "nvim" } } }
      assert.is_true(restore.snapshot("tab", doc, win, "live"))
      fixture.fail.send = true
      wt._run_timers()
      assert.is_nil(require("harbor.state").protection "live")
    end)

    it("rolls back panes it created when a tab fails", function()
      local _, _, win = fixture.spawn { workspace = "live" }
      local killed
      local kill = ws.kill_panes
      ws.kill_panes = function(ids)
        killed = ids
        return #ids, {}
      end
      fixture.fail.split = true
      local doc = tab_doc "t"
      doc.windows[1].tabs[1].root = {
        split = "Right",
        size = 0.5,
        first = leaf(),
        second = leaf(),
      }
      local ok, err = restore.snapshot("tab", doc, win, "live")
      ws.kill_panes = kill
      assert.is_false(ok)
      assert.truthy(err:find("rolled back", 1, true))
      assert.is_true(#killed >= 1)
    end)

    it("rejects documents of the wrong shape before spawning", function()
      local ok = restore.snapshot("tab", window_doc "w", nil, "live")
      assert.is_false(ok)
      assert.equal(0, #fixture.windows)
    end)
  end)

  describe("workspace operations", function()
    it("loads a saved tab into the calling window and emits the kind", function()
      store.write(tab_doc "t", "tab")
      local _, _, win = fixture.spawn { workspace = "live" }
      local gui = {
        mux_window = function()
          return win
        end,
      }
      assert.is_true(ws.load_snapshot("tab", gui, nil, "t"))
      assert.equal(2, #win.items)
      local last = wt._emitted[#wt._emitted]
      assert.equal("harbor.session.restored", last.name)
    end)

    it("reports a missing snapshot", function()
      local ok, err = ws.load_snapshot("window", nil, nil, "nope")
      assert.is_false(ok)
      assert.truthy(err)
    end)

    it("deletes a snapshot and emits session.deleted", function()
      store.write(window_doc "w", "window")
      assert.is_true(ws.forget_snapshot("window", nil, nil, "w"))
      assert.is_false(store.exists("w", "window"))
    end)

    it("refuses to save without a window or name", function()
      assert.is_false(ws.save_snapshot("tab", nil, nil, "x"))
    end)
  end)

  describe("sources and picker", function()
    it("lists snapshots as typed entries and opens them", function()
      store.write(tab_doc "t", "tab")
      store.write(window_doc "w", "window")
      wt._dirs[store.dir "tab"] = { store.path_for("t", "tab") }
      wt._dirs[store.dir "window"] = { store.path_for("w", "window") }
      local entries = require("harbor.sources").list { kinds = { tab = true, window = true } }
      assert.equal(2, #entries)
      assert.equal("tab:t", entries[1].id)
      assert.equal("win:w", entries[2].id)

      local picker = require "harbor.picker"
      local called
      local load = ws.load_snapshot
      ws.load_snapshot = function(kind, _, _, name)
        called = kind .. ":" .. name
        return true
      end
      picker.open_entry({}, {}, entries[1])
      ws.load_snapshot = load
      assert.equal("tab:t", called)
    end)

    local function gui()
      local win = { performed = {} }
      function win:window_id()
        return 1
      end
      function win:perform_action(action)
        self.performed[#self.performed + 1] = action
      end
      return win
    end

    it("deletes a snapshot from the picker with its kind", function()
      env.setup { picker = { confirm = false } }
      local forgot
      local forget = ws.forget_snapshot
      ws.forget_snapshot = function(kind, _, _, name)
        forgot = kind .. ":" .. name
        return true
      end
      require("harbor.picker").dispatch("delete", gui(), nil, { kind = "tab", name = "t" }, {})
      ws.forget_snapshot = forget
      assert.equal("tab:t", forgot)
    end)

    it("renames a snapshot from the picker within its kind", function()
      local renamed
      local rename = store.rename
      store.rename = function(old, new, kind)
        renamed = table.concat({ old, new, tostring(kind) }, ":")
        return true
      end
      local win = gui()
      require("harbor.picker").dispatch("rename", win, nil, { kind = "window", name = "w" }, {})
      local prompt = win.performed[#win.performed]
      prompt.args.action.callback(win, nil, "w2")
      store.rename = rename
      assert.equal("w:w2:window", renamed)
    end)

    it("labels snapshot entries", function()
      local picker = require "harbor.picker"
      local label = picker.label({ kind = "tab", name = "dev" }, { icons = false })
      assert.truthy(label:find("dev", 1, true))
      assert.truthy(label:find("tab snapshot", 1, true))
    end)

    it("honours sources.snapshots.enabled", function()
      env.setup { sources = { snapshots = { enabled = false } } }
      store = require "harbor.session.store"
      store.write(tab_doc "t", "tab")
      wt._dirs[store.dir "tab"] = { store.path_for("t", "tab") }
      assert.equal(0, #require("harbor.sources").list { kinds = { tab = true } })
    end)
  end)
end)
