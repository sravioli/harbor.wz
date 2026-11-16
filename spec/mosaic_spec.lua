-- Checked first: loading harbor must not read its mosaic integration.
local read_by_harbor = package.loaded["harbor.mosaic.session"] ~= nil

local env = require "spec.support.env"

describe("mosaic integration harbor.session", function()
  local harbor, descriptor, saved
  local mosaic = {
    palette = {
      accent = function(i)
        return function()
          return { fg = "accent" .. i }
        end
      end,
    },
  }
  local window = {
    active_workspace = function()
      return "work"
    end,
  }

  before_each(function()
    env.setup()
    harbor = require "harbor.api"
    descriptor = require "harbor.mosaic.session"
    saved = {}
    harbor.has_session = function(name)
      return saved[name] == true
    end
  end)

  it("is not read when harbor loads", function()
    assert.is_false(read_by_harbor)
  end)

  it("follows the descriptor contract", function()
    assert.equal(1, descriptor.api)
    assert.is_function(descriptor.new)
    assert.is_function(descriptor.new({}, mosaic))
    for _, event in ipairs(descriptor.events) do
      assert.is_truthy(event:match "^harbor%.")
    end
  end)

  it("hides without a saved session", function()
    assert.is_false(descriptor.new({}, mosaic)(window).enabled)
  end)

  it("marks a workspace with a saved session", function()
    saved.work = true
    local spec = descriptor.new({}, mosaic)(window)
    assert.is_true(spec.enabled)
    assert.is_false(spec.text.enabled)
    assert.equals(3, spec.accent)
    assert.is_nil(spec.style) -- content only: the preset decorates it
  end)

  it("can show the workspace name and hide the icon", function()
    saved.work = true
    local spec = descriptor.new({ name = true, icon = false }, mosaic)(window)
    assert.is_true(spec.text.enabled)
    assert.equal("work", spec.text.value)
    assert.is_false(spec.icon.enabled)
  end)
end)
