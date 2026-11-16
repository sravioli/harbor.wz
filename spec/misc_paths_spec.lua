local env = require "spec.support.env"
local wt = require "wezterm"

describe("harbor misc edge cases", function()
  local dir, saved

  local function patch(module, key, value)
    saved[#saved + 1] = { module, key, module[key] }
    module[key] = value
  end

  before_each(function()
    dir = env.setup()
    saved = {}
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      saved[i][1][saved[i][2]] = saved[i][3]
    end
    env.rmdir(dir)
  end)

  describe("config", function()
    it("falls back to the defaults for options that are not a table", function()
      local config = require "harbor.config"
      assert.is_table(config.setup(123))
      assert.is_table(config.get().sessions)
    end)

    it("initialises its defaults on first use", function()
      local original = package.loaded["harbor.config"]
      package.loaded["harbor.config"] = nil
      local fresh = require "harbor.config"
      assert.is_table(fresh.get().picker)
      package.loaded["harbor.config"] = original
    end)
  end)

  describe("history without a data directory", function()
    it("ignores every update when the directory cannot be made", function()
      local util = require "harbor.util"
      patch(util, "mkdir", function()
        return false
      end)
      local history = require "harbor.history"
      history._reset()
      assert.has_no.errors(function()
        history.visit("a", "b")
        history.visit_dir "/x"
        history.rename("a", "c")
        history.forget "a"
        history.saved("a", 1)
        history.forget_saved "a"
      end)
      assert.is_nil(history.current())
    end)

    it("follows a rename of the current workspace", function()
      local history = require "harbor.history"
      history.visit("b", "a")
      history.rename("b", "c")
      assert.equal("c", history.current())
      history.forget "c"
    end)
  end)

  describe("naming styles", function()
    it("names a workspace by its tilde or full path", function()
      local naming = require "harbor.naming"
      local config = require "harbor.config"
      local util = require "harbor.util"
      config.setup { sessions = { dir = dir }, naming = { style = "tilde" } }
      assert.equal(util.tilde "/srv/app", naming.base_name "/srv/app")
      config.setup { sessions = { dir = dir }, naming = { style = "path" } }
      assert.equal("/srv/app", naming.base_name "/srv/app")
    end)
  end)

  describe("picker labels and format", function()
    local picker

    before_each(function()
      picker = require "harbor.picker"
    end)

    it("tags the current workspace, with or without ribbon", function()
      local cfg = { icons = false, path_width = 40 }
      local entry = { kind = "workspace", name = "dev", current = true }
      assert.matches("current", picker.label(entry, cfg))
      patch(require "harbor.deps", "ribbon", nil)
      assert.matches("current", picker.label(entry, cfg))
    end)

    it("lets picker.format rewrite a label, and ignores one that fails", function()
      local seen = {}
      local function window()
        local w = { performed = {} }
        function w:window_id()
          return 7
        end
        function w:active_key_table() end
        function w:perform_action(action)
          self.performed[#self.performed + 1] = action
        end
        return w
      end
      local config = require "harbor.config"
      config.setup {
        sessions = { dir = dir },
        picker = {
          format = function(e, label)
            seen[#seen + 1] = e.kind
            if e.kind == "workspace" then
              return "formatted " .. label
            end
            error "bad format"
          end,
        },
      }
      patch(wt.mux, "all_windows", function()
        return {}
      end)
      local w = window()
      picker.open(w, "pane", {})
      local selector = w.performed[#w.performed]
      assert.equal("InputSelector", selector.action)
      assert.is_true(#seen > 0)
      local formatted = false
      for _, choice in ipairs(selector.args.choices) do
        formatted = formatted or choice.label:find("formatted", 1, true) ~= nil
      end
      assert.is_true(formatted)
    end)

    it("deletes a saved session after a confirmation", function()
      local workspace = require "harbor.workspace"
      local util = require "harbor.util"
      local forgotten
      patch(workspace, "forget", function(_, _, name)
        forgotten = name
      end)
      patch(util, "confirm", function(_, _, _, on_yes)
        on_yes(nil, nil)
      end)
      patch(util, "later", function() end)
      picker.dispatch("delete", { performed = {} }, "pane", { kind = "saved", name = "old" }, {})
      assert.equal("old", forgotten)
    end)
  end)

  describe("startup restore", function()
    local function startup()
      for _, handler in ipairs(wt._handlers["gui-startup"] or {}) do
        handler()
      end
    end

    before_each(function()
      local auto = require "harbor.session.auto"
      auto._registered = false -- the mock drops handlers between tests, harbor keeps its flag
      auto.register()
    end)

    it("does nothing without a name, and nothing to restore without a saved session", function()
      require("harbor.config").setup { sessions = { dir = dir, restore_on_startup = true } }
      assert.has_no.errors(startup) -- no history: true has no name to use
      require("harbor.config").setup { sessions = { dir = dir, restore_on_startup = "absent" } }
      assert.has_no.errors(startup) -- nothing saved under that name
    end)

    it("restores the named session and activates it, or reports a failed restore", function()
      require("harbor.config").setup { sessions = { dir = dir, restore_on_startup = "back" } }
      local store = require "harbor.session.store"
      assert(store.write {
        name = "back",
        windows = { { tabs = { { root = { pane = {} } } } } },
      })
      local mux = require("spec.support.mux").new()
      patch(wt.mux, "spawn_window", mux.spawn)
      startup()
      assert.equal("back", wt._active_workspace)

      local restore = require "harbor.session.restore"
      patch(restore, "workspace", function()
        return false, "broken"
      end)
      wt._active_workspace = "default"
      startup()
      assert.equal("default", wt._active_workspace)
    end)
  end)

  describe("sources", function()
    it("keeps a failing source from taking the list down", function()
      local sources = require "harbor.sources"
      local zoxide = require "harbor.sources.zoxide"
      patch(zoxide, "collect", function()
        error "zoxide exploded"
      end)
      require("harbor.config").setup {
        sessions = { dir = dir },
        sources = { zoxide = { enabled = true } },
      }
      assert.has_no.errors(function()
        sources.list { current = "default" }
      end)
    end)

    it("ignores a custom source that does not return a list", function()
      local sources = require "harbor.sources"
      require("harbor.config").setup {
        sessions = { dir = dir },
        sources = {
          custom = {
            function()
              return "not a list"
            end,
          },
        },
      }
      assert.has_no.errors(function()
        sources.list { current = "default" }
      end)
    end)

    it("lists saved sessions with their save time", function()
      local store = require "harbor.session.store"
      assert(store.write { name = "kept", windows = { { tabs = { { root = { pane = {} } } } } } })
      wt._dirs[dir .. "/sessions"] = { store.path_for "kept" } -- the mock lists its own directories
      local out = require("harbor.sources.saved").collect()
      assert.equal("kept", out[1].name)
      assert.is_number(out[1].saved_at)
    end)

    it("has no workspaces when the mux cannot list them", function()
      patch(wt.mux, "get_workspace_names", function()
        error "gone"
      end)
      assert.same({}, require("harbor.sources.workspaces").collect())
    end)

    it("finds the root of a workspace from its first window's pane", function()
      local workspaces = require "harbor.sources.workspaces"
      local windows = {
        {
          get_workspace = function()
            return "w"
          end,
          active_tab = function()
            return {
              active_pane = function()
                return {
                  get_current_working_dir = function()
                    return "file://host/srv/app"
                  end,
                }
              end,
            }
          end,
        },
      }
      assert.equal("/srv/app", workspaces.root("w", windows))
      assert.is_nil(workspaces.root("other", windows))
    end)
  end)

  describe("store and zoxide", function()
    it("rejects a list that is not a sequence, and reports a failed migration on read", function()
      local store = require "harbor.session.store"
      local d = {
        name = "a",
        windows = {
          {
            tabs = {
              { root = { pane = { process = { name = "nvim", argv = { "x", extra = "y" } } } } },
            },
          },
        },
      }
      assert.is_false(store.validate(d))

      assert(store.write { name = "m", windows = { { tabs = { { root = { pane = {} } } } } } })
      patch(store, "migrate", function()
        return nil, "no way up"
      end)
      assert.same({ nil, "no way up" }, { store.read "m" })
    end)

    it("parses the output of a successful zoxide query", function()
      local zoxide = require "harbor.sources.zoxide"
      local process = require("harbor.deps").warp.process
      patch(process, "which", function()
        return "/bin/zoxide" -- zoxide need not be installed where the specs run
      end)
      patch(process, "run", function()
        return true, " 12.5 /srv/app\n", ""
      end)
      local out = zoxide.collect { path = "/bin/zoxide", min_score = 0, limit = 10 }
      assert.equal("/srv/app", out[1].path)
    end)
  end)

  describe("remaining branches", function()
    it("names the root directory after the path itself", function()
      require("harbor.config").setup { sessions = { dir = dir } }
      assert.equal("/", require("harbor.naming").base_name "/")
    end)

    it("knows the root of a workspace harbor opened", function()
      require("harbor.state").set_workspace_path("w", "/srv/app")
      assert.equal("/srv/app", require("harbor.sources.workspaces").root("w", {}))
    end)

    it("keeps the order for sort mode none, and the order of equally ranked directories", function()
      local sources = require "harbor.sources"
      local entries = { { kind = "dir", path = "/b" }, { kind = "dir", path = "/a" } }
      assert.equal(entries, sources.sort(entries, "none"))
      local sorted =
        sources.sort({ { kind = "dir", path = "/b" }, { kind = "dir", path = "/a" } }, "mru")
      assert.same({ "/b", "/a" }, { sorted[1].path, sorted[2].path })
    end)

    it("treats a directory with .git as a repository", function()
      os.execute(('mkdir -p "%s/.git"'):format(dir))
      assert.is_true(require("harbor.session.capture").in_repo(dir))
    end)

    it("calls a failed restore rolled back when nothing had been opened", function()
      local restore = require "harbor.session.restore"
      local doc =
        { name = "r", windows = { { tabs = { { root = { pane = { cwd = "/no/such/dir" } } } } } } }
      local ok, err = restore.workspace(doc, { rollback = true })
      assert.is_false(ok)
      assert.matches("rolled back", err)
    end)

    it("does not autosave on focus lost unless it is switched on", function()
      local auto = require "harbor.session.auto"
      auto._registered = false
      auto.register()
      local window = {
        is_focused = function()
          return false
        end,
      }
      for _, handler in ipairs(wt._handlers["window-focus-changed"] or {}) do
        assert.has_no.errors(function()
          handler(window, "pane")
        end)
      end
    end)

    it("cancelling a rename prompt reopens the picker", function()
      local picker = require "harbor.picker"
      local util = require "harbor.util"
      local reopened = false
      patch(util, "later", function(_, fn)
        fn()
      end)
      patch(picker, "open", function()
        reopened = true
      end)
      local window = { performed = {} }
      function window:perform_action(action)
        self.performed[#self.performed + 1] = action
      end
      picker.dispatch("rename", window, "pane", { kind = "workspace", name = "dev" }, {})
      window.performed[1].args.action.callback(window, "pane", "")
      assert.is_true(reopened)
    end)
  end)
end)
