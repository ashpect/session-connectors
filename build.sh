#!/bin/bash
# Builds Relay.app into ./build. Pass --open to (re)launch it.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/Relay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Relay "$APP/Contents/MacOS/Relay"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
# The same binary doubles as the hook Claude Code and Codex call (see Hook.swift).
mkdir -p "$HOME/.relay"
cp .build/release/Relay "$HOME/.relay/relay-hook.tmp" && mv -f "$HOME/.relay/relay-hook.tmp" "$HOME/.relay/relay-hook"
echo "Built $APP"
if [[ "${1:-}" == "--open" ]]; then
  pkill -x Relay 2>/dev/null || true
  sleep 0.3
  open "$APP"
fi
