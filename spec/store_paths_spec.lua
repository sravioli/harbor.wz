local env = require "spec.support.env"
local wt = require "wezterm"

describe("harbor.session.store edge cases", function()
  local store, dir, saved

  local function patch(module, key, value)
    saved[#saved + 1] = { module, key, module[key] }
    module[key] = value
  end

  local function doc(name)
    return {
      name = name,
      windows = { { tabs = { { root = { pane = { cwd = "/w" } } } } } },
    }
  end

  before_each(function()
    dir = env.setup()
    store = require "harbor.session.store"
    saved = {}
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      saved[i][1][saved[i][2]] = saved[i][3]
    end
    env.rmdir(dir)
  end)

  describe("validate", function()
    local function with_leaf(leaf)
      local d = doc "a"
      d.windows[1].tabs[1].root = { pane = leaf }
      return d
    end

    it("rejects a pane with a badly typed field", function()
      assert.is_false(store.validate(with_leaf { cwd = 1 }))
      assert.is_false(store.validate(with_leaf { active = "yes" }))
      assert.is_false(store.validate(with_leaf "not a table"))
    end)

    it("rejects a pane process that is malformed or does not match its argv", function()
      assert.is_false(store.validate(with_leaf { process = "nvim" }))
      assert.is_false(store.validate(with_leaf { process = { name = 1, argv = { "a" } } }))
      assert.is_false(store.validate(with_leaf { process = { name = "a", argv = {} } }))
      assert.is_false(store.validate(with_leaf { process = { name = "a", argv = { 1 } } }))
      assert.is_false(store.validate(with_leaf { process = { name = "a", argv = { "a\1b" } } }))
      assert.is_false(
        store.validate(with_leaf { process = { name = "other", argv = { "/bin/nvim" } } })
      )
      assert.is_true(
        store.validate(with_leaf { process = { name = "nvim", argv = { "/bin/nvim" } } })
      )
    end)

    it("rejects a bad path, schema version, tab or window title", function()
      local d = doc "a"
      d.path = 1
      assert.same({ false, "invalid workspace path" }, { store.validate(d) })

      d = doc "a"
      d.schema_version = "x"
      assert.same({ false, "invalid schema version" }, { store.validate(d) })

      d.schema_version = store.SCHEMA_VERSION + 1
      assert.same({ false, "session was written by a newer harbor" }, { store.validate(d) })

      d = doc "a"
      d.windows[1].tabs[1].title = 5
      assert.matches("invalid metadata", select(2, store.validate(d)))

      d = doc "a"
      d.windows[1].title = 5
      assert.matches("invalid title", select(2, store.validate(d)))
    end)
  end)

  describe("migrate", function()
    local function migrations(steps, version)
      patch(store, "migrations", steps)
      patch(store, "SCHEMA_VERSION", version)
    end

    it("rejects an unusable schema version", function()
      assert.same({ nil, "invalid schema version" }, { store.migrate { schema_version = "x" } })
    end)

    it("reports a missing, failing or non-advancing migration step", function()
      migrations({}, 3)
      assert.matches("no migration from schema 1", select(2, store.migrate(doc "a")))

      migrations({
        [1] = function()
          error "boom"
        end,
      }, 2)
      assert.matches("migration failed from schema 1", select(2, store.migrate(doc "a")))

      migrations({
        [1] = function(d)
          d.schema_version = 1
          return d
        end,
      }, 2)
      assert.matches("did not advance", select(2, store.migrate(doc "a")))
    end)

    it("applies a migration and stamps the current version", function()
      migrations({
        [1] = function(d)
          d.schema_version = 2
          d.migrated = true
          return d
        end,
      }, 2)
      local out = store.migrate(doc "a")
      assert.is_true(out.migrated)
      assert.equal(2, out.schema_version)
    end)
  end)

  describe("write", function()
    it("logs when the directory cannot be restricted", function()
      store._restricted[dir .. "/sessions"] = nil
      local process = require("harbor.deps").warp.process
      patch(process, "run", function()
        return false, "", "no chmod"
      end)
      assert.is_true(store.write(doc "w"))
    end)

    it("fails without serde, and when encoding fails", function()
      local serde = wt.serde
      wt.serde = nil
      assert.same({ false, "wezterm.serde is unavailable" }, { store.write(doc "w") })
      wt.serde = {
        json_encode = function()
          error "cannot encode"
        end,
        json_decode = serde.json_decode,
      }
      assert.matches("encode failed", select(2, store.write(doc "w")))
      wt.serde = serde
    end)
  end)

  describe("read and list", function()
    it("reports an empty session file", function()
      local path = store.path_for "e"
      local fh = assert(io.open(path, "wb"))
      fh:close()
      assert.matches("empty session file", select(2, store.read "e"))
    end)

    it("rejects a session that fails validation after migrating", function()
      patch(store, "migrate", function()
        return { name = "broken" } -- no windows
      end)
      assert(store.write(doc "m"))
      local read, err = store.read "m"
      assert.is_nil(read)
      assert.equal("missing windows", err)
    end)

    it("lists nothing when the directory cannot be read", function()
      patch(wt, "read_dir", function()
        error "unreadable"
      end)
      assert.same({}, store.list())
    end)
  end)

  describe("rename", function()
    it("is a no-op for the same name, and passes on a read or write failure", function()
      assert.is_true(store.rename("a", "a"))
      assert.is_false(store.rename("missing", "other"))

      assert(store.write(doc "src"))
      patch(store, "write", function()
        return false, "disk full"
      end)
      assert.same({ false, "disk full" }, { store.rename("src", "dst") })
    end)
  end)
end)
