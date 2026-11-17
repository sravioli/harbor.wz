local env = require "spec.support.env"
local wt = require "wezterm"

describe("harbor.util platform paths", function()
  local util, fs, dir, saved

  local function patch(module, key, value)
    saved[#saved + 1] = { module, key, module[key] }
    module[key] = value
  end

  before_each(function()
    dir = env.setup()
    util = require "harbor.util"
    fs = require("harbor.deps").warp.filesystem
    saved = {}
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      saved[i][1][saved[i][2]] = saved[i][3]
    end
    env.rmdir(dir)
  end)

  it("lowercases path keys on Windows only", function()
    assert.equal("/Some/Dir", util.path_key "/Some/Dir")
    patch(fs, "is_win", true)
    assert.equal("/some/dir", util.path_key "/Some/Dir")
  end)

  it("has no dirname for a bare name", function()
    assert.is_nil(util.dirname "bare")
    assert.equal("/a", util.dirname "/a/b")
  end)

  it("has no pane directory when it cannot be read", function()
    assert.is_nil(util.pane_cwd(nil))
    patch(fs, "get_cwd", function()
      error "no cwd"
    end)
    assert.is_nil(util.pane_cwd {})
    fs.get_cwd = function()
      return ""
    end
    assert.is_nil(util.pane_cwd {})
  end)

  describe("data_dir", function()
    before_each(function()
      require("harbor.config").setup {} -- no sessions.dir: use the platform default
      patch(fs, "home", "/home/me")
      patch(fs, "is_win", false)
      patch(fs, "platform", function()
        return { is_mac = false }
      end)
    end)

    local function with_env(vars, fn)
      local getenv = os.getenv
      os.getenv = function(name)
        if vars[name] ~= nil then
          return vars[name] or nil
        end
        return getenv(name)
      end
      local ok, err = pcall(fn)
      os.getenv = getenv
      assert(ok, err)
    end

    it("follows XDG_STATE_HOME on Linux, and falls back to ~/.local/state", function()
      with_env({ XDG_STATE_HOME = "/xdg" }, function()
        assert.equal("/xdg/wezterm/harbor", util.data_dir())
      end)
      with_env({ XDG_STATE_HOME = "" }, function()
        assert.equal("/home/me/.local/state/wezterm/harbor", util.data_dir())
      end)
    end)

    it("uses ~/.local/state on macOS, or an existing Application Support directory", function()
      fs.platform = function()
        return { is_mac = true }
      end
      local legacy = "/home/me/Library/Application Support/wezterm/harbor"
      with_env({ XDG_STATE_HOME = "" }, function()
        patch(fs, "is_dir", function()
          return false
        end)
        assert.equal("/home/me/.local/state/wezterm/harbor", util.data_dir())
        fs.is_dir = function(p)
          return p == legacy
        end
        assert.equal(legacy, util.data_dir())
      end)
    end)

    it("uses LOCALAPPDATA on Windows, or AppData/Local under the home directory", function()
      fs.is_win = true
      with_env({ LOCALAPPDATA = "C:/Local" }, function()
        assert.equal("C:/Local/wezterm/harbor", util.data_dir())
      end)
      with_env({ LOCALAPPDATA = false }, function()
        assert.equal("/home/me/AppData/Local/wezterm/harbor", util.data_dir())
      end)
    end)
  end)

  it("logs and reports a directory that cannot be created", function()
    patch(fs, "mkdir", function()
      return false, "denied"
    end)
    assert.is_false(util.mkdir "/nope")
  end)

  it("finds the wezterm executable next to the running binary, or on the path", function()
    patch(wt, "executable_dir", nil)
    local process = require("harbor.deps").warp.process
    patch(process, "which", function(name)
      return name == "wezterm" and "/usr/bin/wezterm" or nil
    end)
    assert.equal("/usr/bin/wezterm", util.wezterm_exe())
    process.which = function()
      return nil
    end
    assert.equal("wezterm", util.wezterm_exe())
  end)

  it("describes ages from just now to days", function()
    assert.is_nil(util.ago(nil))
    assert.is_nil(util.ago(0))
    assert.equal("just now", util.ago(1000, 1030))
    assert.equal("5m ago", util.ago(1000, 1300))
    assert.equal("2h ago", util.ago(1000, 1000 + 7200))
    assert.equal("3d ago", util.ago(1000, 1000 + 3 * 86400))
  end)

  it("accepts a plain question for a confirmation", function()
    local performed
    local window = {
      perform_action = function(_, action)
        performed = action
      end,
    }
    local answers = {}
    util.confirm(window, "pane", "Sure?", function()
      answers[#answers + 1] = "yes"
    end, function()
      answers[#answers + 1] = "no"
    end)
    assert.matches("Sure%?", performed.args.description)
    performed.args.action.callback(window, "pane", "yes")
    performed.args.action.callback(window, "pane", "no")
    assert.same({ "yes", "no" }, answers)
  end)
end)
