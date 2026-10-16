local env = require "spec.support.env"
local wezterm = require "wezterm"

describe("harbor.session.auto", function()
  local auto, ws, capture
  local saved, sigs
  local orig = {}

  before_each(function()
    env.setup { sessions = { autosave = { enabled = true, interval = 30 } } }
    auto = require "harbor.session.auto"
    auto._registered = nil
    ws = require "harbor.workspace"
    capture = require "harbor.session.capture"
    orig.save, orig.names, orig.active, orig.signature =
      ws.save, ws.names, ws.active, capture.signature
    saved, sigs = {}, {}
    ws.save = function(_, _, name, opts)
      saved[#saved + 1] = { name = name, opts = opts }
      return true
    end
    ws.names = function()
      return { "a", "b", "scratch" }
    end
    ws.active = function()
      return "a"
    end
    capture.signature = function(name)
      return sigs[name] or "sig"
    end
  end)

  after_each(function()
    ws.save, ws.names, ws.active, capture.signature =
      orig.save, orig.names, orig.active, orig.signature
    auto._registered = nil
  end)

  it("skips unchanged structure", function()
    assert.is_true(auto.save_if_changed "a")
    assert.is_false(auto.save_if_changed "a")
    sigs.a = "changed"
    assert.is_true(auto.save_if_changed "a")
    assert.equal(2, #saved)
    assert.is_true(saved[1].opts.quiet)
  end)

  it("does not remember the signature when the save fails", function()
    ws.save = function()
      return false
    end
    assert.is_false(auto.save_if_changed "a")
    ws.save = function()
      return true
    end
    assert.is_true(auto.save_if_changed "a")
  end)

  it("honours scope and exclude", function()
    env.setup {
      sessions = { autosave = { enabled = true, exclude = { "scratch" } } },
    }
    assert.same({ "a", "b" }, auto.targets())
    env.setup { sessions = { autosave = { enabled = true, scope = "active" } } }
    assert.same({ "a" }, auto.targets())
  end)

  it("stops loops from older generations", function()
    auto.start()
    assert.equal(1, #wezterm._timers)
    auto.start() -- config reload: new generation
    assert.equal(2, #wezterm._timers)
    wezterm._run_timers()
    -- only the current generation reschedules itself
    assert.equal(1, #wezterm._timers)
    assert.equal(30, wezterm._timers[1].secs)
  end)

  it("keeps looping when a pass fails", function()
    ws.names = function()
      error "boom"
    end
    auto.start()
    wezterm._run_timers()
    assert.equal(1, #wezterm._timers)
  end)

  it("schedules nothing when disabled", function()
    env.setup()
    auto.start()
    assert.equal(0, #wezterm._timers)
  end)

  it("registers handlers once", function()
    env.setup {
      sessions = {
        autosave = { enabled = true, on_focus_lost = true },
        restore_on_startup = true,
      },
    }
    auto.register()
    auto.register()
    assert.equal(1, #wezterm._handlers["window-focus-changed"])
    assert.equal(1, #wezterm._handlers["gui-startup"])
  end)

  it("saves on focus lost only", function()
    env.setup { sessions = { autosave = { enabled = true, on_focus_lost = true } } }
    auto.register()
    local focused = true
    local win = {
      is_focused = function()
        return focused
      end,
      active_workspace = function()
        return "b"
      end,
    }
    wezterm.emit("window-focus-changed", win, nil)
    assert.equal(0, #saved)
    focused = false
    wezterm.emit("window-focus-changed", win, nil)
    assert.equal(1, #saved)
    assert.equal("b", saved[1].name)
  end)
end)
