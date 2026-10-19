local M = {}

function M.new()
  local fixture = { windows = {}, next_id = 0, fail = {}, calls = {} }
  local function check(kind)
    fixture.calls[#fixture.calls + 1] = kind
    if fixture.fail[kind] then
      error("injected " .. kind)
    end
  end
  local function pane()
    fixture.next_id = fixture.next_id + 1
    local p = { id = fixture.next_id, sent = {}, output = {} }
    function p:pane_id()
      return self.id
    end
    function p:activate()
      check "pane.activate"
      fixture.active_pane = self
    end
    function p:inject_output(text)
      check "inject"
      self.output[#self.output + 1] = text
    end
    function p:send_text(text)
      check "send"
      self.sent[#self.sent + 1] = text
    end
    function p:get_foreground_process_info()
      return { executable = "pwsh.exe" }
    end
    function p:split(args)
      check "split"
      local next_pane = pane()
      next_pane.spawn = args
      self.children = self.children or {}
      self.children[#self.children + 1] = next_pane
      return next_pane
    end
    return p
  end
  local function tab(args)
    local p = pane()
    p.spawn = args
    local t = { first = p }
    function t:set_title(title)
      check "tab.title"
      self.title = title
    end
    function t:activate()
      check "tab.activate"
      fixture.active_tab = self
    end
    function t:set_zoomed(value)
      check "zoom"
      self.zoomed = value
    end
    function t:panes()
      local out = {}
      local function walk(current)
        out[#out + 1] = current
        for _, child in ipairs(current.children or {}) do
          walk(child)
        end
      end
      walk(p)
      return out
    end
    return t, p
  end
  function fixture.spawn(args)
    check "window"
    local t, p = tab(args)
    local w = { workspace = args.workspace, items = { t } }
    function w:get_workspace()
      return self.workspace
    end
    function w:set_workspace(name)
      check "merge"
      self.workspace = name
    end
    function w:tabs()
      check "tabs"
      return self.items
    end
    function w:set_title(title)
      check "window.title"
      self.title = title
    end
    function w:spawn_tab(opts)
      check "tab"
      local next_tab, next_pane = tab(opts)
      self.items[#self.items + 1] = next_tab
      return next_tab, next_pane
    end
    fixture.windows[#fixture.windows + 1] = w
    return t, p, w
  end
  return fixture
end

return M
