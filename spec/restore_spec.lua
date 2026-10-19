local env = require "spec.support.env"
local mux = require "spec.support.mux"
local wt = require "wezterm"

describe("harbor.session.restore reliability", function()
  local restore, fixture, dir, spawn
  local function leaf(opts)
    return { pane = opts or {} }
  end
  local function doc()
    return { name = "restored", windows = { { tabs = { { root = leaf() } } } } }
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
  it("rejects malformed trees before any spawn", function()
    local d = doc()
    d.windows[1].tabs[1].root = { split = "Right", size = 2, first = leaf() }
    local ok, err = restore.workspace(d)
    assert.is_false(ok)
    assert.truthy(err)
    assert.equal(0, #fixture.windows)
  end)
  it("restores nested trees, titles, tab/pane focus and zoom", function()
    local d = doc()
    d.windows[1].title = "window title"
    d.windows[1].tabs = {
      { title = "first", root = leaf() },
      {
        title = "active",
        active = true,
        root = {
          split = "Right",
          size = 0.4,
          first = leaf(),
          second = {
            split = "Bottom",
            size = 0.6,
            first = leaf(),
            second = leaf { active = true, zoomed = true },
          },
        },
      },
    }
    assert.is_true(restore.workspace(d))
    local win = fixture.windows[1]
    assert.equal("restored", win.workspace)
    assert.equal("window title", win.title)
    assert.equal("active", fixture.active_tab.title)
    assert.is_true(fixture.active_tab.zoomed)
    local panes = fixture.active_tab:panes()
    assert.equal(3, #panes)
    assert.equal(panes[3], fixture.active_pane)
    assert.equal("Right", panes[2].spawn.direction)
    assert.equal(0.6, panes[3].spawn.size)
  end)
  it("keeps healthy panes but reports partial split failure and protects autosave", function()
    local d = doc()
    d.windows[1].tabs[1].root = {
      split = "Right",
      size = 0.5,
      first = leaf(),
      second = leaf(),
    }
    fixture.fail.split = true
    local ok, err = restore.workspace(d)
    assert.is_false(ok)
    assert.truthy(err:find("split failed", 1, true))
    assert.equal(1, #fixture.windows)
    assert.truthy(require("harbor.state").protection "restored")
  end)
  it("reports tab spawn failures", function()
    local d = doc()
    d.windows[1].tabs[2] = { root = leaf() }
    fixture.fail.tab = true
    local ok, err = restore.workspace(d)
    assert.is_false(ok)
    assert.truthy(err:find("tab 2", 1, true))
  end)
  it("reports window spawn failures", function()
    fixture.fail.window = true
    assert.is_false(restore.workspace(doc()))
  end)

  it("continues restoring healthy windows after an earlier window fails", function()
    local d = doc()
    d.windows[1].tabs[1].root = leaf { domain = "SSH:missing" }
    d.windows[2] = { tabs = { { root = leaf() } } }
    local ok = restore.workspace(d)
    assert.is_false(ok)
    assert.equal(1, #fixture.windows)
  end)

  it("reports disconnected remote spawn without replaying commands", function()
    wt._domains = { {
      name = function()
        return "SSH:test"
      end,
    } }
    local d = doc()
    d.windows[1].tabs[1].root = leaf { domain = "SSH:test" }
    fixture.fail.window = true
    local ok, err = restore.workspace(d)
    assert.is_false(ok)
    assert.truthy(err:find("spawn_window failed", 1, true))
    assert.equal(0, #wt._timers)
  end)

  it("does not replay programs outside the allowlist", function()
    local d = doc()
    d.windows[1].tabs[1].root = leaf {
      process = { name = "untrusted", argv = { "untrusted" } },
    }
    assert.is_true(restore.workspace(d))
    assert.equal(0, #wt._timers)
  end)
  it("rejects process argv that does not match its claimed executable", function()
    local d = doc()
    d.windows[1].tabs[1].root = leaf {
      process = { name = "nvim", argv = { "sh", "-c", "unexpected" } },
    }
    assert.is_false(restore.workspace(d))
    assert.equal(0, #fixture.windows)
    assert.equal(0, #wt._timers)
  end)
  it("reports title and focus failures", function()
    local d = doc()
    d.windows[1].tabs[1].title = "title"
    d.windows[1].tabs[1].active = true
    fixture.fail["tab.title"], fixture.fail["tab.activate"] = true, true
    local ok, err = restore.workspace(d)
    assert.is_false(ok)
    assert.truthy(err:find("tab title", 1, true))
    assert.truthy(err:find("active tab", 1, true))
  end)
  it("never falls back locally for unavailable remote domains", function()
    local d = doc()
    d.windows[1].tabs[1].root = leaf {
      domain = "SSH:missing",
      cwd = "/remote",
      process = { name = "nvim", argv = { "nvim", "secret" } },
    }
    local ok, err = restore.workspace(d)
    assert.is_false(ok)
    assert.truthy(err:find("domain is not available", 1, true))
    assert.equal(0, #fixture.windows)
    assert.equal(0, #wt._timers)
  end)
  it("preserves remote cwd without local directory checks and skips command replay", function()
    wt._domains = { {
      name = function()
        return "SSH:test"
      end,
    } }
    local d = doc()
    d.windows[1].tabs[1].root = leaf {
      domain = "SSH:test",
      cwd = "/remote/only",
      process = { name = "nvim", argv = { "nvim" } },
    }
    assert.is_true(restore.workspace(d))
    assert.equal("/remote/only", fixture.windows[1].items[1].first.spawn.cwd)
    assert.equal(0, #wt._timers)
  end)
  it("reports missing local cwd rather than silently using another", function()
    local d = doc()
    d.windows[1].tabs[1].root = leaf { cwd = dir .. "/absent" }
    assert.is_false(restore.workspace(d))
    assert.equal(0, #fixture.windows)
  end)

  it("targets the local domain explicitly instead of a remote default domain", function()
    local opts = assert(restore.spawn_opts { domain = "local" })
    assert.same({ DomainName = "local" }, opts.domain)
    assert.same({ DomainName = "local" }, restore.spawn_opts({}).domain)
  end)
  it("sanitizes stored output and replays only allowlisted argv", function()
    local d = doc()
    d.windows[1].tabs[1].root = leaf {
      scrollback = "safe\27]0;bad\7\27[31mred\27[0m",
      process = { name = "nvim", argv = { "nvim", "a b.txt" } },
    }
    assert.is_true(restore.workspace(d))
    local p = fixture.windows[1].items[1].first
    assert.is_nil(p.output[1]:find("bad", 1, true))
    wt._run_timers()
    assert.truthy(p.sent[1]:find("a b.txt", 1, true))
    fixture.fail.send = true
    assert.is_true(restore.workspace(d))
    wt._run_timers()
    assert.truthy(require("harbor.state").protection "restored")
  end)
  it("reports timer scheduling failure as an incomplete restore", function()
    local d = doc()
    d.windows[1].tabs[1].root = leaf {
      process = { name = "nvim", argv = { "nvim" } },
    }
    local call_after = wt.time.call_after
    wt.time.call_after = function()
      error "timer unavailable"
    end
    local ok, err = restore.workspace(d)
    wt.time.call_after = call_after
    assert.is_false(ok)
    assert.truthy(err:find("schedule process replay", 1, true))
    assert.truthy(require("harbor.state").protection "restored")
  end)
  it("retains replay failure protection when timers are unavailable", function()
    local d = doc()
    d.windows[1].tabs[1].root = leaf {
      process = { name = "nvim", argv = { "nvim" } },
    }
    local call_after = wt.time.call_after
    wt.time.call_after = nil
    fixture.fail.send = true
    local ok, err = restore.workspace(d)
    wt.time.call_after = call_after
    assert.is_false(ok)
    assert.truthy(err:find("process replay failed", 1, true))
    assert.truthy(require("harbor.state").protection "restored")
  end)
end)
