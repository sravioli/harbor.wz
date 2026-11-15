local env = require "spec.support.env"

describe("harbor.history", function()
  local history, dir

  before_each(function()
    dir = env.setup()
    history = require "harbor.history"
  end)

  after_each(function()
    env.rmdir(dir)
  end)

  it("tracks current and previous", function()
    history.visit "a"
    history.visit "b"
    assert.are.equal("b", history.current())
    assert.are.equal("a", history.previous())
  end)

  it("reads an empty list that GLOBAL stored as an object", function()
    local Store =
      getmetatable(require("harbor.deps").memo.state.new { path = dir .. "/probe.json" })
    local get = Store.get
    -- Real wezterm.GLOBAL turns `{}` into an object proxy that rejects integer keys.
    Store.get = function()
      return setmetatable({}, {
        __index = function(_, k)
          if type(k) ~= "string" then
            error "can only index objects using string values"
          end
        end,
      })
    end
    local ok, ranks = pcall(history.ranks, "workspaces")
    Store.get = get
    assert.is_true(ok, tostring(ranks))
    assert.are.same({}, ranks)
  end)

  it("ranks most recent first without duplicates", function()
    history.visit "a"
    history.visit "b"
    history.visit "a"
    local ranks = history.ranks "workspaces"
    assert.are.equal(1, ranks.a)
    assert.are.equal(2, ranks.b)
    assert.are.equal(2, #history.list "workspaces")
  end)

  it("renames without leaving duplicates", function()
    history.visit "a"
    history.visit "b"
    history.rename("a", "b")
    local list = history.list "workspaces"
    assert.are.equal(1, #list)
    assert.are.equal("b", list[1].id)
  end)

  it("forgets workspaces", function()
    history.visit "a"
    history.visit "b"
    history.forget "a"
    assert.is_nil(history.ranks("workspaces").a)
    assert.is_nil(history.previous())
  end)

  it("persists across reloads", function()
    history.visit "a"
    history.visit_dir "/X/Proj"
    history._reset()
    require("wezterm").GLOBAL = {}
    assert.are.equal(1, history.ranks("workspaces").a)
    assert.is_not_nil(next(history.ranks "dirs"))
  end)
end)
