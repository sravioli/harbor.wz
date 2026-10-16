local env = require "spec.support.env"

---Fake pane/tab/window recording what a layout does.
local function fake()
  local log = {}
  local function pane(id)
    local p = { id = id }
    function p:send_text(t)
      log[#log + 1] = { "send", self.id, t }
    end
    function p:split(args)
      log[#log + 1] = { "split", self.id, args }
      return pane(self.id .. "s")
    end
    function p:activate()
      log[#log + 1] = { "activate_pane", self.id }
    end
    return p
  end
  local function tab(id)
    local t = { id = id }
    function t:set_title(s)
      log[#log + 1] = { "title", self.id, s }
    end
    function t:activate()
      log[#log + 1] = { "activate_tab", self.id }
    end
    return t
  end
  local n = 1
  local window = {}
  function window:spawn_tab(args)
    n = n + 1
    log[#log + 1] = { "spawn_tab", args }
    return tab(n), pane("p" .. n), self
  end
  return { log = log, window = window, tab = tab(1), pane = pane "p1" }
end

local function count(log, kind)
  local c = 0
  for _, e in ipairs(log) do
    if e[1] == kind then
      c = c + 1
    end
  end
  return c
end

describe("harbor.layout", function()
  local layout

  before_each(function()
    env.setup()
    layout = require "harbor.layout"
  end)

  it("rejects layouts without tabs", function()
    local f = fake()
    assert.is_false(layout.apply({ tabs = {} }, { window = f.window, tab = f.tab, pane = f.pane }))
  end)

  it("applies tabs, splits and commands", function()
    local f = fake()
    local ok = layout.apply({
      tabs = {
        { title = "edit", cmd = "nvim ." },
        {
          title = "run",
          cwd = "app",
          splits = { { direction = "Bottom", cmd = "make" } },
          active = true,
        },
      },
    }, { root = "/r", window = f.window, tab = f.tab, pane = f.pane })
    assert.is_true(ok)
    assert.equal(1, count(f.log, "spawn_tab"))
    assert.equal(1, count(f.log, "split"))
    assert.equal(2, count(f.log, "title"))
    for _, e in ipairs(f.log) do
      if e[1] == "spawn_tab" then
        assert.equal("/r/app", e[2].cwd)
      elseif e[1] == "split" then
        assert.equal("Bottom", e[3].direction)
        assert.equal(0.5, e[3].size)
      end
    end
    assert.same({ "send", "p1", "nvim .\r" }, f.log[2])
  end)

  it("does not type cmd when args replace the shell", function()
    local f = fake()
    layout.apply({
      tabs = { { cmd = "x", args = { "htop" }, splits = { { cmd = "y", args = { "top" } } } } },
    }, { window = f.window, tab = f.tab, pane = f.pane })
    assert.equal(0, count(f.log, "send"))
  end)

  it("first_tab_args uses the first tab", function()
    assert.same({ cwd = "/r" }, layout.first_tab_args(nil, "/r"))
    local a = layout.first_tab_args({ tabs = { { cwd = "sub", args = { "nvim" } } } }, "/r")
    assert.equal("/r/sub", a.cwd)
    assert.same({ "nvim" }, a.args)
  end)

  it("resolves rules by pattern and function", function()
    local l1, l2 = { tabs = { {} } }, { tabs = { {}, {} } }
    env.setup {
      layouts = {
        rules = {
          { match = "web", layout = l1 },
          {
            match = function(_, name)
              return name == "special"
            end,
            layout = l2,
          },
        },
      },
    }
    -- config deep-copies options, so compare structure
    assert.equal(1, #layout.resolve("/dev/web", "web").tabs)
    assert.equal(2, #layout.resolve("/dev/x", "special").tabs)
    assert.is_nil(layout.resolve("/dev/x", "x"))
  end)

  it("ignores project files unless trusted", function()
    local dir = env.setup()
    local fh = assert(io.open(dir .. "/.harbor.lua", "w"))
    fh:write "return { tabs = { { title = 'proj' } } }"
    fh:close()
    assert.is_nil(layout.resolve(dir, "x"))
    env.setup { layouts = { trust_project_files = true } }
    local l = layout.resolve(dir, "x")
    assert.equal("proj", l.tabs[1].title)
  end)
end)
