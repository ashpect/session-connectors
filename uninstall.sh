#!/bin/bash
# Removes Relay: its hook entries (nothing else in your settings), ~/.relay, and the app.
set -euo pipefail
cd "$(dirname "$0")"

pkill -x Relay 2>/dev/null || true
/usr/bin/python3 scripts/hooks.py uninstall claude codex
rm -rf "$HOME/.relay" "$HOME/Applications/Relay.app"

cat <<'EOF'
Relay is removed. Copies of your settings from before Relay first changed them are next to
them as *.relay-backup; delete them whenever you like.
EOF
