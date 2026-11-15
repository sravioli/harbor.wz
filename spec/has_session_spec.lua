local env = require "spec.support.env"

local function doc(name)
  return { name = name, windows = { { tabs = { { root = { pane = { cwd = "/w" } } } } } } }
end

describe("harbor.has_session", function()
  local harbor, store, dir

  before_each(function()
    dir = env.setup()
    harbor = require "harbor.api"
    store = require "harbor.session.store"
  end)

  after_each(function()
    env.rmdir(dir)
  end)

  it("reports saved sessions", function()
    assert.is_true(store.write(doc "a"))
    assert.is_true(harbor.has_session "a")
    assert.is_false(harbor.has_session "b")
    assert.is_false(harbor.has_session "")
    assert.is_false(harbor.has_session(nil))
  end)

  it("caches lookups instead of touching the disk every frame", function()
    assert.is_false(harbor.has_session "a")
    assert.is_true(store.write(doc "a"))
    assert.is_false(harbor.has_session "a")
  end)

  it("drops the cached answer when the session is deleted", function()
    assert.is_true(store.write(doc "a"))
    assert.is_true(harbor.has_session "a")
    assert.is_true(require("harbor.workspace").forget(nil, nil, "a"))
    assert.is_false(harbor.has_session "a")
  end)
end)
