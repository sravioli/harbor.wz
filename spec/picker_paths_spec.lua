local env = require "spec.support.env"

describe("harbor.picker labels and dispatch", function()
  local picker, workspace, store, util, dir, saved, calls

  local function patch(module, key, value)
    saved[#saved + 1] = { module, key, module[key] }
    module[key] = value
  end

  local function window()
    local w = { performed = {}, toasts = {} }
    function w:window_id()
      return 1
    end
    function w:perform_action(action)
      self.performed[#self.performed + 1] = action
    end
    function w:toast_notification(_, msg)
      self.toasts[#self.toasts + 1] = msg
    end
    return w
  end

  before_each(function()
    dir = env.setup()
    picker = require "harbor.picker"
    workspace = require "harbor.workspace"
    store = require "harbor.session.store"
    util = require "harbor.util"
    saved, calls = {}, {}
    -- Record the operations a dispatch triggers instead of performing them.
    for _, name in ipairs {
      "switch",
      "restore",
      "load_snapshot",
      "open_dir",
      "open_domain",
      "create",
      "close",
      "forget",
      "forget_snapshot",
      "rename",
      "save",
    } do
      patch(workspace, name, function(...)
        calls[#calls + 1] = { name, select(2, ...) }
        return true
      end)
    end
    patch(util, "later", function(_, fn)
      fn()
    end)
    patch(picker, "open", function(_, _, opts)
      calls[#calls + 1] = { "reopen", opts }
    end)
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      saved[i][1][saved[i][2]] = saved[i][3]
    end
    env.rmdir(dir)
  end)

  local cfg = { icons = false, path_width = 40 }

  describe("labels", function()
    it("uses a label an entry brings along", function()
      assert.equal("mine", picker.label({ kind = "dir", label = "mine" }, cfg))
    end)

    it("tags the previous workspace and shows its path", function()
      local text =
        picker.label({ kind = "workspace", name = "dev", previous = true, path = "/srv/dev" }, cfg)
      assert.matches("dev", text)
      assert.matches("previous", text)
      assert.matches("/srv/dev", text)
    end)

    it("labels a domain with its kind, or just domain", function()
      assert.matches(
        "ssh",
        picker.label({ kind = "domain", domain = "SSH:x", domain_kind = "ssh" }, cfg)
      )
      assert.matches("domain", picker.label({ kind = "domain", domain = "SSH:x" }, cfg))
    end)
  end)

  describe("opening an entry", function()
    it("opens a domain through the workspace module", function()
      picker.open_entry(nil, nil, { kind = "domain", domain = "SSH:x" })
      assert.same({ "open_domain", "SSH:x" }, { calls[1][1], calls[1][3] })
    end)
  end)

  describe("dispatch", function()
    ---The callback of the PromptInputLine a dispatch performed.
    local function answer(w, line)
      w.performed[#w.performed].args.action.callback(w, "pane", line)
    end

    it("prompts for a new workspace name and creates it, or reopens when cancelled", function()
      local w = window()
      picker.dispatch("new", w, "pane", nil, { title = "t" })
      assert.equal("New workspace name", w.performed[1].args.description)
      answer(w, "fresh")
      assert.equal("create", calls[1][1])
      answer(w, "")
      assert.equal("reopen", calls[#calls][1])
    end)

    it("prompts for a path, starting from the selected entry's", function()
      local w = window()
      picker.dispatch("new_at_path", w, "pane", { path = "/srv/app" }, {})
      assert.matches("app", w.performed[1].args.initial_value)
      answer(w, "/srv/other")
      assert.equal("open_dir", calls[1][1])
      answer(w, nil)
      assert.equal("reopen", calls[#calls][1])

      w = window()
      picker.dispatch("new_at_path", w, "pane", nil, {})
      assert.is_nil(w.performed[1].args.initial_value)
    end)

    it("reopens when there is no entry to act on", function()
      picker.dispatch("delete", window(), "pane", nil, {})
      assert.equal("reopen", calls[1][1])
    end)

    it("asks before deleting a workspace, a saved session or a snapshot", function()
      local asked = {}
      patch(util, "confirm", function(_, _, spec, on_yes, on_no)
        asked[#asked + 1] = spec
        if #asked % 2 == 1 then
          on_yes(nil, nil)
        else
          on_no(nil, nil)
        end
      end)
      local w = window()
      picker.dispatch("delete", w, "pane", { kind = "workspace", name = "dev", saved = true }, {})
      picker.dispatch("delete", w, "pane", { kind = "saved", name = "old" }, {})
      picker.dispatch("delete", w, "pane", { kind = "tab", name = "t1" }, {})
      assert.matches("saved session is kept", asked[1].yes_hint)
      assert.matches("delete saved session", asked[2].title)
      assert.matches("Delete tab snapshot", asked[3].question)
      local ran = {}
      for _, c in ipairs(calls) do
        ran[#ran + 1] = c[1]
      end
      -- yes closes and reopens; no (the second) only reopens; the third is yes again
      assert.same({ "close", "reopen", "reopen", "forget_snapshot", "reopen" }, ran)
    end)

    it("deletes without asking when confirm is off", function()
      require("harbor.config").setup { sessions = { dir = dir }, picker = { confirm = false } }
      picker.dispatch("delete", window(), "pane", { kind = "workspace", name = "dev" }, {})
      assert.same({ "close", "reopen" }, { calls[1][1], calls[2][1] })
    end)

    it("explains why a directory or domain cannot be deleted", function()
      picker.dispatch(
        "delete",
        window(),
        "pane",
        { kind = "dir", path = "/srv/app" },
        { title = "t" }
      )
      local opts = calls[1][2]
      assert.matches("Can't delete", opts.notice)
      assert.matches("a directory", opts.notice)
      assert.equal("t", opts.title)

      picker.dispatch("delete", window(), "pane", { kind = "domain", domain = "SSH:x" }, nil)
      assert.matches("a domain", calls[2][2].notice)
    end)

    it("renames a workspace through the workspace module", function()
      local w = window()
      picker.dispatch("rename", w, "pane", { kind = "workspace", name = "dev" }, {})
      assert.equal("Rename dev", w.performed[1].args.description)
      answer(w, "prod")
      assert.same({ "rename", "dev", "prod" }, { calls[1][1], calls[1][3], calls[1][4] })
    end)

    it("renames a saved session or snapshot through the store, reporting a failure", function()
      local renamed
      patch(store, "rename", function(old, new, kind)
        renamed = { old, new, kind }
        return false, "exists"
      end)
      local w = window()
      picker.dispatch("rename", w, "pane", { kind = "tab", name = "t1" }, {})
      answer(w, "t2")
      assert.same({ "t1", "t2", "tab" }, renamed)
      assert.same({ "Rename failed: exists" }, w.toasts)

      patch(store, "rename", function(_, _, kind)
        renamed = { kind = kind }
        return true
      end)
      w = window()
      local dropped = {}
      patch(require "harbor.state", "invalidate", function(key)
        dropped[#dropped + 1] = key
      end)
      picker.dispatch("rename", w, "pane", { kind = "saved", name = "s" }, {})
      answer(w, "s2")
      assert.is_nil(renamed.kind)
      -- The save marker must not show the old name for 30 s.
      assert.same({ "session:s", "session:s2" }, dropped)
    end)

    it("does not rename a directory", function()
      picker.dispatch("rename", window(), "pane", { kind = "dir", path = "/x" }, {})
      assert.equal("reopen", calls[1][1])
    end)

    it("saves a workspace and reopens, or opens any other entry", function()
      picker.dispatch("save", window(), "pane", { kind = "workspace", name = "dev" }, {})
      assert.same({ "save", "reopen" }, { calls[1][1], calls[2][1] })
      picker.dispatch("save", window(), "pane", { kind = "saved", name = "s" }, {})
      assert.equal("reopen", calls[3][1])
      picker.dispatch("anything", window(), "pane", { kind = "workspace", name = "dev" }, {})
      assert.equal("switch", calls[4][1])
    end)
  end)
end)
