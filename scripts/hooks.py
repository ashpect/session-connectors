#!/usr/bin/env python3
"""Adds or removes Relay's hook in Claude Code and Codex.

    hooks.py install   claude codex
    hooks.py uninstall claude codex

Claude Code reads ~/.claude/settings.json and Codex reads ~/.codex/hooks.json; both use the same
format. Only Relay's own entries are touched, key order is preserved, and each file is backed up
(as <file>.relay-backup) before Relay changes it for the first time. Safe to run repeatedly.
"""
import json
import os
import shutil
import sys

HOME = os.path.expanduser("~")
HOOK = f"{HOME}/.relay/relay-hook"
EVENTS = ["UserPromptSubmit", "Stop"]
FILES = {
    "claude": f"{HOME}/.claude/settings.json",
    "codex": f"{HOME}/.codex/hooks.json",
}


def command(agent):
    return f"{HOOK} {agent}"


def load(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        text = f.read().strip()
    return json.loads(text) if text else {}


def save(path, cfg):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path) and not os.path.exists(path + ".relay-backup"):
        shutil.copy2(path, path + ".relay-backup")
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write("\n")


def install(agent):
    path = FILES[agent]
    cfg = load(path)
    hooks = cfg.setdefault("hooks", {})
    changed = False
    for event in EVENTS:
        groups = hooks.setdefault(event, [])
        if not any(h.get("command") == command(agent) for g in groups for h in g.get("hooks", [])):
            groups.append({"hooks": [{"type": "command", "command": command(agent), "timeout": 5}]})
            changed = True
    if changed:
        save(path, cfg)
        print(f"  {agent}: added Relay's hooks to {path}")
    else:
        print(f"  {agent}: already set up in {path}")


def uninstall(agent):
    path = FILES[agent]
    if not os.path.exists(path):
        return
    cfg = load(path)
    hooks = cfg.get("hooks", {})
    changed = False
    for event in EVENTS:
        kept = []
        for group in hooks.get(event, []):
            entries = group.get("hooks", [])
            rest = [h for h in entries if h.get("command") != command(agent)]
            if len(rest) != len(entries):
                changed = True
                if not rest:
                    continue
                group = {**group, "hooks": rest}
            kept.append(group)
        if kept:
            hooks[event] = kept
        elif event in hooks:
            del hooks[event]
    if not changed:
        return
    if agent == "codex" and cfg == {"hooks": {}}:
        os.remove(path)  # Relay created this file; leave nothing behind
        print(f"  {agent}: removed {path}")
    else:
        save(path, cfg)
        print(f"  {agent}: removed Relay's hooks from {path}")


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("install", "uninstall"):
        sys.exit(__doc__)
    action = install if sys.argv[1] == "install" else uninstall
    for agent in sys.argv[2:]:
        if agent not in FILES:
            sys.exit(f"Unknown agent '{agent}'. Use claude and/or codex.")
        action(agent)
