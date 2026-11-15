# harbor.wz

[![Code license](https://img.shields.io/badge/code-GPL--2.0-blue?style=flat-square)](../LICENSE)
[![Docs license](https://img.shields.io/badge/docs-CC_BY--NC_4.0-blue?style=flat-square)](../LICENSE-DOCS)

Manage workspaces and saved sessions in [WezTerm](https://wezterm.org/).

Find workspaces, saved layouts, directories, and domains in one picker.
Save windows, tabs, splits, and working directories, then rebuild them with
optional scrollback and allowlisted foreground-command replay.

[Quick start](#quick-start) · [Usage](#usage) · [Configuration](#configuration) · [API reference](#api-reference) · [Troubleshooting](#troubleshooting) · [Development](#development) · [License](#license)

## Quick start

### Requirements

Requires **[WezTerm nightly including the prompt-prefill fix (2024-09-22) or newer](https://github.com/wezterm/wezterm/commit/67603e73e05cc6c3818a6b474b923f0e9e6ce971)**
and Git. Stable builds lack required prompt and JSON APIs.
Configure remote domains beforehand; WSL domains need Windows/WSL.

Automatically loads [warp.wz](https://github.com/sravioli/warp.wz),
[memo.wz](https://github.com/sravioli/memo.wz),
[log.wz](https://github.com/sravioli/log.wz), and
[warden.wz](https://github.com/sravioli/warden.wz); missing dependencies raise.
Optional [sigil.wz](https://github.com/sravioli/sigil.wz) and
[ribbon.wz](https://github.com/sravioli/ribbon.wz) provide labels with built-in
fallbacks. Local API modules take precedence.

**zoxide** supplies optional directory history; **fd/fdfind** accelerates
project discovery, with a Lua-walk fallback. Closing workspaces needs WezTerm's
CLI. Icons have text fallbacks.

### Install and run

Remote installation at `sravioli/harbor.wz` awaits publication.
Until then use [Local checkout](#local-checkout).

Put this in `wezterm.lua`:

```lua
local wezterm = require "wezterm"
local harbor = wezterm.plugin.require "https://github.com/sravioli/harbor.wz"
local config = wezterm.config_builder()

harbor.apply_to_config(config)
config.keys = {
  { key = "h", mods = "CTRL|SHIFT", action = harbor.action.pick() },
}

return config
```

Press **Ctrl+Shift+H**, type to filter, and press Enter to open an entry.
Esc cancels. `apply_to_config` initializes defaults and registers the action
table, but does not bind keys. Reuse your existing config builder and append
the binding before returning.

## Usage

### Open and organize workspaces

Press Enter to switch to a live workspace, restore a session that is not
running, or open a directory or domain. Directory entries come from zoxide,
project discovery, pinned paths, and custom sources.

| Picker key | Action |
| --- | --- |
| `Ctrl+D` | Ask, then close the selected live workspace, or delete a saved-only session and its backup. |
| `Ctrl+R` | Prompt to rename a workspace/session; an existing live destination merges workspaces. |
| `Ctrl+A` | Prompt for a new workspace name. |
| `Ctrl+O` | Prompt for a directory, prefilled from the selection when available. |
| `Ctrl+S` | Save the selected live workspace. |

Ctrl+D and `harbor.action.close()` ask first; "No" is preselected and Esc
cancels. Set `picker.confirm = false` to skip the question. Closing saves the
workspace first and aborts if that save fails (`sessions.save_on_close`), so a
closed workspace stays restorable; a workspace protected after a partial
restore is closed without overwriting its snapshot. Closing a workspace targets
all its panes, and Harbor refuses to close the only workspace. A failed mux or saved-file operation can leave a rename or merge
partly complete; check diagnostics before retrying. InputSelector keeps its
Ctrl+N/P/J/K navigation and cancel keys.

### Save and resume a session

Bind `harbor.action.save()` to capture the active workspace and
`harbor.action.restore()` to prompt for a saved name. Restoring an already-live
name switches to it rather than overwriting it. Saved entries show how long ago
they were saved.

WezTerm has no event before it quits. To save on exit, bind
`harbor.action.quit()` where you quit: it saves every live workspace, then quits,
and refuses to quit when a save fails. Closing windows through the window
manager, or closing the last pane, bypasses it; enable autosave for those cases.

Sessions preserve windows and tabs, splits, directories, domains, tab and window
titles, focus, and zoom. Scrollback captures sanitized text and SGR colors,
but skips the alternate screen. Harbor replays only allowlisted local foreground
command arguments. It does not restore process memory, unsaved buffers, or
complete shell state.

Restore only session files you trust. An allowlisted program can execute commands
through its arguments or configuration. The allowlist is not a sandbox;
disable replay if that is unsuitable for your setup.

### Add project directories and a layout

Before `apply_to_config`, configure discovery and a simple two-tab layout:

```lua
harbor.setup {
  sources = {
    projects = { roots = { "~/dev" } },
    dirs = { paths = { wezterm.home_dir } },
  },
  layouts = {
    default = { tabs = { { title = "edit" }, { title = "run" } } },
  },
}
```

For a new workspace, tabs accept `cwd` (root-relative), `args`, `env`, `cmd`,
`active`, and `splits`. Splits add `direction` (`Right`, `Left`, `Bottom`, `Top`), `size`
(`0.05..0.95`), and nested splits. `args` replaces the shell and suppresses `cmd`;
otherwise Harbor types the trusted `cmd` text into the shell.
See the [layout schema](../plugin/harbor/layout.lua).

Harbor calls custom sources without arguments. They return path strings,
`{ path, label? }`, or `{ workspace, path?, label? }` records. Layout functions receive
`{ name, root, domain, window, tab, pane }`; rule predicates receive `(root, name)`.

## Configuration

### Example

Setup is optional and replaces the current settings. Call it before
`apply_to_config`, and register any adapter between those calls.
The values below are overrides, not defaults:

```lua
harbor.setup {
  picker = { icons = false },
  sessions = {
    processes = { enabled = false },
    autosave = { enabled = true, interval = 120 },
  },
}
```

### Options

#### Naming and sources

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `default_workspace` | `string` | `"default"` | Fallback active name when the mux cannot report it; non-empty. |
| `naming.style` | `"basename"\|"tilde"\|"path"` | `"basename"` | Derive directory workspace names. |
| `naming.replace_dots` | `boolean` | `false` | Replace dots with underscores in derived names. |
| `naming.max_length` | `integer` | `64` | Base-name display-column limit, `8..256`; collision suffixes can extend it. |
| `naming.fn` | `fun(path: string): string` | `nil` | Custom non-empty name wins before built-in replacement/truncation; errors log and fall back. |
| `sources.order` | `string[]` | `{ "workspaces", "saved", "zoxide", "projects", "dirs", "domains" }` | Built-in collection order; custom sources run afterward. |
| `sources.cache_ttl` | `number` | `30` | Project/zoxide cache seconds, minimum `0`; `0` bypasses caching. |
| `sources.workspaces.enabled` | `boolean` | `true` | Include live workspaces. |
| `sources.saved.enabled` | `boolean` | `true` | Include sessions on disk. |
| `sources.zoxide.enabled` | `boolean` | `true` | Query zoxide if installed. |
| `sources.zoxide.path` | `string?` | `nil` | Explicit executable name/path. |
| `sources.zoxide.min_score` | `number` | `0` | Minimum returned score. |
| `sources.zoxide.limit` | `integer` | `300` | Non-negative result cap; `0` is unlimited. |
| `sources.zoxide.add_on_open` | `boolean` | `true` | Best-effort `zoxide add` when opening a directory. |
| `sources.projects.enabled` | `boolean` | `true` | Discover Git roots. |
| `sources.projects.roots` | `(string\|table)[]` | `{}` | Paths or `{ path, max_depth? }`; `~/dev` is an example, not a default. |
| `sources.projects.max_depth` | `integer` | `4` | Directory depth, `1..16`; per-root depth overrides it. |
| `sources.projects.exclude` | `string[]` | `{ "node_modules", ".cache", ".venv", "venv", "target", "vendor", "dist", "build" }` | Excluded directory names/patterns for discovery. |
| `sources.projects.fd_path` | `string?` | `nil` | Explicit fd path; otherwise try fd/fdfind before walking. |
| `sources.projects.include_roots` | `boolean` | `false` | Include configured roots even when not Git projects. |
| `sources.dirs.enabled` | `boolean` | `true` | Include pinned directories. |
| `sources.dirs.paths` | `string[]` | `{}` | Non-empty directory paths; leading `~` expands. |
| `sources.domains.enabled` | `boolean` | `true` | Include configured spawnable mux domains. |
| `sources.domains.kinds` | `string[]` | `{ "ssh", "sshmux", "wsl", "unix", "tls", "other" }` | Allowed categories; `"local"` is accepted but omitted by default. |
| `sources.domains.ignore` | `string[]` | `{}` | Exact names to exclude. |
| `sources.domains.ignore_patterns` | `string[]` | `{}` | Lua patterns to exclude, not regexes. |
| `sources.domains.action` | `"workspace"\|"tab"` | `"workspace"` | Open a domain as its own workspace or a new tab. |
| `sources.custom` | `function[]` | `{}` | Additional source callbacks; see [Usage](#add-project-directories-and-a-layout). |

#### Picker

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `picker.title` | `string` | `"Harbor"` | Selector title. |
| `picker.fuzzy` | `boolean` | `true` | Initial fuzzy mode; fuzzy prompt remains `"Search: "`. |
| `picker.description` | `string?` | `nil` | Explicit exact-mode description; otherwise generated top hints when enabled. |
| `picker.show_current` | `boolean` | `true` | Show the active workspace. |
| `picker.icons` | `boolean` | `true` | Add glyphs/text fallback markers. |
| `picker.sort` | `"mru"\|"alpha"\|"none"` | `"mru"` | Group by kind, then sort; `"none"` keeps collection order. |
| `picker.path_width` | `integer` | `60` | Path display target, `10..200` columns; Warp shortening is best-effort. |
| `picker.hints` | `boolean` | `true` | Master generated-hint switch, not an action-key switch. |
| `picker.hint_position` | `"top"\|"status"\|"none"` | `"top"` | Exact description, host status adapter, or no generated hints. |
| `picker.confirm` | `boolean` | `true` | Ask before closing a workspace or deleting a saved session from the picker or `action.close()`. |
| `picker.filter` | `fun(entry: harbor.Entry): boolean` | `nil` | Only explicit `false` removes an entry; errors log and retain it. |
| `picker.format` | `fun(entry: harbor.Entry, label: string): string` | `nil` | Customize a rendered label; errors/non-strings keep the original. |
| `picker.key_table` | `string` | `"harbor_picker"` | Non-empty native action-table name. |
| `picker.keys.delete.key` | `string` | `"d"` | Close/delete action key. |
| `picker.keys.delete.mods` | `string` | `"CTRL"` | Close/delete modifiers. |
| `picker.keys.rename.key` | `string` | `"r"` | Rename action key. |
| `picker.keys.rename.mods` | `string` | `"CTRL"` | Rename modifiers. |
| `picker.keys.new.key` | `string` | `"a"` | New-workspace action key. |
| `picker.keys.new.mods` | `string` | `"CTRL"` | New-workspace modifiers. |
| `picker.keys.new_at_path.key` | `string` | `"o"` | Open-directory action key. |
| `picker.keys.new_at_path.mods` | `string` | `"CTRL"` | Open-directory modifiers. |
| `picker.keys.save.key` | `string` | `"s"` | Save action key. |
| `picker.keys.save.mods` | `string` | `"CTRL"` | Save modifiers. |

#### Layouts and sessions

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `layouts.dir` | `string?` | `nil` | Directory containing named `<name>.lua` layouts. |
| `layouts.default` | `string\|table?` | `nil` | Fallback layout name/table. |
| `layouts.rules` | `table[]` | `{}` | First matching `{ match, layout }`; match is a Lua pattern or predicate. |
| `layouts.project_file` | `string` | `".harbor.lua"` | Project-root layout file; `""` disables lookup. |
| `layouts.trust_project_files` | `boolean` | `false` | Allow executing project layout Lua; enable only for trusted roots. |
| `sessions.dir` | `string?` | `nil` | Platform data root when omitted; sessions live in its `sessions` subdirectory. |
| `sessions.backup` | `boolean` | `true` | Retain previous session JSON as `.bak`. |
| `sessions.save_on_close` | `boolean` | `true` | Save a workspace before closing it; a failed save aborts the close. |
| `sessions.max_file_bytes` | `integer` | `33554432` | Read/write size cap in bytes, minimum `1024`; not a streaming read limit. |
| `sessions.scrollback.enabled` | `boolean` | `true` | Capture/replay bounded scrollback outside the alternate screen. |
| `sessions.scrollback.max_lines` | `integer` | `3500` | Non-negative capture line cap; `0` disables capture. |
| `sessions.scrollback.max_pane_bytes` | `integer` | `524288` | Non-negative byte cap per pane; `0` removes this byte cap. |
| `sessions.scrollback.remote` | `boolean` | `false` | Permit capture from remote panes. |
| `sessions.processes.enabled` | `boolean` | `true` | Capture/replay allowlisted local foreground argv. |
| `sessions.processes.allow` | `string[]` | `{}` | Extra lowercase basenames, without `.exe`; built-ins include editors, pagers, monitors, and file managers. |
| `sessions.processes.mode` | `"extend"\|"replace"` | `"extend"` | Extend the [built-in allowlist](../plugin/harbor/config.lua), or use only `allow`. |
| `sessions.processes.delay` | `number` | `0.3` | Replay delay in seconds, `0..10`; not an application-readiness check. |
| `sessions.autosave.enabled` | `boolean` | `false` | Enable periodic autosave. |
| `sessions.autosave.interval` | `number` | `300` | Seconds between passes, minimum `10`. |
| `sessions.autosave.on_focus_lost` | `boolean` | `false` | Also save on focus loss when autosave is enabled. |
| `sessions.autosave.scope` | `"all"\|"active"` | `"all"` | Periodic-pass targets; focus-loss saving targets that window's workspace. |
| `sessions.autosave.exclude` | `string[]` | `{}` | Exact workspace exclusions for periodic passes and `save_all`/`quit`, not the focus-loss path. |
| `sessions.restore_on_startup` | `boolean\|string` | `false` | Restore a named session; `true` uses the last recorded workspace. |

### Behavior and precedence

Warden logs invalid fields and falls back to defaults for those fields, leaving
valid options in place. Unknown fields produce warnings and remain. Setup
starts from schema defaults, normalizes maps by field, and replaces lists.
Options do not persist. Setup registers events and timers without scanning
directories or changing workspaces; loading dependencies may download plugins.

Harbor chooses layouts in this order: an explicit per-call layout, a trusted
project file, the first matching rule, then the default. Live workspaces win
over matching saved sessions and directories. It caches zoxide and project
results; `refresh` invalidates that cache.

Data uses `%LOCALAPPDATA%\wezterm\harbor` on Windows (home AppData fallback),
`~/Library/Application Support/wezterm/harbor` on macOS, and
`$XDG_STATE_HOME/wezterm/harbor` or `~/.local/state/wezterm/harbor` on Linux.
Harbor creates directories on demand for `history.json` and encoded
`sessions/*.json` names. Keep data outside the watched config directory;
Windows directory creation rejects cmd metacharacters.

Autosave tracks layout and directory changes, not scrollback-only changes.
Failed saves are retried. After a partial restore, close, or merge, Harbor
blocks autosave for the affected names. That protection survives reloads and
cache clearing, but not a restart. A successful explicit save accepts the
current partial layout and clears protection; it can replace a good snapshot,
so inspect the workspace first. A new timer generation stops old loops between
targets and before they reschedule.

Fuzzy input replaces the native description, so top hints cannot stay above it.
Status hints need an adapter and a visible status bar; Harbor never enables a bar
or falls back to top hints. Disabling hints retains explicit descriptions.

## API reference

`?` marks optional or nullable values. Run scanning, saving, and mux operations
inside WezTerm callbacks, which supply `window` and `pane`.
Use `.` for module and action-factory calls.

### Configuration and operations

| Signature → Return type | Description |
| --- | --- |
| `harbor.setup(options?) → table` | Replace settings and register/restart event/timer handling. |
| `harbor.apply_to_config(config) → table` | Initialize if needed, register the picker action table, and return the same config. |
| `harbor.set_picker_adapter(adapter?) → nil` | Replace the host adapter, or remove with `nil`; call before `apply_to_config` each reload. |
| `harbor.pick(window, pane, options?) → nil` | Open a picker; accepts `kinds` list/set, `title`, and `actions` (default true). A kinds list is converted in place. |
| `harbor.list(options?) → harbor.Entry[]` | Collect entries; optional `current` and `kinds` boolean set, not a kinds list. |
| `harbor.switch(window, pane, name) → boolean` | Switch workspace and record history on change. |
| `harbor.open_dir(window, pane, path, options?) → boolean` | Open/create a directory workspace; options include `name`, `layout`. |
| `harbor.create(window, pane, name, root?, options?) → boolean` | Create and switch; options include `domain`, `layout`. |
| `harbor.rename(window, pane, old, new) → boolean` | Rename or merge live workspaces; non-merge saved-name collisions are refused. |
| `harbor.close(window, pane, name) → boolean` | Save (per `save_on_close`), snapshot target pane IDs and kill those panes via CLI; never asks. |
| `harbor.save_all(window, pane) → boolean, string[]` | Save every live workspace, skipping `autosave.exclude` and protected names; returns failed names. |
| `harbor.quit(window, pane) → boolean` | `save_all`, then `QuitApplication`; does not quit when a save fails. |
| `harbor.previous(window, pane) → boolean` | Switch to the previous still-live workspace, or notify and return false. |
| `harbor.save(window, pane, name?) → boolean` | Save the named or active workspace; a successful explicit save clears restore protection. |
| `harbor.restore(window, pane, name, options?) → boolean, string?` | Restore/switch; `options.backup = true` explicitly reads `.bak` without promoting it. |
| `harbor.delete_session(window, pane, name) → boolean` | Delete primary saved JSON and its backup; does not close a live workspace. |
| `harbor.sessions() → table[]` | List `{ name, file }` records, without parsing each document. |
| `harbor.refresh() → nil` | Drop cached source results; does not reopen the current selector. |

Entries have a `kind` (`workspace`, `saved`, `dir`, `domain`), typed `id`,
and kind-specific fields and flags in the [annotations](../plugin/harbor/sources/init.lua).

An adapter has optional native `keys` and an `open(window, pane, session)` callback.
For status hints, the session contains `{ key_table, bindings }`. Return an
idempotent cleanup function for acceptance, cancellation, action dispatch,
reopening, and handled errors. If the adapter throws before returning, it must
clean up itself. Harbor installs extra keys only when status hints are enabled.
Avoid stacking unrelated tables: Harbor pops its own table only when it is
on top. Chord integration uses the generic `temporary` API;
Chord is not a dependency.

### Key-assignment factories

| Signature → Return type | Description |
| --- | --- |
| `harbor.action.pick(options?) → KeyAssignment` | All sources or selected kinds/title; `actions = false` disables action keys for this opening. |
| `harbor.action.workspaces() → KeyAssignment` | Live-workspace picker. |
| `harbor.action.projects() → KeyAssignment` | All directory entries, not just the projects provider. |
| `harbor.action.sessions() → KeyAssignment` | Saved and live-workspace entries. |
| `harbor.action.domains() → KeyAssignment` | Domain picker without action keys. |
| `harbor.action.previous() → KeyAssignment` | Previous live workspace. |
| `harbor.action.save() → KeyAssignment` | Save the active workspace. |
| `harbor.action.restore() → KeyAssignment` | Prompt for a saved name. |
| `harbor.action.new() → KeyAssignment` | Prompt for a new workspace name. |
| `harbor.action.new_at_path() → KeyAssignment` | Prompt for a directory. |
| `harbor.action.rename() → KeyAssignment` | Prompt to rename/merge the active workspace. |
| `harbor.action.close() → KeyAssignment` | Ask, then close all panes of the active workspace when another exists. |
| `harbor.action.quit() → KeyAssignment` | Save every workspace, then quit. |
| `harbor.action.refresh() → KeyAssignment` | Invalidate sources. |

### Events and constants

Events emit `(window, pane, payload)`; background operations may pass nil
window/pane. Event-handler errors log instead of aborting the operation.

| Constant | Value | Meaning |
| --- | --- | --- |
| `harbor.VERSION` | `"0.1.0"` | Plugin version string. |
| `harbor.events` | List of the seven names below | Event discovery; not a registration function. |

| Event | Payload |
| --- | --- |
| `harbor.workspace.switched` | `{ name, from }` |
| `harbor.workspace.created` | `{ name, path? }` |
| `harbor.workspace.renamed` | `{ from, to, merged }` |
| `harbor.workspace.closed` | `{ name, panes }` |
| `harbor.session.saved` | `{ name }` |
| `harbor.session.restored` | `{ name }` |
| `harbor.session.deleted` | `{ name }` |

## Troubleshooting

### A restore is partial or fails

Harbor validates pane trees before spawning anything. Missing local directories
or unavailable domains cause an error rather than a different destination.
Failures in window or tab creation, splits, titles, focus, zoom, output, or
scheduling return `false, error` with context. Harbor logs the full error,
then closes every pane the restore created, cancels pending command replay, and
does not switch or emit a success event, so you can retry right away. If the
rollback cannot close a pane, the partial workspace stays open and autosave
stays blocked for it. Restore on startup does not roll back, so WezTerm never
starts without a window.

A successful return does not guarantee that an editor started. If replay fails
later, Harbor logs the error and blocks autosave. Running programs control
subsequent pane titles.

### Recover a backup without overwriting the primary

From an action callback use
`harbor.restore(window, pane, "dev", { backup = true })`.
Harbor never promotes a backup automatically, even if the primary is corrupt
or oversized. It checks writes before replacing files and keeps `.bak` by
default. Each write goes to its own temporary file that is renamed over the
target, and the backup is copied the same way first, so concurrent writers
cannot corrupt a session (the last complete save wins) and the primary is never
missing on POSIX systems. On Windows a replacement still takes two renames.
There is no `fsync`; a power loss can still lose the latest save.

### Close or rename reports failure

Close uses `wezterm cli --no-auto-start kill-pane --pane-id ...` with captured
IDs. If some pane kills fail, Harbor keeps history and path metadata and does
not emit a full-close event. Merge and saved-session rename failures are reported
instead of overwriting colliding names.

Check **Ctrl+Shift+L**, missing optional executables, and data permissions.
After publication, update with `wezterm.plugin.update_all()` and reload;
report [issues](https://github.com/sravioli/harbor.wz/issues) with sanitized
options, plugin/WezTerm revisions, and logs. Do not attach private scrollback.

## Development

### Local checkout

Place the checkout at `plugins/harbor.wz` beneath `wezterm.config_dir` and replace
the remote import:

```lua
local wezterm = require "wezterm"
local harbor = wezterm.plugin.require(
  "file:///" .. wezterm.config_dir .. "/plugins/harbor.wz"
)
```

Offline loading needs sibling APIs on `package.path`; specs require all six checkouts.

### Editor support

Add `plugin` to [LuaLS's library](https://luals.github.io/wiki/settings/#workspacelibrary).
[wezterm-types](https://github.com/DrKJeff16/wezterm-types) has no Harbor entry;
the local API also lacks a named module class:

```lua
---@type table
local harbor = wezterm.plugin.require "https://github.com/sravioli/harbor.wz"
```

The generic annotation does not describe Harbor's methods. See the
[API](../plugin/harbor/api.lua), [schema](../plugin/harbor/config.lua), and `harbor.Entry`.

### Checks and contributions

From the repository root, with Lua 5.4 and the named tools installed:

```sh
busted --verbose
luacheck plugin spec
selene --display-style=quiet plugin
stylua --check plugin spec
```

Tests use mocked mux APIs and temporary data with real dependencies. There are no CI
workflows or separate contribution guide. Follow [AGENTS.md](../AGENTS.md), use
Conventional Commits, and cover behavior changes with focused specs.

## License

Code: [GNU GPL v2](../LICENSE). Documentation:
[CC BY-NC 4.0](../LICENSE-DOCS). Preserve existing attribution.

Design credits:
[smart_workspace_switcher](https://github.com/MLFlexer/smart_workspace_switcher.wezterm),
[workspace-manager](https://github.com/ryanmsnyder/workspace-manager.wezterm),
[workspace-picker](https://github.com/isseii10/workspace-picker.wezterm),
[sessionizer](https://github.com/mikkasendke/sessionizer.wezterm),
[workspacesionizer](https://github.com/vieitesss/workspacesionizer.wezterm),
[quick_domains](https://github.com/DavidRR-F/quick_domains.wezterm),
[wsinit](https://github.com/JuanraCM/wsinit.wezterm),
[resurrect](https://github.com/StephenGemin/resurrect.wezterm),
[wezterm-sessions](https://github.com/abidibo/wezterm-sessions),
[tabsets](https://github.com/srackham/tabsets.wezterm).
