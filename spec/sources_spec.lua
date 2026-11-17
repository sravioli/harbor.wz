local env = require "spec.support.env"

describe("harbor sources", function()
  local wezterm = require "wezterm"

  before_each(function()
    env.setup()
  end)

  describe("zoxide.parse", function()
    it("parses scores, filters and limits", function()
      local z = require "harbor.sources.zoxide"
      local text = "  12.5 /a/one\n   3.0 /a/two\n  0.5 /a/three\nnot a line\n"
      local all = z.parse(text, {})
      assert.are.equal(3, #all)
      assert.are.equal("/a/one", all[1].path)
      assert.are.equal("zoxide", all[1].source)
      assert.are.equal(2, #z.parse(text, { min_score = 1 }))
      assert.are.equal(1, #z.parse(text, { limit = 1 }))
    end)

    it("collect returns nothing when zoxide is missing", function()
      local z = require "harbor.sources.zoxide"
      assert.are.same({}, z.collect { enabled = true, path = "/does/not/exist/zoxide" })
    end)
  end)

  describe("projects", function()
    local p

    before_each(function()
      p = require "harbor.sources.projects"
    end)

    it("builds an fd argv without a shell", function()
      local argv = p.fd_argv("fd", "/r", 2, { "node_modules" })
      assert.are.equal("fd", argv[1])
      assert.are.equal("/r", argv[#argv])
      assert.are.equal("^\\.git$", argv[#argv - 1])
      local joined = table.concat(argv, " ")
      assert.truthy(joined:find("--max-depth=3", 1, true))
      assert.truthy(joined:find("--exclude=node_modules", 1, true))
      assert.truthy(joined:find("--prune", 1, true))
    end)

    it("parses fd output into repo roots", function()
      local out = p.parse_fd "/r/a/.git\n/r/b/.git/\nC:\\r\\c\\.git\n/r/noise\n"
      assert.are.same({ "/r/a", "/r/b", "C:/r/c" }, out)
    end)

    it("walk finds repos and prunes below them", function()
      wezterm._dirs["/r"] = { "/r/a", "/r/b", "/r/node_modules", "/r/.hidden" }
      wezterm._dirs["/r/a"] = { "/r/a/.git", "/r/a/sub" }
      wezterm._dirs["/r/a/sub"] = { "/r/a/sub/.git" }
      wezterm._dirs["/r/b"] = { "/r/b/c" }
      wezterm._dirs["/r/b/c"] = { "/r/b/c/.git" }
      wezterm._dirs["/r/node_modules"] = { "/r/node_modules/x" }
      wezterm._dirs["/r/node_modules/x"] = { "/r/node_modules/x/.git" }
      -- Dot-folders are scanned, as `fd --hidden` does.
      wezterm._dirs["/r/.hidden"] = { "/r/.hidden/.git" }
      local out = p.walk("/r", 3, { node_modules = true })
      table.sort(out)
      assert.are.same({ "/r/.hidden", "/r/a", "/r/b/c" }, out)
    end)
  end)

  describe("domains.kind", function()
    it("classifies by prefix", function()
      local d = require "harbor.sources.domains"
      assert.are.equal("ssh", d.kind "SSH:host")
      assert.are.equal("sshmux", d.kind "SSHMUX:host")
      assert.are.equal("wsl", d.kind "WSL:Ubuntu")
      assert.are.equal("local", d.kind "local")
    end)
  end)

  describe("pipeline", function()
    local sources, state

    before_each(function()
      sources = require "harbor.sources"
      state = require "harbor.state"
    end)

    it("dedupes saved sessions and dirs into live workspaces", function()
      state.set_workspace_path("api", "/w/api")
      local groups = {
        { { kind = "workspace", name = "api" }, { kind = "workspace", name = "web" } },
        { { kind = "saved", name = "api", file = "f" }, { kind = "saved", name = "old" } },
        {
          { kind = "dir", path = "/w/api" },
          { kind = "dir", path = "/w/other" },
          { kind = "dir", path = "/w/other" },
        },
        { { kind = "domain", domain = "SSH:x" } },
      }
      local out = sources.dedupe(groups, { current = "web", previous = "api" })
      local ids = {}
      for _, e in ipairs(out) do
        ids[#ids + 1] = e.id
      end
      assert.are.same({ "ws:api", "ws:web", "sv:old", "dir:/w/other", "dom:SSH:x" }, ids)
      assert.is_true(out[1].saved)
      assert.is_true(out[1].previous)
      assert.is_true(out[2].current)
    end)

    it("sorts grouped by kind, previous first and current last", function()
      local entries = {
        { kind = "dir", path = "/b" },
        { kind = "workspace", name = "zed", current = true },
        { kind = "workspace", name = "alpha" },
        { kind = "workspace", name = "beta", previous = true },
        { kind = "saved", name = "s" },
      }
      local out = sources.sort(entries, "mru")
      local names = {}
      for _, e in ipairs(out) do
        names[#names + 1] = e.name or e.path
      end
      assert.are.same({ "beta", "alpha", "zed", "s", "/b" }, names)
    end)

    it("alpha sort is case-insensitive", function()
      local out = sources.sort({
        { kind = "workspace", name = "b" },
        { kind = "workspace", name = "A" },
      }, "alpha")
      assert.are.equal("A", out[1].name)
    end)

    it("list applies kinds, show_current and a failing filter safely", function()
      wezterm._workspaces = { "default", "api" }
      require("harbor.config").setup {
        sessions = { dir = env.setup() },
        sources = { zoxide = { enabled = false }, projects = { enabled = false } },
        picker = {
          show_current = false,
          filter = function(e)
            if e.name == "api" then
              error "filter bug"
            end
            return true
          end,
        },
      }
      wezterm._workspaces = { "default", "api" }
      local out = sources.list { current = "default", kinds = { workspace = true } }
      assert.are.equal(1, #out)
      assert.are.equal("api", out[1].name)
    end)

    it("custom sources accept strings and tables", function()
      require("harbor.config").setup {
        sessions = { dir = env.setup() },
        sources = {
          order = {},
          custom = {
            function()
              return { "/c/one", { name = "wsx" }, 42 }
            end,
            function()
              error "custom broke"
            end,
          },
        },
      }
      local out = sources.list {}
      assert.are.equal(2, #out)
    end)
  end)
end)
