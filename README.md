# Relay

Relay connects your Claude Code and Codex sessions so that one session's answer becomes the next session's prompt. You can send answers one way, or run a loop: Claude writes a plan, Codex reviews it, the review goes back to Claude, and so on until one of them says a phrase you picked, like `LGTM`.

It's a small floating window for macOS that works with the Claude Code and Codex sessions you already have open in iTerm2. Nothing about how you run them changes.

![Relay running a plan-review loop between Claude and Codex](docs/relay.png)

*A loop between a Claude session writing a plan and a Codex session reviewing it: ready, mid-run, and finished after Codex said "LGTM".*

## Why

If you use two agents on the same plan, you end up copying Claude's plan into Codex, copying Codex's review back into Claude, and doing it again for every revision. Relay does that copying for you. You write the instructions that travel with each answer once, and decide when the back-and-forth should stop.

## How it works

1. **Pick your sessions.** Click an empty slot in Relay, then click an iTerm pane. A thread follows your cursor out of Relay, latches onto the pane you click, and pulls that session into the slot.
2. **Write what gets sent.** Each connection between the two sessions carries a prompt of your own. The answer is inserted wherever you put `{answer}`.
3. **Pick one-way or loop.** One-way sends the first session's answers to the second. Loop also sends the second session's replies back, with a prompt of their own.
4. **Set when to stop.** Stop when either session (or a particular one) ends its reply with a phrase such as `AGREED`, or after a set number of rounds.
5. **Press Start.**

Under the hood, Relay installs a small hook in Claude Code and in Codex. Whenever a turn ends, the hook passes the answer to Relay over a local socket. Relay wraps the answer in your prompt and pastes it into the other pane, just as if you'd pasted it yourself and pressed Return:

```
Claude pane ── Stop hook ──▶ relay-hook ──▶ Relay ── paste ──▶ Codex pane
     ▲                                                             │
     └────────── paste ◀── Relay ◀── relay-hook ◀── Stop hook ─────┘
```

## Requirements

