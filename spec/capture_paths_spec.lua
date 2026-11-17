local env = require "spec.support.env"
local wt = require "wezterm"

describe("harbor.session.capture edge cases", function()
  local capture, dir

  before_each(function()
    dir = env.setup()
    capture = require "harbor.session.capture"
  end)

  after_each(function()
    env.rmdir(dir)
  end)

  local function pane(o)
    o = o or {}
    return {
      get_current_working_dir = function()
        return "file://host/w"
      end,
      get_domain_name = function()
        return "local"
      end,
      get_title = function()
        return "t"
      end,
      is_alt_screen_active = function()
        return false
      end,
      get_foreground_process_info = function()
        return { executable = "/usr/bin/nvim", argv = o.argv }
      end,
      get_lines_as_escapes = function()
        return ""
      end,
    }
  end

  local function opts()
    local cfg = require("harbor.config").get().sessions
    return {
      scrollback = cfg.scrollback,
      processes = cfg.processes,
      allow = { nvim = true },
    }
  end

  it("treats a .git file (worktree or submodule) as a repository", function()
    local fh = assert(io.open(dir .. "/.git", "w"))
    fh:write "gitdir: elsewhere"
    fh:close()
    assert.is_true(capture.in_repo(dir))
  end)

  it("never climbs from a drive root into WezTerm's own directory", function()
    -- Specs run from a checkout, so `./.git` exists: the walk must stop first.
    assert.is_false(capture.in_repo "C:/")
  end)

  it("falls back to the executable when a process has no argv", function()
    local data = capture.pane({ pane = pane { argv = {} } }, opts())
    assert.same({ "/usr/bin/nvim" }, data.process.argv)
  end)

  it("reports tabs, windows and workspaces that cannot be enumerated", function()
    local no_panes = {
      get_title = function()
        return "t"
      end,
      panes_with_info = function()
        error "gone"
      end,
    }
    assert.same({ nil, "cannot enumerate tab panes" }, { capture.tab(no_panes, opts()) })

    local win = {
      tabs_with_info = function()
        error "gone"
      end,
    }
    assert.same({ nil, "cannot enumerate workspace tabs" }, { capture.window(win, opts()) })

    win.tabs_with_info = function()
      return { { tab = no_panes, is_active = true } }
    end
    assert.same({ nil, "cannot enumerate tab panes" }, { capture.window(win, opts()) })
    assert.same({ nil, "cannot enumerate tab panes" }, { capture.window_doc("w", win) })
    assert.same({ nil, "cannot enumerate tab panes" }, { capture.tab_doc("t", no_panes) })
  end)

  describe("workspace", function()
    local all

    before_each(function()
      all = wt.mux.all_windows
    end)

    after_each(function()
      wt.mux.all_windows = all
    end)

    it("fails when the windows cannot be listed or inspected", function()
      wt.mux.all_windows = function()
        error "gone"
      end
      assert.same({ nil, "cannot enumerate windows" }, { capture.workspace "w" })

      wt.mux.all_windows = function()
        return {
          {
            get_workspace = function()
              error "gone"
            end,
          },
        }
      end
      assert.same({ nil, "cannot inspect workspace window" }, { capture.workspace "w" })
    end)

    it("fails when a window of the workspace cannot be captured, or there is none", function()
      wt.mux.all_windows = function()
        return {
          {
            get_workspace = function()
              return "w"
            end,
            tabs_with_info = function()
              error "gone"
            end,
          },
        }
      end
      assert.same({ nil, "cannot enumerate workspace tabs" }, { capture.workspace "w" })

      wt.mux.all_windows = function()
        return {}
      end
      assert.same({ nil, "workspace has no windows: w" }, { capture.workspace "w" })
    end)

    it("signs a workspace by its name alone when the windows cannot be listed", function()
      wt.mux.all_windows = function()
        error "gone"
      end
      assert.equal("w", capture.signature "w")
    end)
  end)
end)
