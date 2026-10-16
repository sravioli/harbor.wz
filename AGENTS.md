# Repository Guidelines

## Project Structure & Module Organization

harbor is a WezTerm workspace and session manager. The entrypoint `plugin/init.lua` bootstraps `package.path` and returns `harbor.api`. Modules live in `plugin/harbor/`: `api.lua` (public surface and `action.*`), `config.lua` (warden schema, defaults, live config), `deps.lua` (sibling plugin loading), `workspace.lua` (switch/create/rename/close/save/restore), `picker.lua` (InputSelector, key table, dispatch), `layout.lua`, `naming.lua`, `history.lua`, `state.lua`, `util.lua`, `logger.lua`. Entry providers are in `sources/` and persistence in `session/` (`capture`, `restore`, `store`, `auto`). Specs live in `spec/`, with a hand-written WezTerm mock in `spec/mocks/wezterm.lua` and shared setup in `spec/support/env.lua`. User docs are in `.github/readme.md`.

## Build, Test, and Development Commands

- `busted`: runs the suite. The mock puts sibling checkouts (`../warp.wz`, `../memo.wz`, `../log.wz`, `../warden.wz`, `../sigil.wz`, `../ribbon.wz`) on `package.path`, so specs run against the real dependencies.
- `luacheck plugin spec`: lint.
- `selene --display-style=quiet plugin`: second lint profile.
- `stylua --check plugin spec`: formatting.

## Coding Style & Naming Conventions

Two-space indentation, `snake_case`, `require "x"` without parentheses, LuaCATS annotations, `---@module`/`---@author`/`---@license` headers. Reuse warp, memo, log and warden instead of reimplementing helpers. Never use a shell or `io.popen`; external programs go through `wezterm.run_child_process` with argument lists. Nothing may spawn processes or touch the disk at require or setup time. Wrap user callbacks and action handlers so they log instead of raising.

## Testing Guidelines

Add or update specs for every behavior change. Bug fixes need a regression test. Stub collaborators by replacing functions on the cached module table and restore them in `after_each`. Use `env.setup(opts)` for an isolated data directory.

## Commit & Pull Request Guidelines

Conventional Commits, subject at most 50 characters, e.g. `fix(picker): pop key table once`. Keep source, specs, docs and tooling in separate commits where practical.
