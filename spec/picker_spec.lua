local env = require "spec.support.env"
local wezterm = require "wezterm"

---Fake GUI window recording performed actions.
local function fake_window(id)
  local win = { performed = {} }
  function win:window_id()
    return id or 1
  end
  function win:perform_action(action, _)
    self.performed[#self.performed + 1] = action
  end
  return win
end

local function find(performed, name)
  for _, a in ipairs(performed) do
    -- called actions are `{action=...}`, bare ones (PopKeyTable) `{_action=...}`
    if a.action == name or a._action == name then
      return a
    end
  end
end

describe("harbor.picker", function()
  local picker, ws, sources
  local orig = {}
  local calls

  before_each(function()
    env.setup()
    picker = require "harbor.picker"
    ws = require "harbor.workspace"
    sources = require "harbor.sources"
    calls = {}
    for _, fn in ipairs { "switch", "restore", "open_dir", "close", "save", "create", "active" } do
      orig[fn] = ws[fn]
      ws[fn] = function(_, _, ...)
        if fn == "active" then
          return "default"
        end
        calls[#calls + 1] = { fn = fn, args = { ... } }
        return "default"
      end
    end
    orig.list = sources.list
    sources.list = function()
      return {
        { id = "w:a", kind = "workspace", name = "a" },
        { id = "d:/x", kind = "dir", path = "/x" },
      }
    end
  end)

  after_each(function()
    for k, v in pairs(orig) do
      if k == "list" then
        sources.list = v
      else
        ws[k] = v
      end
    end
  end)

  it("builds hints from the key config", function()
    local h = picker.hints(require("harbor.config").get().picker)
    assert.matches("CTRL%+d delete", h)
    assert.matches("CTRL%+o new at path", h)
  end)

  it("key table has only action keys, no Enter/Escape", function()
    local kt = picker.key_table()
    assert.equal(#picker.ACTIONS, #kt)
    for _, e in ipairs(kt) do
      assert.not_equal("Enter", e.key)
      assert.not_equal("Escape", e.key)
    end
  end)

  it("action key records pending action and sends Enter", function()
    local win = fake_window()
    local kt = picker.key_table()
    kt[1].action.callback(win, nil)
    local send = find(win.performed, "SendKey")
    assert.is_not_nil(send)
    assert.equal("Enter", send.args.key)
    assert.is_nil(find(win.performed, "PopKeyTable"))
  end)

  it("opens the selector without key table until registered", function()
    local win = fake_window()
    picker.open(win, nil)
    assert.is_not_nil(find(win.performed, "InputSelector"))
    assert.is_nil(find(win.performed, "ActivateKeyTable"))
  end)

  it("enter opens the entry and pops the table once", function()
    require("harbor.state").key_table_ready = true
    local win = fake_window()
    picker.open(win, nil)
    assert.is_not_nil(find(win.performed, "ActivateKeyTable"))
    local sel = find(win.performed, "InputSelector")
    sel.args.action.callback(win, nil, "w:a")
    local pops = 0
    for _, a in ipairs(win.performed) do
      if a._action == "PopKeyTable" then
        pops = pops + 1
      end
    end
    assert.equal(1, pops)
    assert.equal("switch", calls[#calls].fn)
    assert.equal("a", calls[#calls].args[1])
  end)

  it("cancel pops and does nothing else", function()
    require("harbor.state").key_table_ready = true
    local win = fake_window()
    picker.open(win, nil)
    find(win.performed, "InputSelector").args.action.callback(win, nil, nil)
    assert.is_not_nil(find(win.performed, "PopKeyTable"))
    assert.equal(0, #calls)
  end)

  it("pending action is dispatched on accept", function()
    require("harbor.state").key_table_ready = true
    local win = fake_window()
    picker.open(win, nil)
    local sel = find(win.performed, "InputSelector")
    -- user presses the delete key while "w:a" is highlighted
    for _, e in ipairs(picker.key_table()) do
      if e.key == "d" then
        e.action.callback(win, nil)
      end
    end
    sel.args.action.callback(win, nil, "w:a")
    assert.equal("close", calls[#calls].fn)
    assert.equal("a", calls[#calls].args[1])
    -- picker reopens after the action
    assert.equal(1, #wezterm._timers)
  end)

  it("open_entry routes by kind", function()
    picker.open_entry(nil, nil, { kind = "dir", path = "/x" })
    assert.equal("open_dir", calls[#calls].fn)
    picker.open_entry(nil, nil, { kind = "saved", name = "s" })
    assert.equal("restore", calls[#calls].fn)
  end)
end)
