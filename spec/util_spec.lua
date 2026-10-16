local env = require "spec.support.env"

describe("harbor.util", function()
  local util

  before_each(function()
    env.setup()
    util = require "harbor.util"
  end)

  describe("clean_path", function()
    it("rejects empty input", function()
      assert.is_nil(util.clean_path(nil))
      assert.is_nil(util.clean_path "")
    end)

    it("normalizes separators and trailing slashes", function()
      assert.are.equal("C:/a/b", util.clean_path "C:\\a\\b\\")
      assert.are.equal("/a/b", util.clean_path "/a/b//")
      assert.are.equal("/", util.clean_path "/")
      assert.are.equal("C:/", util.clean_path "C:/")
    end)

    it("strips the Windows verbatim prefix and URL drive slash", function()
      assert.are.equal("C:/x", util.clean_path "\\\\?\\C:\\x")
      assert.are.equal("C:/x", util.clean_path "/C:/x")
    end)
  end)

  it("dirname/basename", function()
    assert.are.equal("/a", util.dirname "/a/b")
    assert.are.equal("/", util.dirname "/a")
    assert.are.equal("b", util.basename "/a/b")
  end)

  it("tilde shortens paths under home", function()
    local home = (require("harbor.deps").warp.filesystem.home or ""):gsub("\\", "/")
    assert.are.equal("~", util.tilde(home))
    assert.are.equal("~/x", util.tilde(home .. "/x"))
    assert.are.equal("/elsewhere", util.tilde "/elsewhere")
  end)

  it("data_dir honours sessions.dir", function()
    local dir = env.setup()
    assert.are.equal(dir, util.data_dir())
  end)

  it("try swallows errors and ignores non-functions", function()
    assert.are.same({ false, nil }, { util.try("x", nil) })
    local ok = util.try("x", function()
      error "boom"
    end)
    assert.is_false(ok)
    assert.are.same({ true, 3 }, {
      util.try("x", function(a, b)
        return a + b
      end, 1, 2),
    })
  end)

  it("emit prefixes event names and never raises", function()
    local wezterm = require "wezterm"
    wezterm.on("harbor.thing", function()
      error "handler broke"
    end)
    assert.has_no.errors(function()
      util.emit("thing", nil, nil, { a = 1 })
    end)
    assert.are.equal("harbor.thing", wezterm._emitted[1].name)
  end)
end)
