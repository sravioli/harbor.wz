local env = require "spec.support.env"
local mux = require "spec.support.mux"
local wt = require "wezterm"

describe("harbor git branch awareness", function()
  local dir, capture, restore, process, run, calls, branches, spawn, fixture

  local function pane_item(cwd, domain)
    return {
      pane = {
        get_current_working_dir = function()
          return "file://localhost/" .. cwd
        end,
        get_domain_name = function()
          return domain or "local"
        end,
        get_title = function()
          return "p"
        end,
        is_alt_screen_active = function()
          return false
        end,
        get_lines_as_escapes = function()
          return ""
        end,
        get_foreground_process_info = function()
          return { executable = "bash" }
        end,
      },
    }
  end

  local function doc(branch, cwd)
    return {
      name = "proj",
      windows = {
        { tabs = { { root = { pane = { cwd = cwd or "/repo", branch = branch } } } } },
      },
    }
  end

  before_each(function()
    dir = env.setup()
    capture = require "harbor.session.capture"
    restore = require "harbor.session.restore"
    process = require("harbor.deps").warp.process
    run = process.run
    calls, branches = {}, {}
    process.run = function(argv)
      calls[#calls + 1] = argv
      local b = branches[argv[3]]
      if b then
        return true, b .. "\n", ""
      end
      return false, "", "not a repo"
    end
    fixture = mux.new()
    spawn = wt.mux.spawn_window
    wt.mux.spawn_window = fixture.spawn
  end)

  after_each(function()
    process.run = run
    wt.mux.spawn_window = spawn
    env.rmdir(dir)
  end)

  describe("capture", function()
    it("records the branch of a local pane", function()
      branches["/repo"] = "feature/x"
      local data = capture.pane(pane_item "/repo", capture.options())
      assert.are.equal("feature/x", data.branch)
      assert.are.same({ "git", "-C", "/repo", "rev-parse", "--abbrev-ref", "HEAD" }, calls[1])
    end)

    it("asks git once per directory in a pass", function()
      branches["/repo"] = "main"
      local opts = capture.options()
      capture.pane(pane_item "/repo", opts)
      capture.pane(pane_item "/repo", opts)
      assert.are.equal(1, #calls)
    end)

    it("ignores detached HEAD and non-repositories", function()
      branches["/detached"] = "HEAD"
      assert.is_nil(capture.pane(pane_item "/detached", capture.options()).branch)
      assert.is_nil(capture.pane(pane_item "/plain", capture.options()).branch)
    end)

    it("skips remote panes", function()
      branches["/repo"] = "main"
      local data = capture.pane(pane_item("/repo", "SSH:box"), capture.options())
      assert.is_nil(data.branch)
      assert.are.equal(0, #calls)
    end)

    it("is disabled by sessions.git_branch = false", function()
      env.setup { sessions = { git_branch = false } }
      branches["/repo"] = "main"
      assert.is_nil(capture.pane(pane_item "/repo", capture.options()).branch)
      assert.are.equal(0, #calls)
    end)

    it("is accepted by the store schema", function()
      assert.is_true(require("harbor.session.store").validate(doc "main"))
    end)
  end)

  describe("branch_mismatches", function()
    it("reports panes whose branch changed", function()
      branches["/repo"] = "dev"
      local out = restore.branch_mismatches(doc "main")
      assert.are.same({ { path = "/repo", saved = "main", current = "dev" } }, out)
    end)

    it("stays quiet when the branch matches or is unknown", function()
      branches["/repo"] = "main"
      assert.are.same({}, restore.branch_mismatches(doc "main"))
      assert.are.same({}, restore.branch_mismatches(doc(nil)))
      assert.are.same({}, restore.branch_mismatches(doc("main", "/gone")))
    end)

    it("is disabled by the option", function()
      env.setup { sessions = { git_branch = false } }
      branches["/repo"] = "dev"
      assert.are.same({}, restore.branch_mismatches(doc "main"))
    end)
  end)

  it("restore warns and emits branch_mismatch without failing", function()
    local ws = require "harbor.workspace"
    local store = require "harbor.session.store"
    branches[dir] = "dev"
    assert.is_true(store.write(doc("main", dir)))
    assert.is_true(ws.restore(nil, nil, "proj"))
    local found
    for _, event in ipairs(wt._emitted) do
      if event.name == "harbor.session.branch_mismatch" then
        found = event
      end
    end
    assert.truthy(found)
  end)
end)
