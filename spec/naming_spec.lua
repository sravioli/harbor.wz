local env = require "spec.support.env"

describe("harbor.naming", function()
  local naming

  before_each(function()
    env.setup()
    naming = require "harbor.naming"
  end)

  it("uses the basename by default", function()
    assert.are.equal("proj", naming.base_name "/home/u/dev/proj/")
  end)

  it("honours style, replace_dots and max_length", function()
    require("harbor.config").setup { naming = { replace_dots = true, max_length = 8 } }
    assert.are.equal("my_xyza…", naming.base_name "/x/my.xyzabcdef")
    assert.are.equal("àèìòù", naming.base_name "/x/àèìòù")
    assert.are.equal("àèìòùàè…", naming.base_name "/x/àèìòùàèìòù")
    require("harbor.config").setup { naming = { style = "path" } }
    assert.are.equal("/x/a", naming.base_name "/x/a")
  end)

  it("prefers a custom naming fn and falls back when it errors", function()
    require("harbor.config").setup {
      naming = {
        fn = function(p)
          if p:find "boom" then
            error "nope"
          end
          return "custom"
        end,
      },
    }
    assert.are.equal("custom", naming.base_name "/a/b")
    assert.are.equal("boom", naming.base_name "/a/boom")
  end)

  describe("unique_name", function()
    it("reuses a name owned by the same path", function()
      assert.are.equal("api", naming.unique_name("/w/api", { api = "/w/api" }))
    end)

    it("qualifies with the parent dir on collision", function()
      assert.are.equal("api (b)", naming.unique_name("/b/api", { api = "/a/api" }))
    end)

    it("falls back to a counter", function()
      local taken = { api = "/a/api", ["api (b)"] = true, ["api (2)"] = true }
      assert.are.equal("api (3)", naming.unique_name("/b/api", taken))
    end)
  end)

  describe("encode/decode", function()
    it("round-trips arbitrary names", function()
      for _, name in ipairs { "plain", "with space", "a/b\\c:d*?", "ünïcødé", "100%" } do
        local stem = naming.encode(name)
        assert.is_nil(stem:find '[/\\:*?"<>|]')
        assert.are.equal(name, naming.decode(stem))
      end
    end)

    it("caps long names with a hash suffix", function()
      local a = naming.encode(string.rep("x", 300) .. "1")
      local b = naming.encode(string.rep("x", 300) .. "2")
      assert.is_true(#a <= 120)
      assert.are_not.equal(a, b)
    end)
  end)
end)
