# harbor.wz

Workspace and session manager for [WezTerm](https://wezfurlong.org/wezterm/).

One fuzzy picker for live workspaces, saved sessions, zoxide directories, git
projects, pinned directories and SSH/WSL/unix domains. Workspaces can be saved
to disk (tabs, splits, cwd, scrollback, running editors) and restored later,
by hand, on a timer, or at startup.

harbor is built on [warp.wz](https://github.com/sravioli/warp.wz),
[memo.wz](https://github.com/sravioli/memo.wz),
[log.wz](https://github.com/sravioli/log.wz),
[warden.wz](https://github.com/sravioli/warden.wz) and, when available,
[sigil.wz](https://github.com/sravioli/sigil.wz) for icons.

## Installation

```lua
local wezterm = require "wezterm"
local config = wezterm.config_builder()

local harbor = wezterm.plugin.require "https://github.com/sravioli/harbor.wz"

harbor.setup {
  sources = { projects = { roots = { "~/dev", { path = "~/work", max_depth = 2 } } } },
}
harbor.apply_to_config(config)

config.keys = {
  { key = "s", mods = "LEADER", action = harbor.action.pick() },
  { key = "w", mods = "LEADER", action = harbor.action.workspaces() },
  { key = "Tab", mods = "LEADER", action = harbor.action.previous() },
  { key = "S", mods = "LEADER|SHIFT", action = harbor.action.save() },
}

return config
```

`apply_to_config` registers the key table used for in-picker actions. It does
not bind any keys. Without it the picker still works, minus the action keys.

## Picker

Each line is one of:

- **workspace**: a live workspace (`current`, `previous`, `saved` tags)
- **saved**: a session on disk with no live workspace
- **dir**: a directory from zoxide, project discovery or `sources.dirs`
- **domain**: an SSH, WSL, unix or TLS domain

Enter switches to, restores or creates the workspace. Opening a directory
creates a workspace named after it (see `naming`) and adds it to zoxide.

Keys while the picker is open:

| Key      | Action                                          |
| -------- | ----------------------------------------------- |
| `Enter`  | open                                            |
| `CTRL-d` | close workspace / delete saved session          |
| `CTRL-r` | rename workspace or saved session               |
| `CTRL-a` | new workspace (prompted name)                   |
| `CTRL-o` | new workspace at path (prefilled from selection)|
| `CTRL-s` | save workspace                                  |
| `Esc`    | cancel                                          |

`CTRL-n`/`CTRL-p`/`CTRL-j`/`CTRL-k` keep their InputSelector meaning
(navigation), so harbor avoids them. Change any of these under `picker.keys`.

### Search and hint placement

The fuzzy input always uses the short, single-line `Search: ` prompt. Native
InputSelector draws it at column zero and truncates it to the window width;
action hints and explicit descriptions are never prepended to the input.
Choice labels, fuzzy matching and action keys are independent of hint placement.

```lua
harbor.setup {
  picker = {
    hints = true, -- master switch for generated hints
    hint_position = "top", -- "top" (default), "status", or "none"
    description = "Choose a workspace", -- optional explicit selector description
  },
}
```

`top` uses the selector description for generated hints unless an explicit
description was supplied. Native InputSelector replaces that row with its
search prompt while filtering; it does not support a separate multiline
description above fuzzy input. `status` omits generated top hints and lets an
installed adapter show them in a **visible status bar**. `none`, or
`hints = false`, suppresses generated hints in both locations without removing
explicit descriptions. Invalid placements are logged and fall back to `top`.
No adapter means no status hints: Harbor neither enables the bar nor changes
its layout or falls back to top hints.

### Optional Chord status adapter

Harbor does not load or require Chord. Hosts can install this adapter using
Chord's generic temporary-table API (requires a version providing
`chord.temporary`):

```lua
harbor.setup { picker = { hint_position = "status", key_table = "my_picker" } }
harbor.set_picker_adapter {
  keys = chord.table {
    { "<C-S-A-Left>", chord.hint_action(nil, -1), "previous hints" },
    { "<C-S-A-Right>", chord.hint_action(nil, 1), "next hints" },
  },
  open = function(window, pane, session)
    return chord.temporary.begin(window, pane, {
      name = session.key_table,
      keys = session.bindings,
      meta = function(theme)
        return { i = "H", txt = "HARBOR", bg = theme.ansi[5] }
      end,
    })
  end,
}
harbor.apply_to_config(config)
```

The host's status renderer must read `chord.temporary.get(window, theme)`
before ordinary mode metadata, pass its `name` to `chord.hint_layout()` with
the **remaining column budget**, and refresh on `chord-temporary-changed`
and `chord-hint-page-changed`. The main configuration demonstrates this in
`opts/statusbar.lua` and `events/update-status.lua`. Keep its existing
status-bar enablement check.

`set_picker_adapter(adapter)` replaces the previous adapter; call it before
`apply_to_config()` on each reload. `set_picker_adapter(nil)` removes it.
The adapter's optional native `keys` extend the registered picker table only
for enabled status hints. `open(window, pane, session)` receives the configured
`key_table` and `bindings` (native entries with `desc`, including Enter/cancel).
These come from the same definitions as the action key table, so changing
`picker.keys` updates both behavior and hints. Disabled actions or missing
`apply_to_config()` never advertise unavailable action keys.

Return an idempotent cleanup function from `open`; it runs before acceptance,
cancellation, dispatch or another picker, and after opening/action errors.
An adapter that throws before returning must release any resources it acquired.
Callbacks should not stack unrelated key tables over a picker: Harbor only
pops its own table when it is on top, never an unrelated table. Chord stores
temporary hints per window and ignores stale releases after reopening.

## Actions

All `harbor.action.*` return key assignments. Errors are logged, never raised.

| Action          | Does                                        |
| --------------- | ------------------------------------------- |
| `pick(opts?)`   | picker; `opts.kinds`, `opts.title`          |
| `workspaces()`  | picker over live workspaces                 |
| `projects()`    | picker over directories                     |
| `sessions()`    | picker over saved and live workspaces       |
| `domains()`     | picker over domains                         |
| `previous()`    | jump to the previously active workspace     |
| `save()`        | save the active workspace                   |
| `restore()`     | restore a session by name (prompt)          |
| `new()`         | create a workspace (prompt)                 |
| `new_at_path()` | create a workspace at a path (prompt)       |
| `rename()`      | rename the active workspace (prompt)        |
| `close()`       | close every pane of the active workspace    |
| `refresh()`     | drop cached source results                  |

The same operations exist as plain functions taking `(window, pane, ...)`:
`pick`, `list`, `switch`, `open_dir`, `create`, `rename`, `close`, `previous`,
`save`, `restore`, `delete_session`, `sessions`, `refresh`.

## Events

Emitted with `(window, pane, payload)`:

- `harbor.workspace.switched` `{ name, from }`
- `harbor.workspace.created` `{ name, path }`
- `harbor.workspace.renamed` `{ from, to, merged }`
- `harbor.workspace.closed` `{ name, panes }`
- `harbor.session.saved` `{ name }`
- `harbor.session.restored` `{ name }`
- `harbor.session.deleted` `{ name }`

## Configuration

Every option is validated with warden. A bad value is logged and replaced by
its default; the rest of your options still apply and the config never fails
to load because of harbor.

```lua
harbor.setup {
  default_workspace = "default",

  naming = {
    style = "basename", -- "basename" | "tilde" | "path"
    replace_dots = false,
    max_length = 64,
    fn = nil, -- function(path) -> name
  },

  sources = {
    order = { "workspaces", "saved", "zoxide", "projects", "dirs", "domains" },
    cache_ttl = 30, -- seconds
    zoxide = { enabled = true, path = nil, min_score = 0, limit = 300, add_on_open = true },
    projects = {
      enabled = true,
      roots = {}, -- "~/dev" or { path = "~/dev", max_depth = 2 }
      max_depth = 4,
      exclude = { "node_modules", ".cache", ".venv", "venv", "target", "vendor", "dist", "build" },
      fd_path = nil,
      include_roots = false,
    },
    dirs = { enabled = true, paths = {} },
    domains = {
      enabled = true,
      kinds = { "ssh", "sshmux", "wsl", "unix", "tls", "other" },
      ignore = {},
      ignore_patterns = {},
      action = "workspace", -- or "tab"
    },
    custom = {}, -- functions returning entries, see below
  },

  picker = {
    title = "Harbor",
    fuzzy = true,
    description = nil, -- default: key hints
    show_current = true,
    icons = true,
    sort = "mru", -- "mru" | "alpha" | "none"
    path_width = 60,
    hints = true,
    hint_position = "top", -- "top" | "status" | "none"
    filter = nil, -- function(entry) -> boolean
    format = nil, -- function(entry, label) -> string
    key_table = "harbor_picker",
    keys = {
      delete = { key = "d", mods = "CTRL" },
      rename = { key = "r", mods = "CTRL" },
      new = { key = "a", mods = "CTRL" },
      new_at_path = { key = "o", mods = "CTRL" },
      save = { key = "s", mods = "CTRL" },
    },
  },

  layouts = {
    dir = nil, -- directory with <name>.lua layout files
    default = nil, -- layout name or table
    rules = {}, -- { match = "pattern" | function(root, name), layout = ... }
    project_file = ".harbor.lua",
    trust_project_files = false,
  },

  sessions = {
    dir = nil, -- see "Where files go"
    backup = true,
    max_file_bytes = 32 * 1024 * 1024,
    scrollback = { enabled = true, max_lines = 3500, max_pane_bytes = 512 * 1024, remote = false },
    processes = { enabled = true, allow = {}, mode = "extend", delay = 0.3 },
    autosave = { enabled = false, interval = 300, on_focus_lost = false, scope = "all", exclude = {} },
    restore_on_startup = false, -- true = last workspace, or a session name
  },
}
```

### Project discovery

Projects are git repositories under `sources.projects.roots`. harbor uses `fd`
when it is on `PATH` (or `fd_path` is set) and falls back to walking the tree
with `wezterm.read_dir`. Results are cached for `cache_ttl` seconds.

### Custom sources

A custom source is a function returning a list. Items can be a path string,
`{ path = ..., label? }` for a directory, or `{ workspace = ..., path?, label? }`
for a workspace.

```lua
sources = {
  custom = {
    function()
      return { "~/notes", { workspace = "scratch" } }
    end,
  },
}
```

### Layouts

A layout runs when harbor creates a workspace from a directory. It is a table
or a function `fn(ctx)` with `ctx = { name, root, domain, window, tab, pane }`.

```lua
layouts = {
  rules = {
    {
      match = "/web/",
      layout = {
        tabs = {
          { title = "edit", cmd = "nvim ." },
          {
            title = "run",
            splits = { { direction = "Right", size = 0.4, cmd = "npm run dev" } },
          },
        },
      },
    },
  },
}
```

Tab and split fields: `cwd` (relative to the workspace root), `cmd` (typed
into the shell), `args` (replaces the shell; `cmd` is then ignored), `env`.
Splits also take `direction` (`Right`, `Left`, `Bottom`, `Top`) and `size`.

Project layout files (`.harbor.lua` in the repository) execute Lua from that
directory, so they are off unless you set `trust_project_files = true`.

## Sessions

`save` writes the workspace to `<dir>/sessions/<name>.json`: windows, tabs,
split tree with sizes, cwd per pane, domain, titles, zoom, and optionally
scrollback and the foreground program.

On restore harbor rebuilds the layout and relaunches a foreground program only
if its name is on the allowlist (editors, pagers, `htop`, `lazygit`, file
managers and similar). Add names with `processes.allow`, or set
`mode = "replace"` to use only your list. The saved command line is quoted for
the pane's shell and typed in after `processes.delay` seconds.

Scrollback is stripped of every escape sequence except colours before it is
written, so replaying a session cannot run terminal control sequences. Remote
pane scrollback is skipped unless `scrollback.remote = true`.

Writes are atomic and keep a `.bak` of the previous file. A corrupt or
oversized file is reported and skipped.

### Autosave

With `autosave.enabled`, harbor saves every `interval` seconds and,
optionally, when a window loses focus. A workspace whose layout and
directories have not changed is skipped. Scrollback-only changes do not count
as a change.

### Where files go

- Windows: `%LOCALAPPDATA%\wezterm\harbor`
- macOS: `~/Library/Application Support/wezterm/harbor`
- Linux: `$XDG_STATE_HOME/wezterm/harbor`, else `~/.local/state/wezterm/harbor`

Override with `sessions.dir`.

## Safety

- No shell, no `io.popen`. External programs (`zoxide`, `fd`) run through
  `wezterm.run_child_process` with argument lists.
- Nothing runs at require or setup time; work starts when an action fires.
- Every callback is wrapped; failures are logged through log.wz.

## Credits

Ideas taken from
[smart_workspace_switcher](https://github.com/MLFlexer/smart_workspace_switcher.wezterm),
[workspace-manager](https://github.com/ryanmsnyder/workspace-manager.wezterm),
[workspace-picker](https://github.com/isseii10/workspace-picker.wezterm),
[sessionizer](https://github.com/mikkasendke/sessionizer.wezterm),
[workspacesionizer](https://github.com/vieitesss/workspacesionizer.wezterm),
[quick_domains](https://github.com/DavidRR-F/quick_domains.wezterm),
[wsinit](https://github.com/JuanraCM/wsinit.wezterm),
[resurrect](https://github.com/StephenGemin/resurrect.wezterm),
[wezterm-sessions](https://github.com/abidibo/wezterm-sessions) and
[tabsets](https://github.com/srackham/tabsets.wezterm).

## License

Code under [GPL-2.0](../LICENSE), documentation under [LICENSE-DOCS](../LICENSE-DOCS).
