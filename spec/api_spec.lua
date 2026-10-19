local env = require "spec.support.env"

describe("harbor.api", function()
  local api

  before_each(function()
    env.setup()
    api = require "harbor.api"
  end)

  it("registers the picker key table", function()
    local c = { key_tables = { other = {} } }
    assert.equal(c, api.apply_to_config(c))
    assert.is_table(c.key_tables.harbor_picker)
    assert.is_table(c.key_tables.other)
    assert.is_true(require("harbor.state").key_table_ready)
  end)

  it("uses the configured key table name", function()
    api.setup { picker = { key_table = "mine" } }
    local c = api.apply_to_config {}
    assert.is_table(c.key_tables.mine)
  end)

  it("installs and replaces optional adapters before registration", function()
    api.setup { picker = { hint_position = "status", key_table = "custom" } }
    local adapter = {
      keys = { { key = "RightArrow", mods = "ALT", desc = "next hints" } },
      open = function() end,
    }
    api.set_picker_adapter(adapter)
    local c = api.apply_to_config {}
    assert.equal(6, #c.key_tables.custom)
    api.set_picker_adapter(adapter)
    api.apply_to_config(c)
    assert.equal(6, #c.key_tables.custom)
    api.set_picker_adapter(nil)
    api.apply_to_config(c)
    assert.equal(5, #c.key_tables.custom)
  end)

  it("actions return callbacks", function()
    for _, name in ipairs {
      "pick",
      "workspaces",
      "projects",
      "sessions",
      "domains",
      "previous",
      "save",
      "restore",
      "new",
      "new_at_path",
      "rename",
      "close",
      "refresh",
    } do
      local a = api.action[name]()
      assert.is_function(a.callback, name)
    end
  end)

  it("action callbacks never raise", function()
    local a = api.action.previous()
    assert.has_no.errors(function()
      a.callback(nil, nil)
    end)
  end)

  it("exposes version and events", function()
    assert.matches("^%d+%.%d+%.%d+$", api.VERSION)
    assert.is_true(#api.events > 0)
  end)
end)