- macOS 14 (Sonoma) or later
- [iTerm2](https://iterm2.com). Relay reads and types into iTerm panes; other terminals aren't supported.
- Xcode Command Line Tools, for Swift 5.9 or later: `xcode-select --install`
- [Claude Code](https://docs.claude.com/en/docs/claude-code) and/or the [Codex CLI](https://github.com/openai/codex)

## Install

```sh
git clone https://github.com/ashpect/session-connectors.git
cd session-connectors
./install.sh
```

`install.sh` does the following:

- builds Relay and copies it to `~/Applications/Relay.app`
- puts the hook program in `~/.relay/relay-hook`
- registers the hook for `UserPromptSubmit` and `Stop` in `~/.claude/settings.json` (Claude Code) and `~/.codex/hooks.json` (Codex), but only for the agents it finds. Nothing else in those files changes, and each file is backed up as `*.relay-backup` before Relay touches it the first time.
- opens Relay

You can safely run it again; that's also how you update.

### Finish setup (one time)

1. **Allow iTerm control.** macOS asks *"Relay wants to control iTerm2"*. Click **Allow**. If you missed it, go to System Settings → Privacy & Security → Automation → Relay and turn on iTerm2.
2. **Trust the hooks in Codex.** The next time Codex starts, it shows *"Hooks need review"*. Choose **Trust all and continue**. Codex sessions that were already running need a restart (`codex resume`).
3. **Load the hooks in Claude Code.** New sessions pick them up on their own. In Claude sessions that were already open, run `/hooks` once, or restart them with `claude --continue`.

If a hook is missing, Relay shows a warning at the top of its window.

## Using Relay

Open Relay from the menu bar icon (two dots joined by a thread), or press **⌃⌥K** from anywhere.

1. **Fill a flow.** Click the top slot, then click the pane whose answers should go first, for example the Claude session writing your plan. Click the bottom slot, then click the pane that should receive them, for example Codex reviewing it. You can also press **Pick** twice (it fills the top slot, then the bottom), drag a session chip onto a slot, or use **Choose**.
2. **Write the prompts.** Click the prompt on a connection to edit it. The answer goes where `{answer}` is. If you leave `{answer}` out, the answer is added at the end, and an empty prompt sends the answer as-is.
3. **Turn on Loop** if the reply should come back up to the first session.
4. **Set the stop rule:** stop when *either / Claude / Codex* ends its reply with a phrase, with a maximum number of rounds as a backstop. Only a **last line that's just the phrase** counts (`AGREED`, `**AGREED**` and `AGREED.` all do). A reply that merely mentions it, like "Not AGREED, because…", keeps the loop going. Ask for it that way in your prompt: *"If you have concerns, don't use the word AGREED. Only when you're fully happy, end with a last line that says just: AGREED."* The built-in presets already do.
5. **Press Start.** Relay sends the first session's latest answer right away. If that session hasn't answered since Relay started, its next answer goes first. To switch a flow on *without* sending the latest answer (say, you've already dealt with it), use the flow's **⋯ → Turn on without sending**. **Stop** ends a flow, and **Live / Paused** in the header pauses every flow.

Want to look around before connecting real sessions? Choose **⋯ → Load demo flow**.

### Presets

A preset is a saved flow setup: one-way or loop, both prompts, and the stop rule. It doesn't include the sessions, so the same preset works for any pair of panes. Open the book menu at the top of a flow to use one:

- **Apply a preset.** The flow fills in right away, and an **Undo** bar appears for a few seconds in case you picked the wrong one.
- **Save as preset…** Name the flow's current setup and reuse it on other flows.
- **Update "…" with this setup** appears after you've edited a flow that came from one of your saved presets. It updates the preset to match. A dot after the preset's name (`My review loop •`) means the flow has changed since you applied it.

Relay ships with three presets:

| Preset | Mode | What it does | Stops when |
|---|---|---|---|
| **Plan review** | Loop | One session writes the plan and the other reviews it; the review goes back for fixes | the reviewer ends with `LGTM` (max 6 rounds) |
| **Plan discussion** | Loop | Two peers talk the plan through, accepting points and pushing back | either ends with `AGREED` (max 6 rounds) |
| **Second opinion** | One-way | Sends an answer off for a quick check | — |

You can see and rename your saved presets, or delete them, in **⋯ → Settings… → Presets**. They're stored in `~/.relay/presets.json`, so you can copy that file to share them.

For example, to review a plan with Claude and Codex: put Claude (writing the plan) in the top slot and Codex in the bottom, apply **Plan review**, and press **Start**. Or ask Claude for the plan first; once it answers, Relay takes it from there.

### Settings

Open **⋯ → Settings…** to find:

- **Wait before sending.** After a session answers, Relay can wait a few seconds (anything from 0 to 600) before pasting the answer into the next session. While it waits, the flow counts down ("Sending to Codex in 8s") with a **Send now** button, and **Stop** cancels the send. The default is off.
- **Window options:** fade when the cursor isn't over Relay, and opacity.
- **Hook status** for Claude Code and Codex, plus the list of shortcuts.

### Shortcuts

| Keys | What they do |
|---|---|
| ⌃⌥K | Show or hide Relay |
| ⌥⌘P | Pick the pane you're in (from iTerm), or start picking |
| Right-click or Esc | Cancel a pick |
| Double-click a session's name | Rename it |

The session menu (**⋯** on each session) also has Reveal in iTerm, Replace, and Remove, and the eye icon shows a live view of the pane.

### Good to know

- **Relay types into panes.** Don't type in a pane that's part of a running flow, or your half-written text will mix with Relay's message.
- **A busy session isn't interrupted.** If the receiving session is mid-turn, Relay waits for that turn to end and then sends.
- **Relay only hears turns while it's running.** When Relay is closed, the hook exits immediately and does nothing.
- **The hook runs on every turn of every session.** It's a tiny program that forwards the event and prints nothing. Relay ignores sessions that aren't in a flow.
- **Your flows are saved** in `~/.relay/state.json`.
- **Each time you rebuild or update,** macOS asks again for permission to control iTerm. That's because Relay is built locally without a signing certificate.

## Troubleshooting

**Nothing happens when a turn ends.** Check the three setup steps above: the hooks are installed, Codex trusts them, and the Claude session has loaded them. To see what Relay hears, turn on logging:

```sh
touch ~/.relay/debug        # every hook call → ~/.relay/hook.log, everything Relay does → ~/.relay/relay.log
rm ~/.relay/debug           # turn it off again
```

**"Relay can't read iTerm yet."** Give Relay permission to control iTerm2 (setup step 1).

**"Sent to Codex, but it hasn't confirmed receiving it."** The receiving pane was probably showing a dialog, such as a permission prompt, or its hooks aren't trusted yet.

**The window is gone.** Press ⌃⌥K or click the menu bar icon. Opening Relay again from Spotlight also brings it back.

## Update

```sh
git pull && ./install.sh
```

## Uninstall

```sh
./uninstall.sh
```

This removes Relay's hook entries (and nothing else) from your Claude Code and Codex settings, along with `~/.relay` and `~/Applications/Relay.app`. The `*.relay-backup` copies of your settings stay where they are. Codex also keeps a trust record for the removed hooks in `~/.codex/config.toml` (under `[hooks.state]`); it's harmless, and you can delete it if you like.

## Development

```sh
./build.sh --open    # build into ./build and relaunch (doesn't touch ~/Applications)
swift test           # unit tests: stop-phrase matching, prompt composition
```

| File | What's in it |
|---|---|
| `Sources/Relay/App.swift` | App startup, the floating panel, menu bar icon, global shortcuts |
| `Sources/Relay/Model.swift` | Sessions, flows, and the engine that moves answers between sessions |
| `Sources/Relay/Hook.swift` | `relay-hook` (the program the agents run) and the socket server that receives its events |
| `Sources/Relay/ITerm.swift` | Reading panes and pasting into them through iTerm's AppleScript interface |
| `Sources/Relay/Picker.swift`, `Thread.swift` | The pick gesture and the thread that follows your cursor |
| `Sources/Relay/Views.swift`, `FlowViews.swift` | The SwiftUI interface |
| `scripts/hooks.py` | Adds and removes Relay's hook entries in the agents' settings |

Both agents report the answer in their `Stop` hook as `last_assistant_message`. For Claude Code, the hook runs inside the pane's process tree, so `$ITERM_SESSION_ID` identifies the pane. Codex usually runs turns in a shared background daemon (`codex app-server`). Its environment belongs to whichever pane happened to start the daemon, so `relay-hook` ignores the pane ID there. Relay instead matches the Codex thread to its pane by the exact prompt it pasted (Codex's `UserPromptSubmit` carries it), falling back to the folder and the text on screen, and it remembers the match.

To render the interface to an image without a screen, which is handy for checking layout changes:

```sh
build/Relay.app/Contents/MacOS/Relay --snapshot out.png --demo [--sim --at 3] [--oneway] [--peek] [--settings] [--delay 10] [--preset plan-review]
```

## Limitations

- macOS and iTerm2 only.
- Relay is built from source and isn't signed, which is why macOS asks for iTerm permission again after each update.
