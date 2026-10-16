# Changelog

All notable changes to this project are documented here. The format follows
[Conventional Commits](https://www.conventionalcommits.org/) and versions are
managed with [Cocogitto](https://docs.cocogitto.io/).

## Unreleased

### Features

- Unified fuzzy picker over workspaces, saved sessions, zoxide, git projects,
  pinned directories, domains and custom sources.
- In-picker actions: delete, rename, new, new at path, save.
- Workspace switching with previous-workspace history, rename (with merge)
  and close.
- Session save/restore: tabs, split tree, cwd, domain, zoom, sanitized
  scrollback and allowlisted foreground programs.
- Autosave on a timer and on focus loss, restore on startup.
- Layouts for new workspaces by rule, default, or trusted project file.
- Validated options: invalid fields fall back to defaults.
