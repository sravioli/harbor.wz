local env = require "spec.support.env"
local wt = require "wezterm"

describe("harbor domain, dir, project and zoxide sources", function()
  local dir

  before_each(function()
    dir = env.setup()
  end)

  after_each(function()
    env.rmdir(dir)
  end)

  describe("domains", function()
    local domains

    before_each(function()
      domains = require "harbor.sources.domains"
    end)

    it("classifies every kind of domain name", function()
      assert.equal("local", domains.kind "local")
      assert.equal("sshmux", domains.kind "SSHMUX:host")
      assert.equal("ssh", domains.kind "SSH:host")
      assert.equal("wsl", domains.kind "WSL:Ubuntu")
      assert.equal("tls", domains.kind "TLS:server")
      assert.equal("unix", domains.kind "Unix-Socket")
      assert.equal("other", domains.kind "mine")
    end)

    it("filters by kind, exact name and Lua pattern, ignoring a bad pattern", function()
      local opts = { kinds = { "ssh", "other" }, ignore = { "skip" }, ignore_patterns = { "^tmp" } }
      assert.is_true(domains.allowed("SSH:host", opts))
      assert.is_false(domains.allowed("WSL:Ubuntu", opts)) -- kind not allowed
      assert.is_false(domains.allowed("skip", opts))
      assert.is_false(domains.allowed("tmp-one", opts))
      opts.ignore_patterns = { "[" } -- malformed: ignored rather than raising
      assert.is_true(domains.allowed("tmp-one", opts))
    end)

    it("collects the spawnable domains that are allowed", function()
      local function domain(name, spawnable)
        return {
          name = function()
            return name
          end,
          is_spawnable = function()
            if spawnable == "error" then
              error "unknown"
            end
            return spawnable
          end,
        }
      end
      local all = wt.mux.all_domains
      wt.mux.all_domains = function()
        return {
          domain("SSH:a", true),
          domain("SSH:b", false), -- not spawnable
          domain("SSH:c", "error"), -- unknown spawnability counts as spawnable
          {
            name = function()
              error "no name"
            end,
            is_spawnable = function()
              return true
            end,
          },
        }
      end
      local opts = { kinds = { "ssh" }, ignore = {}, ignore_patterns = {} }
      local out = domains.collect(opts)
      assert.same({ "SSH:a", "SSH:c" }, { out[1].domain, out[2].domain })
      assert.equal("ssh", out[1].domain_kind)

      wt.mux.all_domains = function()
        error "no mux"
      end
      assert.same({}, domains.collect(opts))
      wt.mux.all_domains = function()
        return "nope"
      end
      assert.same({}, domains.collect(opts))
      wt.mux.all_domains = all
    end)
  end)

  it("lists the configured directories that exist", function()
    local out = require("harbor.sources.dirs").collect { paths = { dir, "/no/such/dir/here" } }
    assert.equal(1, #out)
    assert.equal("dirs", out[1].source)
  end)

  describe("projects", function()
    local projects, process, saved

    before_each(function()
      projects = require "harbor.sources.projects"
      process = require("harbor.deps").warp.process
      saved = { which = process.which, run = process.run }
      wt._dirs["/r"] = { "/r/a", "/r/b" }
      wt._dirs["/r/a"] = { "/r/a/.git" }
      wt._dirs["/r/b"] = { "/r/b/.git" }
    end)

    after_each(function()
      process.which, process.run = saved.which, saved.run
    end)

    local function base(extra)
      local o = {
        roots = { "/r" },
        max_depth = 3,
        exclude = { "node_modules" },
        include_roots = false,
        fd_path = nil,
      }
      for k, v in pairs(extra or {}) do
        o[k] = v
      end
      return o
    end

    it("takes a root as a table with its own depth", function()
      local out = projects.collect(base { roots = { { path = "/r", max_depth = 1 } } })
      assert.equal(2, #out)
    end)

    it("returns nothing for an unreadable directory", function()
      assert.same({}, projects.walk("/missing/root", 2, {}))
    end)

    it("uses fd when it is installed, and lists the roots when asked", function()
      process.which = function()
        return "/usr/bin/fd"
      end
      local argv
      process.run = function(args)
        argv = args
        return true, "/r/a/.git/\n/r/b/.git/\n", ""
      end
      local out = projects.collect(base { include_roots = true })
      assert.equal("/usr/bin/fd", argv[1])
      assert.same({ "/r", "/r/a", "/r/b" }, { out[1].path, out[2].path, out[3].path })
    end)

    it("falls back to walking the tree when fd fails", function()
      process.which = function(name)
        return name == "fd" and "/usr/bin/fd" or nil
      end
      process.run = function()
        return false, "", "fd exploded"
      end
      local out = projects.collect(base())
      assert.same({ "/r/a", "/r/b" }, { out[1].path, out[2].path })
    end)

    it("skips a root that cannot be cleaned", function()
      process.which = function()
        return nil
      end
      assert.same({}, projects.collect(base { roots = { "" } }))
    end)
  end)

  describe("zoxide", function()
    local zoxide, process, run

    before_each(function()
      zoxide = require "harbor.sources.zoxide"
      process = require("harbor.deps").warp.process
      run = process.run
    end)

    after_each(function()
      process.run = run
    end)

    it("skips the source when the query fails", function()
      process.run = function()
        return false, "", "boom"
      end
      assert.same({}, zoxide.collect { path = "/bin/zoxide" })
    end)

    it("only adds a directory when it can find zoxide", function()
      local calls = {}
      process.run = function(argv)
        calls[#calls + 1] = argv
        return true, "", ""
      end
      zoxide.add({ path = "/bin/zoxide" }, "/some/dir")
      assert.equal(1, #calls)
      assert.same({ "add", "--", "/some/dir" }, { calls[1][2], calls[1][3], calls[1][4] })
    end)
  end)
end)

describe("harbor.state workspaces", function()
  local state, dir

  before_each(function()
    dir = env.setup()
    state = require "harbor.state"
  end)

  after_each(function()
    env.rmdir(dir)
  end)

  it("moves a workspace's path and protection to its new name", function()
    state.set_workspace_path("old", "/p")
    state.protect("old", "partial")
    state.rename_workspace("old", "new")
    assert.equal("/p", state.workspace_path "new")
    assert.is_nil(state.workspace_path "old")
    assert.equal("partial", state.protection "new")
    assert.is_nil(state.protection "old")
  end)

  it("drops every cached source at once", function()
    local calls = 0
    state.cached("src:x", 60, function()
      calls = calls + 1
      return { 1 }
    end)
    state.invalidate()
    state.cached("src:x", 60, function()
      calls = calls + 1
      return { 1 }
    end)
    assert.equal(2, calls)
  end)
end)

describe("harbor.deps", function()
  local original, preload

  before_each(function()
    original = package.loaded["harbor.deps"]
    preload = {}
    for _, name in ipairs { "warp.api", "sigil.api" } do
      preload[name] = { package.loaded[name], package.preload[name] }
    end
  end)

  after_each(function()
    package.loaded["harbor.deps"] = original
    for name, saved in pairs(preload) do
      package.loaded[name], package.preload[name] = saved[1], saved[2]
    end
    wt.plugin.require = function(url)
      error("plugin.require disabled in specs: " .. url)
    end
  end)

  local function reload()
    package.loaded["harbor.deps"] = nil
    return require "harbor.deps"
  end

  it("falls back to the plugin url, and raises when a required plugin is missing", function()
    package.loaded["warp.api"] = nil
    package.preload["warp.api"] = function()
      error "not on the path"
    end
    local from_url = { from = "url" }
    wt.plugin.require = function(url)
      if url:find("warp.wz", 1, true) then
        return from_url
      end
      error "offline"
    end
    assert.equal(from_url, reload().warp)

    wt.plugin.require = function()
      error "offline"
    end
    assert.has_error(function()
      reload()
    end)
  end)

  it("leaves an optional plugin out when it cannot be loaded", function()
    package.loaded["sigil.api"] = nil
    package.preload["sigil.api"] = function()
      error "not on the path"
    end
    assert.is_nil(reload().sigil)
  end)
end)
