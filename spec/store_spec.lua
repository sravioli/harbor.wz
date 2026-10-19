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

  it("reads backup only when explicitly requested without changing primary", function()
    local d = doc "backup"
    assert.is_true(store.write(d))
    d.windows[1].tabs[1].title = "new"
    assert.is_true(store.write(d))
    local path = store.path_for "backup"
    local fh = assert(io.open(path, "wb"))
    fh:write "{broken"
    fh:close()
    assert.is_nil(store.read "backup")
    local recovered = assert(store.read("backup", { backup = true }))
    assert.is_nil(recovered.windows[1].tabs[1].title)
    assert.is_nil(store.read "backup")
    os.remove(path)
    assert.truthy(store.read("backup", { backup = true }))
  end)

  it("refuses renaming over another saved session", function()
    assert.is_true(store.write(doc "a"))
    assert.is_true(store.write(doc "b"))
    local ok, err = store.rename("a", "b")
    assert.is_false(ok)
    assert.truthy(err:find("already exists", 1, true))
    assert.equal("a", store.read("a").name)
    assert.equal("b", store.read("b").name)
  end)

  it("rejects invalid trees, process argv and non-integer schema versions", function()
    for _, root in ipairs {
      {},
      { split = "Up", size = 0.5, first = { pane = {} }, second = { pane = {} } },
      { split = "Right", size = 1, first = { pane = {} }, second = { pane = {} } },
      { pane = { process = { name = "nvim", argv = { 12 } } } },
      { pane = { cwd = false } },
    } do
      local d = doc "invalid"
      d.windows[1].tabs[1].root = root
      assert.is_false(store.validate(d))
    end
    local d = doc "invalid"
    d.schema_version = 1.5
    assert.is_nil(store.migrate(d))
  end)

  it("ignores orphan temporary files when listing sessions", function()
    local wt = require "wezterm"
    wt._dirs[store.dir()] = { store.path_for "a" .. ".tmp", store.path_for "a" .. ".bak" }
    assert.same({}, store.list())
  end)

  it("reports missing directories and atomic write failures", function()
    local util = require "harbor.util"
    local deps = require "harbor.deps"
    local mkdir, write = util.mkdir, deps.memo.state.write_atomic
    util.mkdir = function()
      return false
    end
    local ok, err = store.write(doc "fail")
    util.mkdir = mkdir
    assert.is_false(ok)
    assert.truthy(err:find("cannot create", 1, true))
    deps.memo.state.write_atomic = function()
      return false
    end
    ok, err = store.write(doc "fail")
    deps.memo.state.write_atomic = write
    assert.is_false(ok)
    assert.truthy(err:find("write failed", 1, true))
  end)

  it("rejects corrupt and oversized backups through normal validation", function()
    local path = store.path_for "bad" .. ".bak"
    local fh = assert(io.open(path, "wb"))
    fh:write "{bad"
    fh:close()
    local recovered, err = store.read("bad", { backup = true })
    assert.is_nil(recovered)
    assert.truthy(err:find("invalid JSON", 1, true))
    require("harbor.config").setup { sessions = { dir = dir, max_file_bytes = 1024 } }
    fh = assert(io.open(path, "wb"))
    fh:write(string.rep(" ", 2048))
    fh:close()
    recovered, err = store.read("bad", { backup = true })
    assert.is_nil(recovered)
    assert.truthy(err:find("limit", 1, true))
  end)

  it("rejects non-advancing migrations rather than looping", function()
    local version = store.SCHEMA_VERSION
    store.SCHEMA_VERSION = 2
    store.migrations[1] = function(d)
      return d
    end
    local migrated, err = store.migrate(doc "a")
    store.SCHEMA_VERSION, store.migrations[1] = version, nil
    assert.is_nil(migrated)
    assert.truthy(err:find("did not advance", 1, true))
  end)

  it("reports failure to delete the old session after rename", function()
    assert.is_true(store.write(doc "a"))
    local remove = os.remove
    os.remove = function(path)
      if path == store.path_for "a" then
        return nil, "denied"
      end
      return remove(path)
    end
    local ok, err = store.rename("a", "b")
    os.remove = remove
    assert.is_false(ok)
    assert.equal("denied", err)
    assert.equal("a", assert(store.read "a").name)
    assert.equal("b", assert(store.read "b").name)
  end)

  it("reports a backup removal failure rather than claiming full deletion", function()
    assert.is_true(store.write(doc "a"))
    assert.is_true(store.write(doc "a"))
    local remove = os.remove
    os.remove = function(path)
      if path == store.path_for "a" .. ".bak" then
        return nil, "denied"
      end
      return remove(path)
    end
    local ok, err = store.delete "a"
    os.remove = remove
    assert.is_false(ok)
    assert.truthy(err:find("backup removal failed", 1, true))
    assert.truthy(store.read("a", { backup = true }))
  end)
end)
