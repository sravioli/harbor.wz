#!/usr/bin/env bash
# Screenshot every harbor picker, dark (kanagawa-wave) and light
# (kanagawa-lotus) from the kanagawa plugin
# (https://github.com/kanagawa-community/wezterm): .github/assets/<scene>/{dark,light}.png.
#
# Needs KDE Plasma (spectacle) and wezterm; oxipng is used when installed.
# Run it from a session you leave alone: each shot opens a window that must
# keep the focus until it is captured.
#
#   scripts/screenshots.sh                  # every scene
#   scripts/screenshots.sh projects sessions  # only these
#
# Scenes: pick workspaces projects sessions domains
#
# Settings (environment): HARBOR_FONT ("FiraCode Nerd Font"), HARBOR_FONT_SIZE (14),
# HARBOR_COLS (100), HARBOR_ROWS (30), HARBOR_DELAY (seconds to wait for the window, default 5).
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
delay=${HARBOR_DELAY:-5}
all=(pick workspaces projects sessions domains)
scenes=("${@:-${all[@]}}")

for tool in wezterm spectacle; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }
done

export HARBOR_REPO="$repo"
HARBOR_SESSIONS=$(mktemp -d)
HARBOR_DEMO=$(mktemp -d)
export HARBOR_SESSIONS HARBOR_DEMO
trap 'rm -rf "$HARBOR_SESSIONS" "$HARBOR_DEMO"' EXIT
mkdir -p "$HARBOR_DEMO"/{api,website,dotfiles}/.git # demo projects for the projects picker

shoot() { # scene kanagawa-scheme file-name
  local dir="$repo/.github/assets/$1"
  mkdir -p "$dir"
  HARBOR_SCENE=$1 HARBOR_KANAGAWA=$2 \
    wezterm --config-file "$repo/scripts/screenshot.wezterm.lua" start --always-new-process &
  local pid=$!
  sleep "$delay"
  spectacle --activewindow --background --nonotify --output "$dir/$3.png"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  command -v oxipng >/dev/null && oxipng -q -o4 --strip all "$dir/$3.png"
  echo "$dir/$3.png"
}

for scene in "${scenes[@]}"; do
  shoot "$scene" wave dark
  shoot "$scene" lotus light
done
