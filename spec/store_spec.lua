local env = require "spec.support.env"

describe("harbor.session.store", function()
  local store, dir

  local function doc(name)
    return {
      name = name,
      windows = { { tabs = { { root = { pane = { cwd = "/w" } } } } } },
    }
  end

  before_each(function()
    dir = env.setup()
    store = require "harbor.session.store"
  end)

  after_each(function()
    env.rmdir(dir)
  end)

  describe("validate", function()
    it("accepts a minimal document", function()
      assert.is_true(store.validate(doc "a"))
    end)

    it("rejects malformed documents", function()
      assert.is_false(store.validate(nil))
      assert.is_false(store.validate { windows = {} })
      assert.is_false(store.validate { name = "a" })
      assert.is_false(store.validate { name = "a", windows = { {} } })
      assert.is_false(store.validate { name = "a", windows = { { tabs = { {} } } } })
    end)
  end)

  describe("migrate", function()
    it("stamps the current schema", function()
      assert.are.equal(store.SCHEMA_VERSION, store.migrate(doc "a").schema_version)
    end)

    it("refuses documents from a newer harbor", function()
      local d = doc "a"
      d.schema_version = store.SCHEMA_VERSION + 1
      local res, err = store.migrate(d)
      assert.is_nil(res)
      assert.truthy(err:find "newer")
    end)

    it("runs registered migrations", function()
      local saved = store.SCHEMA_VERSION
      store.SCHEMA_VERSION = 2
      store.migrations[1] = function(d)
        d.upgraded = true
        d.schema_version = 2
        return d
      end
      local res = store.migrate(doc "a")
      store.SCHEMA_VERSION = saved
      store.migrations[1] = nil
      assert.is_true(res.upgraded)
    end)
  end)

  it("round-trips through disk with odd names", function()
    local name = "my/odd: name"
    assert.is_true(store.write(doc(name)))
    assert.is_true(store.exists(name))
    local back = assert(store.read(name))
    assert.are.equal(name, back.name)
    assert.are.equal("/w", back.windows[1].tabs[1].root.pane.cwd)
  end)

  it("enforces the size limit", function()
    require("harbor.config").setup { sessions = { dir = dir, max_file_bytes = 1024 } }
    local d = doc "big"
    d.windows[1].tabs[1].root.pane.scrollback = string.rep("x", 4096)
    local ok, err = store.write(d)
    assert.is_false(ok)
    assert.truthy(err:find "limit")
  end)

  it("reports missing and corrupt files", function()
    assert.is_nil((store.read "nope"))
    local fh = assert(io.open(store.path_for "bad", "w"))
    fh:write "{not json"
    fh:close()
    assert.is_nil((store.read "bad"))
  end)

  it("renames and deletes", function()
    assert.is_true(store.write(doc "a"))
    assert.is_true(store.rename("a", "b"))
    assert.is_false(store.exists "a")
    assert.are.equal("b", store.read("b").name)
    assert.is_true(store.delete "b")
    assert.is_false(store.exists "b")
  end)

  it("lists sessions from file names without parsing", function()
    local wezterm = require "wezterm"
    wezterm._dirs[store.dir()] = {
      store.dir() .. "/" .. require("harbor.naming").encode "x y" .. ".json",
      store.dir() .. "/a.json.bak",
      store.dir() .. "/a.json",
    }
    local names = {}
    for _, e in ipairs(store.list()) do
      names[#names + 1] = e.name
    end
    assert.are.same({ "a", "x y" }, names)
  end)
end)
