local env = require "spec.support.env"
local mux = require "spec.support.mux"
local wt = require "wezterm"

describe("harbor.session.restore edge cases", function()
  local restore, fixture, dir, spawn

  local function leaf(opts)
    return { pane = opts or {} }
  end

  local function doc(root)
    return { name = "restored", windows = { { tabs = { { root = root or leaf() } } } } }
  end

  before_each(function()
    dir = env.setup()
    restore = require "harbor.session.restore"
    fixture = mux.new()
    spawn = wt.mux.spawn_window
    wt.mux.spawn_window = fixture.spawn
  end)

  after_each(function()
    wt.mux.spawn_window = spawn
    env.rmdir(dir)
  end)

  it("keeps building the first pane when the second cannot be spawned", function()
    local d =
      doc { split = "Right", size = 0.5, first = leaf(), second = leaf { cwd = "/no/such/dir" } }
    local ok, err = restore.workspace(d, { rollback = false })
    assert.is_false(ok)
    assert.matches("pane root.second: directory does not exist", err)
    assert.equal(1, #fixture.windows)
  end)

  it("records a tab whose pane cannot be spawned, and a window whose first tab cannot", function()
    local d = doc()
    d.windows[1].tabs[2] = { root = leaf { cwd = "/no/such/dir" } }
    local ok, err = restore.workspace(d, { rollback = false })
    assert.is_false(ok)
    assert.matches("spawn_tab failed: directory does not exist", err)

    fixture = mux.new()
    wt.mux.spawn_window = fixture.spawn
    ok, err = restore.workspace(doc(leaf { cwd = "/no/such/dir" }))
    assert.is_false(ok)
    assert.matches("directory does not exist", err)
    assert.equal(0, #fixture.windows)
  end)

  it("fails on a remote pane whose domain is not available", function()
    local ok, err = restore.workspace(doc(leaf { domain = "gone" }))
    assert.is_false(ok)
    assert.matches("domain is not available: gone", err)
  end)

  it("says nothing was restored when no window had tabs", function()
    local store = require "harbor.session.store"
    local validate = store.validate
    store.validate = function()
      return true
    end
    local ok, err = restore.workspace { name = "empty", windows = { { tabs = {} } } }
    store.validate = validate
    assert.is_false(ok)
    assert.equal("nothing restored for empty", err)
  end)

  it("reports a rollback that could not close every pane it opened", function()
    local workspace = require "harbor.workspace"
    local kill = workspace.kill_panes
    workspace.kill_panes = function()
      return 0, { "1: stuck" }
    end
    local d =
      doc { split = "Right", size = 0.5, first = leaf(), second = leaf { cwd = "/no/such/dir" } }
    local ok, err = restore.workspace(d, { rollback = true })
    workspace.kill_panes = kill
    assert.is_false(ok)
    assert.is_nil(err:match "rolled back")
  end)

  it("quotes a replayed command for the platform shell when the shell is unknown", function()
    require("harbor.config").setup {
      sessions = { dir = dir, processes = { enabled = true, mode = "extend", allow = { "nvim" } } },
    }
    local d = doc(leaf { process = { name = "nvim", argv = { "nvim", "a b.lua" } } })
    assert.is_true(restore.workspace(d))
    local pane = fixture.windows[1].items[1].first
    pane.get_foreground_process_info = function()
      error "unknown"
    end
    wt._run_timers()
    assert.matches("nvim", pane.sent[1])
  end)

  it("walks split trees when looking for branch changes", function()
    require("harbor.config").setup { sessions = { dir = dir, git_branch = true } }
    local tree = {
      split = "Right",
      size = 0.5,
      first = leaf { cwd = dir, branch = "main" },
      second = {
        split = "Bottom",
        size = 0.5,
        first = leaf { domain = "SSH:x", cwd = dir, branch = "main" },
        second = leaf(),
      },
    }
    assert.same({}, restore.branch_mismatches(doc(tree)))
  end)
end)
