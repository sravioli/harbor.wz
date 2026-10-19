local env = require "spec.support.env"
local mux = require "spec.support.mux"
local wt = require "wezterm"

describe("Harbor capture/disk/restore round trip", function()
  local dir, all_windows, spawn, fixture, state
  local function source_pane(cwd, text, process)
    return {
      get_current_working_dir = function()
        return "file://localhost/" .. cwd
      end,
      get_domain_name = function()
        return "local"
      end,
      get_title = function()
        return "pane title"
      end,
      is_alt_screen_active = function()
        return false
      end,
      get_lines_as_escapes = function()
        return text
      end,
      get_foreground_process_info = function()
        return process
      end,
    }
  end
  local function source_tab(infos, title)
    return {
      panes_with_info = function()
        return infos
      end,
      get_title = function()
        return title
      end,
    }
  end
  before_each(function()
    dir = env.setup()
    all_windows, spawn = wt.mux.all_windows, wt.mux.spawn_window
    fixture = mux.new()
    wt.mux.spawn_window = fixture.spawn
    state = require "harbor.state"
    state.set_workspace_path("source", dir)
  end)
  after_each(function()
    wt.mux.all_windows, wt.mux.spawn_window = all_windows, spawn
    env.rmdir(dir)
  end)
  it("retains multiwindow nested layout, cwd, titles, focus, zoom and safe content", function()
    local first = source_pane(dir, "hello\27]0;unsafe\7\n", {
      executable = "nvim",
      argv = { "nvim", "file with spaces'$.txt" },
    })
    local second = source_pane(dir, "right top\n", { executable = "bash" })
    local third = source_pane(dir, "right bottom\n", { executable = "bash" })
    local tab = source_tab({
      { left = 0, top = 0, width = 40, height = 20, pane = first },
      { left = 41, top = 0, width = 39, height = 10, pane = second },
      {
        left = 41,
        top = 11,
        width = 39,
        height = 9,
        pane = third,
        is_active = true,
        is_zoomed = true,
      },
    }, "nested")
    local plain = source_tab({
      { left = 0, top = 0, width = 80, height = 20, pane = second, is_active = true },
    }, "plain")
    local source = {
      {
        get_workspace = function()
          return "source"
        end,
        get_title = function()
          return "one"
        end,
        tabs_with_info = function()
          return { { tab = plain }, { tab = tab, is_active = true } }
        end,
      },
      {
        get_workspace = function()
          return "source"
        end,
        get_title = function()
          return "two"
        end,
        tabs_with_info = function()
          return { { tab = plain, is_active = true } }
        end,
      },
    }
    wt.mux.all_windows = function()
      return source
    end
    local doc = assert(require("harbor.session.capture").workspace "source")
    local store = require "harbor.session.store"
    assert.is_true(store.write(doc))
    local loaded = assert(store.read "source")
    assert.same(doc.windows, loaded.windows)
    assert.is_true(require("harbor.session.restore").workspace(loaded))
    assert.equal(2, #fixture.windows)
    local win = fixture.windows[1]
    assert.equal("one", win.title)
    assert.equal("two", fixture.windows[2].title)
    assert.equal(2, #win.items)
    assert.equal("nested", win.items[2].title)
    assert.is_true(win.items[2].zoomed)
    local panes = win.items[2]:panes()
    assert.equal(3, #panes)
    assert.equal(dir, panes[1].spawn.cwd)
    assert.same({ DomainName = "local" }, panes[1].spawn.domain)
    assert.equal(loaded.windows[1].tabs[2].root.size, panes[2].spawn.size)
    assert.equal(loaded.windows[1].tabs[2].root.second.size, panes[3].spawn.size)
    assert.equal("hello\r\n\27[0m", panes[1].output[1])
    wt._run_timers()
    assert.same({ "nvim 'file with spaces''$.txt'\r" }, panes[1].sent)
    assert.same({}, panes[2].sent)
    assert.equal(fixture.windows[2].items[1], fixture.active_tab)
    assert.equal(dir, state.workspace_path "source")
  end)
  it("does not save an incomplete capture over a good session", function()
    local store = require "harbor.session.store"
    assert.is_true(store.write {
      name = "source",
      windows = { { tabs = { { root = { pane = {} } } } } },
    })
    wt.mux.all_windows = function()
      return {
        {
          get_workspace = function()
            return "source"
          end,
          tabs_with_info = function()
            error "disconnected"
          end,
        },
      }
    end
    assert.is_false(require("harbor.workspace").save(nil, nil, "source"))
    assert.equal("source", assert(store.read "source").name)
    assert.is_nil(io.open(store.path_for "source" .. ".bak", "rb"))
  end)
end)
