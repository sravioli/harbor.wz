local env = require "spec.support.env"
local wezterm = require "wezterm"

---Fake GUI window recording performed actions.
local next_id = 0
local function fake_window(id)
  next_id = next_id + 1
  id = id or next_id
  local win = { performed = {} }
  function win:window_id()
    return id
  end
  function win:active_key_table()
    return self.active
  end
  function win:perform_action(action, _)
    self.performed[#self.performed + 1] = action
    if self.fail and action.action == self.fail then
      error("failed " .. self.fail)
    end
    if action.action == "ActivateKeyTable" then
      self.active = action.args.name
    elseif action._action == "PopKeyTable" then
      self.active = nil
    end
  end
  return win
end

local function find_last(performed, name)
  for i = #performed, 1, -1 do
    local a = performed[i]
    if a.action == name or a._action == name then
      return a
    end
  end
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
    picker.set_adapter(nil)
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
    picker.set_adapter(nil)
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
    require("harbor.state").key_table_ready = true
    local win = fake_window()
    picker.open(win, nil)
    local kt = picker.key_table()
    kt[1].action.callback(win, nil)
    local send = find(win.performed, "SendKey")
    assert.is_not_nil(send)
    assert.equal("Enter", send.args.key)
    assert.is_nil(find(win.performed, "PopKeyTable"))
  end)

  it("ignores action keys outside an owned session", function()
    local win = fake_window()
    picker.key_table()[1].action.callback(win, nil)
    assert.equal(0, #win.performed)
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
    -- delete asks first; "No" is the first choice
    local confirm = find_last(win.performed, "InputSelector")
    assert.not_equal(sel, confirm)
    assert.equal("no", confirm.args.choices[1].id)
    assert.equal(0, #calls)
    assert.equal(0, #wezterm._timers)
    confirm.args.action.callback(win, nil, "yes")
    assert.equal("close", calls[#calls].fn)
    assert.equal("a", calls[#calls].args[1])
    -- picker reopens after the action
    assert.equal(1, #wezterm._timers)
  end)

  it("declining or cancelling the delete confirmation closes nothing", function()
    require("harbor.state").key_table_ready = true
    for _, answer in ipairs { "no", false } do
      local win = fake_window()
      picker.dispatch("delete", win, nil, { kind = "saved", name = "s" }, {})
      local confirm = find_last(win.performed, "InputSelector")
      confirm.args.action.callback(win, nil, answer or nil)
    end
    assert.equal(0, #calls)
    assert.equal(2, #wezterm._timers)
  end)

  it("explains what is being deleted in the confirmation", function()
    local win = fake_window()
    picker.dispatch("delete", win, nil, { kind = "saved", name = "s" }, {})
    local args = find_last(win.performed, "InputSelector").args
    assert.matches('Delete saved session "s"%?', args.description)
    assert.equal("harbor: delete saved session", args.title)
    assert.matches("Cancel", args.choices[1].label)
    assert.matches("Delete s", args.choices[2].label)
    assert.matches("cannot be undone", args.choices[2].label)
  end)

  it("reopens with a one-shot reason when deleting a directory", function()
    local win = fake_window()
    win.toast_notification = function()
      error "no toast expected"
    end
    local opts = {}
    picker.dispatch("delete", win, nil, { kind = "dir", path = "/x" }, opts)
    assert.is_nil(find(win.performed, "InputSelector"))
    assert.equal(0, #calls)
    wezterm._run_timers()
    local reopened = find_last(win.performed, "InputSelector").args
    assert.matches("Can't delete /x: it is a directory", reopened.description)
    assert.is_nil(opts.notice)
  end)

  it("shows a notice only on the open that carries it", function()
    local win = fake_window()
    local opts = { notice = "Can't delete /x" }
    picker.open(win, nil, opts)
    assert.matches("Can't delete", find_last(win.performed, "InputSelector").args.description)
    picker.open(win, nil, opts)
    local again = find_last(win.performed, "InputSelector").args
    assert.is_falsy((again.description or ""):find "Can't delete")
  end)

  it("deletes without asking when picker.confirm is false", function()
    require("harbor.config").get().picker.confirm = false
    local win = fake_window()
    picker.dispatch("delete", win, nil, { kind = "workspace", name = "a" }, {})
    assert.is_nil(find(win.performed, "InputSelector"))
    assert.equal("close", calls[#calls].fn)
  end)

  it("shows how long ago a session was saved", function()
    local cfg = require("harbor.config").get().picker
    local now = os.time()
    assert.matches(
      "%[restore, 5m ago%]",
      picker.label({ kind = "saved", name = "s", saved_at = now - 300 }, cfg)
    )
    assert.matches("%[restore%]", picker.label({ kind = "saved", name = "s" }, cfg))
    assert.matches(
      "saved 2h ago",
      picker.label({ kind = "workspace", name = "w", saved = true, saved_at = now - 7200 }, cfg)
    )
  end)

  it("open_entry routes by kind", function()
    picker.open_entry(nil, nil, { kind = "dir", path = "/x" })
    assert.equal("open_dir", calls[#calls].fn)
    picker.open_entry(nil, nil, { kind = "saved", name = "s" })
    assert.equal("restore", calls[#calls].fn)
  end)

  for _, position in ipairs { "top", "status", "none" } do
    for _, hints in ipairs { true, false } do
      it(("separates the short prompt for %s, hints=%s"):format(position, hints), function()
        local cfg = require("harbor.config").get().picker
        cfg.hint_position, cfg.hints = position, hints
        cfg.keys.delete = { key = "Backspace", mods = "ALT|SHIFT" }
        require("harbor.state").key_table_ready = true
        local opened, cleaned = 0, 0
        picker.set_adapter {
          open = function(_, _, session)
            opened = opened + 1
            assert.equal("Backspace", session.bindings[2].key)
            assert.equal("delete", session.bindings[2].desc)
            return function()
              cleaned = cleaned + 1
            end
          end,
        }
        local win = fake_window()
        picker.open(win, nil)
        local args = find(win.performed, "InputSelector").args
        assert.equal("Search: ", args.fuzzy_description)
        assert.is_true(args.fuzzy)
        if hints and position == "top" then
          assert.matches("ALT%+SHIFT%+Backspace delete", args.description)
        else
          assert.is_nil(args.description)
        end
        assert.equal(hints and position == "status" and 1 or 0, opened)
        args.action.callback(win, nil, nil)
        assert.equal(opened, cleaned)
      end)

      it(("preserves explicit descriptions for %s, hints=%s"):format(position, hints), function()
        local cfg = require("harbor.config").get().picker
        cfg.hint_position, cfg.hints = position, hints
        cfg.description = string.rep("User description ", 100)
        local win = fake_window()
        picker.open(win, nil)
        local args = find(win.performed, "InputSelector").args
        assert.equal(cfg.description, args.description)
        assert.equal("Search: ", args.fuzzy_description)
        args.action.callback(win, nil, nil)
      end)
    end
  end

  for _, registered in ipairs { true, false } do
    it("advertises only available keys, registered=" .. tostring(registered), function()
      require("harbor.state").key_table_ready = registered
      local win = fake_window()
      picker.open(win, nil, { actions = false })
      local args = find(win.performed, "InputSelector").args
      assert.equal("Enter open  Escape cancel", args.description)
      assert.is_nil(find(win.performed, "ActivateKeyTable"))
      args.action.callback(win, nil, nil)
      if not registered then
        win = fake_window()
        picker.open(win, nil)
        args = find(win.performed, "InputSelector").args
        assert.equal("Enter open  Escape cancel", args.description)
        args.action.callback(win, nil, nil)
      end
    end)
  end

  it("supports status placement without an adapter or Chord", function()
    require("harbor.config").get().picker.hint_position = "status"
    require("harbor.state").key_table_ready = true
    local win = fake_window()
    picker.open(win, nil)
    local args = find(win.performed, "InputSelector").args
    assert.is_nil(args.description)
    args.action.callback(win, nil, "w:a")
    assert.equal("switch", calls[#calls].fn)
  end)

  it("keeps the picker usable if the registered table was removed by host overrides", function()
    require("harbor.state").key_table_ready = true
    local win = fake_window()
    win.effective_config = function()
      return { key_tables = { unrelated = {} } }
    end
    picker.open(win, nil)
    local args = find(win.performed, "InputSelector").args
    assert.equal("Enter open  Escape cancel", args.description)
    assert.is_nil(find(win.performed, "ActivateKeyTable"))
    args.action.callback(win, nil, "w:a")
    assert.equal("switch", calls[#calls].fn)
  end)

  local function install_adapter()
    local opened, cleaned = {}, {}
    picker.set_adapter {
      keys = { { key = "RightArrow", mods = "ALT", desc = "next hints" } },
      open = function(window, _, session)
        opened[window:window_id()] = session
        return function()
          cleaned[window:window_id()] = (cleaned[window:window_id()] or 0) + 1
        end
      end,
    }
    local cfg = require("harbor.config").get().picker
    cfg.hint_position, cfg.key_table = "status", "custom_picker"
    require("harbor.state").key_table_ready = true
    return opened, cleaned
  end

  it("isolates windows and cleans acceptance, cancellation and reopening once", function()
    local opened, cleaned = install_adapter()
    local a, b = fake_window(), fake_window()
    picker.open(a, nil)
    picker.open(b, nil)
    assert.equal("custom_picker", a.active)
    assert.equal("RightArrow", opened[a:window_id()].bindings[7].key)
    local stale = find(a.performed, "InputSelector").args.action
    picker.open(a, nil)
    assert.equal(1, cleaned[a:window_id()])
    stale.callback(a, nil, "w:a")
    assert.equal(0, #calls)
    local current = a.performed[#a.performed].args.action
    current.callback(a, nil, "w:a")
    current.callback(a, nil, "w:a")
    assert.equal(2, cleaned[a:window_id()])
    assert.is_nil(cleaned[b:window_id()])
    find(b.performed, "InputSelector").args.action.callback(b, nil, nil)
    assert.equal(1, cleaned[b:window_id()])
  end)

  it("does not pop another active table", function()
    local _, cleaned = install_adapter()
    local win = fake_window()
    picker.open(win, nil)
    win.active = "another_mode"
    find(win.performed, "InputSelector").args.action.callback(win, nil, nil)
    assert.is_nil(find(win.performed, "PopKeyTable"))
    assert.equal("another_mode", win.active)
    assert.equal(1, cleaned[win:window_id()])
  end)

  for _, failure in ipairs { "InputSelector", "SendKey", "accept", "dispatch" } do
    it("cleans up after " .. failure .. " errors", function()
      local _, cleaned = install_adapter()
      local win = fake_window()
      if failure == "InputSelector" then
        win.fail = failure
      end
      picker.open(win, nil)
      if failure == "SendKey" then
        win.fail = failure
        picker.key_table()[1].action.callback(win, nil)
      elseif failure == "accept" then
        ws.switch = function()
          error "accept failed"
        end
        find(win.performed, "InputSelector").args.action.callback(win, nil, "w:a")
      elseif failure == "dispatch" then
        ws.close = function()
          error "dispatch failed"
        end
        picker.key_table()[1].action.callback(win, nil)
        find(win.performed, "InputSelector").args.action.callback(win, nil, "w:a")
      end
      assert.equal(1, cleaned[win:window_id()])
      assert.is_nil(win.active)
    end)
  end

  it("releases status hints before action prompts and reacquires on reopen", function()
    local _, cleaned = install_adapter()
    local win = fake_window()
    picker.open(win, nil)
    picker.key_table()[3].action.callback(win, nil)
    find(win.performed, "InputSelector").args.action.callback(win, nil, "w:a")
    assert.equal(1, cleaned[win:window_id()])
    assert.is_nil(win.active)
    find(win.performed, "PromptInputLine").args.action.callback(win, nil, nil)
    wezterm._run_timers()
    assert.equal("custom_picker", win.active)
  end)

  it("replaces adapter registrations instead of accumulating them", function()
    install_adapter()
    local expected = #picker.key_table()
    install_adapter()
    assert.equal(expected, #picker.key_table())
    assert.is_nil(next(wezterm._handlers))
  end)

  it("reuses registered action callbacks when rendering hints and reopening", function()
    require("harbor.state").key_table_ready = true
    local cfg = require("harbor.config").get().picker
    cfg.confirm = false
    cfg.keys.delete = { key = "Backspace", mods = "ALT" }
    local kt = picker.key_table()
    assert.equal("Backspace", kt[1].key)
    local win = fake_window()
    picker.open(win, nil)
    assert.equal(kt, picker.key_table())
    assert.matches("ALT%+Backspace delete", find(win.performed, "InputSelector").args.description)
    kt[1].action.callback(win, nil)
    find(win.performed, "InputSelector").args.action.callback(win, nil, "w:a")
    assert.equal("close", calls[#calls].fn)
    wezterm._run_timers()
    assert.equal(kt, picker.key_table())
  end)

  it("releases a prior session even when fetching new choices fails", function()
    local _, cleaned = install_adapter()
    local win = fake_window()
    picker.open(win, nil)
    sources.list = function()
      error "source failed"
    end
    picker.open(win, nil)
    assert.equal(1, cleaned[win:window_id()])
    assert.is_nil(win.active)
    assert.is_true(#wezterm._calls > 0)
  end)

  it("cleans the owned key table when an adapter cannot open", function()
    install_adapter()
    picker.set_adapter {
      open = function()
        error "adapter failed"
      end,
    }
    local win = fake_window()
    picker.open(win, nil)
    assert.is_nil(win.active)
    assert.is_not_nil(find(win.performed, "PopKeyTable"))
    assert.is_true(#wezterm._calls > 0)
  end)

  it("never installs adapter paging keys when generated status hints are disabled", function()
    install_adapter()
    local cfg = require("harbor.config").get().picker
    for _, position in ipairs { "top", "status", "none" } do
      for _, hints in ipairs { true, false } do
        cfg.hint_position, cfg.hints = position, hints
        local host = { keys = { { key = "RightArrow", desc = "page" } }, open = function() end }
        picker.set_adapter(host)
        local expected = hints and position == "status" and 6 or 5
        assert.equal(expected, #picker.key_table())
      end
    end
  end)
end)
