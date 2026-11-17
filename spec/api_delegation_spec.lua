local env = require "spec.support.env"

---Replace a loaded module with a table whose every function records its call.
local function stub(name, calls)
  local original = package.loaded[name]
  package.loaded[name] = setmetatable({}, {
    __index = function(_, fn)
      return function(...)
        calls[#calls + 1] = { name .. "." .. fn, ... }
        return "ret:" .. fn
      end
    end,
  })
  return function()
    package.loaded[name] = original
  end
end

describe("harbor.api delegation", function()
  local api, calls, restore

  before_each(function()
    env.setup()
    api = require "harbor.api"
    calls = {}
    restore = {}
    for _, name in ipairs {
      "harbor.workspace",
      "harbor.sources",
      "harbor.session.store",
      "harbor.picker",
    } do
      restore[#restore + 1] = stub(name, calls)
    end
  end)

  after_each(function()
    for _, undo in ipairs(restore) do
      undo()
    end
  end)

  local function last()
    return calls[#calls]
  end

  it("hands workspace operations to harbor.workspace with their arguments", function()
    local w, p = {}, {}
    local cases = {
      { "switch", { w, p, "n" }, "harbor.workspace.switch" },
      { "open_dir", { w, p, "/x", { a = 1 } }, "harbor.workspace.open_dir" },
      { "create", { w, p, "n", "/r", {} }, "harbor.workspace.create" },
      { "rename", { w, p, "a", "b" }, "harbor.workspace.rename" },
      { "close", { w, p, "n" }, "harbor.workspace.close" },
      { "previous", { w, p }, "harbor.workspace.previous" },
      { "cycle", { w, p, -1 }, "harbor.workspace.cycle" },
      { "fork", { w, p, "n" }, "harbor.workspace.fork" },
      { "save", { w, p, "n" }, "harbor.workspace.save" },
      { "restore", { w, p, "n", {} }, "harbor.workspace.restore" },
      { "quit", { w, p }, "harbor.workspace.quit" },
      { "save_all", { w, p }, "harbor.workspace.save_all" },
      { "delete_session", { w, p, "n" }, "harbor.workspace.forget" },
    }
    for _, case in ipairs(cases) do
      local before = #calls
      local result = api[case[1]](table.unpack(case[2]))
      assert.equal(before + 1, #calls, case[1])
      assert.equal(case[3], last()[1], case[1])
      assert.equal("ret:" .. case[3]:match "%.([%w_]+)$", result, case[1])
      for i, arg in ipairs(case[2]) do
        assert.equal(arg, last()[i + 1], case[1])
      end
    end
  end)

  it("passes the snapshot kind for tabs and windows", function()
    api.save_tab(1, 2, "n")
    assert.same({ "harbor.workspace.save_snapshot", "tab", 1, 2, "n" }, last())
    api.save_window(1, 2, "n")
    assert.same({ "harbor.workspace.save_snapshot", "window", 1, 2, "n" }, last())
    api.load_tab(1, 2, "n")
    assert.same({ "harbor.workspace.load_snapshot", "tab", 1, 2, "n" }, last())
    api.load_window(1, 2, "n")
    assert.same({ "harbor.workspace.load_snapshot", "window", 1, 2, "n" }, last())
  end)

  it("lists sessions, snapshots and sources through their modules", function()
    assert.equal("ret:list", api.list { x = 1 })
    assert.same({ "harbor.sources.list", { x = 1 } }, last())
    api.snapshots "tab"
    assert.same({ "harbor.session.store.list", "tab" }, last())
    api.sessions()
    assert.same({ "harbor.session.store.list" }, last())
  end)

  it("turns a kinds list into a set before opening the picker", function()
    api.pick("w", "p", { kinds = { "workspace", "dir" }, title = "t" })
    local opts = last()[4]
    assert.same({ workspace = true, dir = true }, opts.kinds)
    api.pick("w", "p")
    assert.same({}, last()[4])
  end)
end)

describe("harbor.api actions", function()
  local api, calls, restore, window, performed

  before_each(function()
    env.setup()
    api = require "harbor.api"
    calls = {}
    restore = {}
    for _, name in ipairs { "harbor.workspace", "harbor.picker" } do
      restore[#restore + 1] = stub(name, calls)
    end
    performed = {}
    window = {
      perform_action = function(_, action, pane)
        performed[#performed + 1] = { action = action, pane = pane }
      end,
      active_workspace = function()
        return "dev"
      end,
      active_tab = function()
        return {
          get_title = function()
            return "tab title"
          end,
        }
      end,
      mux_window = function()
        return {
          get_title = function()
            return "win title"
          end,
        }
      end,
    }
  end)

  after_each(function()
    for _, undo in ipairs(restore) do
      undo()
    end
  end)

  ---Open a prompting action and return its PromptInputLine options.
  local function prompt_of(action)
    action.callback(window, "pane")
    local opts = performed[#performed].action.args
    assert.equal("pane", performed[#performed].pane)
    return opts
  end

  it("cycles, saves, previous and refreshes without a prompt", function()
    api.action.cycle_next().callback(window, "pane")
    assert.same({ "harbor.workspace.cycle", window, "pane", 1 }, calls[#calls])
    api.action.cycle_prev().callback(window, "pane")
    assert.same({ "harbor.workspace.cycle", window, "pane", -1 }, calls[#calls])
    api.action.save().callback(window, "pane")
    assert.same({ "harbor.workspace.save", window, "pane" }, calls[#calls])
    api.action.previous().callback(window, "pane")
    assert.equal("harbor.workspace.previous", calls[#calls][1])
    api.action.quit().callback(window, "pane")
    assert.equal("harbor.workspace.quit", calls[#calls][1])
    assert.has_no.errors(function()
      api.action.refresh().callback(window, "pane")
    end)
  end)

  it("picks tab and window snapshots", function()
    api.action.load_tab().callback(window, "pane")
    assert.same({ tab = true }, calls[#calls][4].kinds)
    assert.equal("Tabs", calls[#calls][4].title)
    api.action.load_window().callback(window, "pane")
    assert.same({ window = true }, calls[#calls][4].kinds)
    assert.equal("Windows", calls[#calls][4].title)
  end)

  it("prompts for a name and runs the operation with it", function()
    local cases = {
      { "fork", "Fork workspace as", "dev-fork", "harbor.workspace.fork" },
      { "restore", "Restore session", nil, "harbor.workspace.restore" },
      { "save_tab", "Save tab as", "tab title", "harbor.workspace.save_snapshot" },
      { "save_window", "Save window as", "win title", "harbor.workspace.save_snapshot" },
      { "new", "New workspace name", nil, "harbor.workspace.create" },
      { "new_at_path", "Open workspace at path", nil, "harbor.workspace.open_dir" },
      { "rename", "Rename workspace", "dev", "harbor.workspace.rename" },
    }
    for _, case in ipairs(cases) do
      local opts = prompt_of(api.action[case[1]]())
      assert.equal(case[2], opts.description, case[1])
      assert.equal(case[3], opts.initial_value, case[1])
      local before = #calls
      opts.action.callback(window, "pane", "typed")
      assert.equal(before + 1, #calls, case[1])
      assert.equal(case[4], calls[#calls][1], case[1])
      -- an empty answer or a cancel does nothing
      opts.action.callback(window, "pane", "")
      opts.action.callback(window, "pane", nil)
      assert.equal(before + 1, #calls, case[1])
    end
  end)

  it("falls back to no initial value when the title cannot be read", function()
    window.active_tab = function()
      error "gone"
    end
    window.mux_window = function()
      error "gone"
    end
    assert.is_nil(prompt_of(api.action.save_tab()).initial_value)
    assert.is_nil(prompt_of(api.action.save_window()).initial_value)
  end)

  it("closes the workspace after a confirmation, or at once when confirm is off", function()
    local util = require "harbor.util"
    local confirm = util.confirm
    local asked
    util.confirm = function(_, _, question, on_yes)
      asked = question
      on_yes(window, "pane")
    end
    api.action.close().callback(window, "pane")
    assert.equal("Close workspace dev?", asked)
    assert.same({ "harbor.workspace.close", window, "pane", "dev" }, calls[#calls])

    require("harbor.config").setup { picker = { confirm = false } }
    asked = nil
    api.action.close().callback(window, "pane")
    assert.is_nil(asked)
    assert.equal("harbor.workspace.close", calls[#calls][1])
    util.confirm = confirm
  end)

  it("logs a failing action instead of raising", function()
    window.active_workspace = function()
      error "boom"
    end
    assert.has_no.errors(function()
      api.action.close().callback(window, "pane")
    end)
  end)
end)
