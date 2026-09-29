import SwiftUI

struct SettingsView: View {
    @Environment(RelayStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 16) {
            Button { withAnimation(.snappy) { store.showingSettings = false } } label: {
                Label("Back to flows", systemImage: "chevron.left").font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text2)

            SettingsGroup(title: "Sending") {
                HStack(spacing: 8) {
                    Text("Wait before sending").font(.system(size: 12.5))
                    Spacer()
                    TextField("0", value: $store.sendDelay, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 42)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(FieldBackground())
                    Text("sec").font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                    Stepper("", value: $store.sendDelay, in: 0...600, step: 1).labelsHidden()
                }
                HStack(spacing: 6) {
                    ForEach([0.0, 3, 10, 30, 60], id: \.self) { s in
                        let on = store.sendDelay == s
                        Button(s == 0 ? "Off" : "\(Int(s))s") { store.sendDelay = s }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(on ? Theme.text1 : Theme.text2)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(Capsule().fill(on ? Color.white.opacity(0.15) : Color.black.opacity(0.2)))
                    }
                }
                Hint("After a session answers, Relay waits this long before pasting the answer into the next session, so you can read it first, send it straight away, or press Stop.")
            }
            .onChange(of: store.sendDelay) { store.sendDelay = min(600, max(0, store.sendDelay.rounded())) }

            SettingsGroup(title: "Presets") {
                ForEach(Preset.builtIns) { PresetRow(preset: $0) }
                ForEach(store.presets) { PresetRow(preset: $0) }
                Hint("Apply one from the book menu on any flow. To save your own, set a flow up, then pick Save as preset… from that menu. Saved presets live in ~/.relay/presets.json, so you can share the file.")
            }

            SettingsGroup(title: "Window") {
                Toggle(isOn: $store.fadeWhenIdle) { Text("Fade when the cursor isn't over Relay").font(.system(size: 12.5)) }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.live)
                HStack {
                    Text("Opacity").font(.system(size: 12.5))
                    Spacer()
                    Picker("", selection: $store.opacity) {
                        Text("100%").tag(1.0)
                        Text("85%").tag(0.85)
                        Text("70%").tag(0.7)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            SettingsGroup(title: "Hooks") {
                HookRow(agent: .claude, file: "~/.claude/settings.json")
                HookRow(agent: .codex, file: "~/.codex/hooks.json")
                Hint("Relay hears that a turn ended through these hooks; install.sh adds them. Codex asks you to trust them once, and Claude sessions that were already open need /hooks.")
            }

            SettingsGroup(title: "Shortcuts") {
                ShortcutRow(keys: "⌃⌥K", action: "Show or hide Relay")
                ShortcutRow(keys: "⌥⌘P", action: "Pick the pane you're in")
                ShortcutRow(keys: "Right-click · Esc", action: "Cancel a pick")
                ShortcutRow(keys: "Double-click a name", action: "Rename a session")
            }
        }
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
        }
    }
}

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.text3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct HookRow: View {
    let agent: AgentKind
    let file: String

    var body: some View {
        let ok = RelayStore.hookInstalled(agent)
        HStack(spacing: 8) {
            AgentGlyph(kind: agent, size: 18)
            Text(agent == .claude ? "Claude Code" : "Codex").font(.system(size: 12.5))
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Theme.live : Theme.paused)
            Text(ok ? "Installed" : "Missing").font(.system(size: 11, weight: .semibold)).foregroundStyle(ok ? Theme.live : Theme.paused)
        }
        .help(file)
    }
}

struct ShortcutRow: View {
    let keys: String
    let action: String

    var body: some View {
        HStack {
            Text(action).font(.system(size: 12))
            Spacer()
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.25)))
        }
    }
}

struct PresetRow: View {
    @Environment(RelayStore.self) private var store
    let preset: Preset
    @State private var name = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: preset.loop ? "arrow.triangle.2.circlepath" : "arrow.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.text3)
                .frame(width: 14)
                .help(preset.loop ? "Loop" : "One-way")
            if preset.builtIn {
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name).font(.system(size: 12.5))
                    if !preset.note.isEmpty { Text(preset.note).font(.system(size: 10.5)).foregroundStyle(Theme.text3) }
                }
            } else {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .onSubmit { store.renamePreset(preset.id, to: name) }
                    .onAppear { name = preset.name }
                    .help("Rename, then press Return")
            }
            Spacer(minLength: 4)
            if !preset.stopPhrase.isEmpty {
                Text(preset.stopPhrase)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.25)))
                    .help("Stops when it sees this")
            }
            if preset.builtIn {
                Text("Built in").font(.system(size: 10)).foregroundStyle(Theme.text3)
            } else {
                Button { store.deletePreset(preset.id) } label: {
                    Image(systemName: "trash").font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text3)
                .help("Delete this preset")
            }
        }
    }
}
