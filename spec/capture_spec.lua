local env = require "spec.support.env"

describe("harbor.session.capture", function()
  local capture

  before_each(function()
    env.setup()
    capture = require "harbor.session.capture"
  end)

  describe("sanitize", function()
    it("keeps SGR and printable text", function()
      local s = "\27[1;31mred\27[0m plain\tok\r\n"
      assert.are.equal(s, capture.sanitize(s))
    end)

    it("drops OSC, DCS, cursor movement and C0 controls", function()
      local s = "a\27]0;title\7b\27]52;c;ZXZpbA==\27\\c\27[2J\27[10;5Hd\27P1$r\27\\e\27=f\1\127g"
      assert.are.equal("abcdefg", capture.sanitize(s))
    end)

    it("handles non-strings", function()
      assert.are.equal("", capture.sanitize(nil))
    end)
  end)

  describe("trim", function()
    it("removes trailing blank (and colour-only) lines", function()
      assert.are.equal("a\nb", capture.trim("a\nb\n  \n\27[0m\n", 0))
      assert.are.equal("", capture.trim("\n\n", 0))
    end)

    it("keeps whole lines from the end within the byte cap", function()
      assert.are.equal("cc\ndd", capture.trim("aa\nbb\ncc\ndd", 6))
    end)
  end)

  it("process_name normalizes executables", function()
    assert.are.equal("nvim", capture.process_name "C:\\tools\\NVIM.EXE")
    assert.are.equal("htop", capture.process_name "/usr/bin/htop")
    assert.is_nil(capture.process_name "")
  end)

  describe("tree", function()
    local function leaf(i)
      return i.id
    end

    it("single pane", function()
      assert.are.same(
        { pane = 1 },
        capture.tree({ { id = 1, left = 0, top = 0, width = 80, height = 24 } }, leaf)
      )
    end)

    it("vertical split with sizes", function()
      local t = capture.tree({
        { id = 1, left = 0, top = 0, width = 60, height = 24 },
        { id = 2, left = 61, top = 0, width = 39, height = 24 },
      }, leaf)
      assert.are.equal("Right", t.split)
      assert.are.same({ pane = 1 }, t.first)
      assert.are.same({ pane = 2 }, t.second)
      assert.is_true(t.size > 0.35 and t.size < 0.45)
    end)

    it("nested layout: left | (top / bottom)", function()
      local t = capture.tree({
        { id = 1, left = 0, top = 0, width = 40, height = 24 },
        { id = 2, left = 41, top = 0, width = 39, height = 12 },
        { id = 3, left = 41, top = 13, width = 39, height = 11 },
      }, leaf)
      assert.are.equal("Right", t.split)
      assert.are.equal("Bottom", t.second.split)
      assert.are.same({ pane = 3 }, t.second.second)
    end)

    it("falls back for irregular (pinwheel) layouts", function()
      local t = capture.tree({
        { id = 1, left = 0, top = 0, width = 20, height = 10 },
        { id = 2, left = 20, top = 0, width = 10, height = 20 },
        { id = 3, left = 10, top = 20, width = 20, height = 10 },
        { id = 4, left = 0, top = 10, width = 10, height = 20 },
        { id = 5, left = 10, top = 10, width = 10, height = 10 },
      }, leaf)
      local count = 0
      local function walk(n)
        if n.pane then
          count = count + 1
        else
          walk(n.first)
          walk(n.second)
        end
      end
      walk(t)
      assert.are.equal(5, count)
    end)
  end)

  describe("pane", function()
    local function fake(o)
      return {
        get_current_working_dir = function()
          -- legacy string form (real Url userdata can't be built in plain Lua)
          return "file://host" .. (o.cwd or "/w/p")
        end,
        get_domain_name = function()
          return o.domain or "local"
        end,
        get_title = function()
          return "t"
        end,
        is_alt_screen_active = function()
          return o.alt or false
        end,
        get_foreground_process_info = function()
          return { executable = o.exe or "/bin/bash", argv = o.argv or { "bash" } }
        end,
        get_lines_as_escapes = function()
          return "hello\27]0;x\7\n"
        end,
      }
    end

    local function opts()
      local cfg = require("harbor.config").get().sessions
      return {
        scrollback = cfg.scrollback,
        processes = cfg.processes,
        allow = require("harbor.config").process_allowlist(),
      }
    end

    it("records allowlisted processes and sanitized scrollback", function()
      local d =
        capture.pane({ pane = fake { exe = "/usr/bin/nvim", argv = { "nvim", "x.lua" } } }, opts())
      assert.are.equal("/w/p", d.cwd)
      assert.are.same({ name = "nvim", argv = { "nvim", "x.lua" } }, d.process)
      assert.are.equal("hello", d.scrollback)
    end)

    it("never records non-allowlisted processes", function()
      local d =
        capture.pane({ pane = fake { exe = "/usr/bin/ssh", argv = { "ssh", "secret" } } }, opts())
      assert.is_nil(d.process)
    end)

    it("skips scrollback on the alt screen and for remote panes", function()
      assert.is_nil(capture.pane({ pane = fake { alt = true } }, opts()).scrollback)
      local remote =
        capture.pane({ pane = fake { domain = "SSH:h", exe = "/usr/bin/nvim" } }, opts())
      assert.is_nil(remote.scrollback)
      assert.is_nil(remote.process)
    end)
  end)
end)
