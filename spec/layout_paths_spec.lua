local env = require "spec.support.env"

describe("harbor.layout edge cases", function()
  local layout, dir

  before_each(function()
    dir = env.setup()
    layout = require "harbor.layout"
  end)

  after_each(function()
    env.rmdir(dir)
  end)

  local function write(name, source)
    local fh = assert(io.open(dir .. "/" .. name .. ".lua", "w"))
    fh:write(source)
    fh:close()
  end

  describe("load", function()
    it("only accepts a name, a table or a function", function()
      assert.is_nil(layout.load(42))
      local fn = function() end
      assert.equal(fn, layout.load(fn))
    end)

    it("needs layouts.dir to load a layout by name", function()
      assert.is_nil(layout.load "dev")
    end)

    it("loads a layout file, and tolerates a missing or broken one", function()
      require("harbor.config").setup { sessions = { dir = dir }, layouts = { dir = dir } }
      write("good", "return { tabs = { { title = 'x' } } }")
      write("bad", "error('broken layout')")
      assert.same({ tabs = { { title = "x" } } }, layout.load "good")
      assert.is_nil(layout.load "bad")
      assert.is_nil(layout.load "absent")
    end)
  end)

  describe("apply", function()
    local function recorder()
      local log = {}
      local function pane(id, fail_split)
        return {
          id = id,
          send_text = function() end,
          activate = function() end,
          split = function(_, args)
            log[#log + 1] = args
            if fail_split then
              error "no room"
            end
            return pane(id .. "s")
          end,
        }
      end
      local tab = { set_title = function() end, activate = function() end }
      return log, pane, tab
    end

    it("runs a layout function and reports whether it worked", function()
      assert.is_true(layout.apply(function() end, {}))
      assert.is_false(layout.apply(function()
        error "bad layout"
      end, {}))
    end)

    it("logs an invalid layout and an invalid split", function()
      assert.is_false(layout.apply({ tabs = {} }, {}))

      local log, pane, tab = recorder()
      local ctx = { tab = tab, pane = pane "p", window = {}, root = "/r" }
      -- Nested splits are only checked when they are applied.
      local nested =
        { { direction = "Right", size = 0.5, splits = { { direction = "Sideways" } } } }
      assert.is_true(layout.apply({ tabs = { { splits = nested } } }, ctx))
      assert.equal(1, #log) -- the outer split ran, the invalid inner one did not
    end)

    it("opens splits and tabs in the layout's domain", function()
      local log, pane, tab = recorder()
      local spawned
      local window = {
        spawn_tab = function(_, args)
          spawned = args
          return tab, pane "second"
        end,
      }
      local ctx = { tab = tab, pane = pane "p", window = window, root = "/r", domain = "remote" }
      layout.apply({
        tabs = {
          { splits = { { direction = "Right", size = 0.5 } } },
          { cwd = "sub" },
        },
      }, ctx)
      assert.same({ DomainName = "remote" }, log[1].domain)
      assert.same({ DomainName = "remote" }, spawned.domain)
      assert.equal("/r/sub", spawned.cwd)
    end)

    it("carries on when a tab or a split cannot be made", function()
      local log, pane, tab = recorder()
      local window = {
        spawn_tab = function()
          error "no tab"
        end,
      }
      local ctx = { tab = tab, pane = pane("p", true), window = window, root = "/r" }
      assert.is_true(layout.apply({
        tabs = {
          { splits = { { direction = "Right", size = 0.5 } } },
          { title = "lost" },
        },
      }, ctx))
      assert.equal(1, #log) -- the split was attempted, and failed
    end)
  end)
end)
