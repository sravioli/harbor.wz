local env = require "spec.support.env"

describe("harbor.config", function()
  local config

  before_each(function()
    env.setup()
    config = require "harbor.config"
  end)

  it("provides defaults", function()
    local cfg = config.parse()
    assert.are.equal("basename", cfg.naming.style)
    assert.are.equal("harbor_picker", cfg.picker.key_table)
    assert.are.equal("top", cfg.picker.hint_position)
    assert.is_false(cfg.sessions.autosave.enabled)
  end)

  it("validates hint placement with field-level fallback", function()
    for _, position in ipairs { "top", "status", "none" } do
      assert.equal(
        position,
        config.parse({ picker = { hint_position = position } }).picker.hint_position
      )
    end
    for _, invalid in ipairs { "bottom", "", false, 42 } do
      local cfg = config.parse { picker = { hint_position = invalid, title = "Ports" } }
      assert.equal("top", cfg.picker.hint_position)
      assert.equal("Ports", cfg.picker.title)
    end
  end)

  it("keeps valid options when another one is invalid", function()
    local cfg = config.parse {
      naming = { replace_dots = true, max_length = 1 },
      picker = { title = "Ports" },
    }
    assert.is_true(cfg.naming.replace_dots)
    assert.are.equal(64, cfg.naming.max_length)
    assert.are.equal("Ports", cfg.picker.title)
  end)

  it("does not mutate the caller's table", function()
    local opts = { naming = { max_length = 1 } }
    config.parse(opts)
    assert.are.equal(1, opts.naming.max_length)
  end)

  it("rejects non-table options", function()
    assert.are.equal("basename", config.parse("nope").naming.style)
  end)

  it("default picker keys avoid InputSelector navigation keys", function()
    local reserved = { n = true, p = true, j = true, k = true, g = true, c = true }
    for _, k in pairs(config.parse().picker.keys) do
      assert.is_nil(reserved[k.key], k.key)
    end
  end)

  describe("process_allowlist", function()
    it("extends the defaults", function()
      config.setup { sessions = { processes = { allow = { "MyTool" } } } }
      local set = config.process_allowlist()
      assert.is_true(set.nvim)
      assert.is_true(set.mytool)
    end)

    it("replaces the defaults", function()
      config.setup { sessions = { processes = { mode = "replace", allow = { "only" } } } }
      local set = config.process_allowlist()
      assert.is_nil(set.nvim)
      assert.is_true(set.only)
    end)
  end)
end)
