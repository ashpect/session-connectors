#!/bin/bash
# Installs Relay: builds the app into ~/Applications, puts the hook program in ~/.relay, and
# registers it with Claude Code and Codex. Safe to re-run (that's also how you update).
set -euo pipefail
cd "$(dirname "$0")"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*"; }

[[ "$(uname)" == "Darwin" ]] || { echo "Relay only runs on macOS."; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || { echo "Relay needs macOS 14 (Sonoma) or later."; exit 1; }
command -v swift >/dev/null || { echo "Swift isn't installed. Run: xcode-select --install"; exit 1; }
[[ -d /Applications/iTerm.app ]] || warn "iTerm2 isn't in /Applications. Relay only works with iTerm2 panes."

agents=()
if [[ -d "$HOME/.claude" ]] || command -v claude >/dev/null; then agents+=(claude); fi
if [[ -d "$HOME/.codex" ]] || command -v codex >/dev/null; then agents+=(codex); fi
(( ${#agents[@]} )) || warn "Found neither Claude Code nor Codex. Install one, then re-run ./install.sh to add its hook."

bold "Building Relay…"
./build.sh

bold "Installing to ~/Applications…"
pkill -x Relay 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Relay.app"
cp -R build/Relay.app "$HOME/Applications/Relay.app"

if (( ${#agents[@]} )); then
  bold "Registering hooks…"
  /usr/bin/python3 scripts/hooks.py install "${agents[@]}"
fi

open "$HOME/Applications/Relay.app"

cat <<'EOF'

Relay is running (menu bar icon, or ⌃⌥K). Three one-time steps are left:
  1. macOS asks "Relay wants to control iTerm2"  →  Allow
  2. Codex, next time it starts: "Hooks need review"  →  Trust all and continue
  3. Claude Code sessions that were already open: run /hooks once, or restart them
Then pick two panes into a flow and press Start. See README.md for the walkthrough.
EOF
