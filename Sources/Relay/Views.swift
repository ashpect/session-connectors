import SwiftUI

enum Theme {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let codex = Color(red: 0.50, green: 0.64, blue: 1.00)
    static let shell = Color(white: 0.72)
    static let live = Color(red: 0.36, green: 0.84, blue: 0.56)
    static let paused = Color(red: 0.98, green: 0.74, blue: 0.32)
    static let danger = Color(red: 1.00, green: 0.45, blue: 0.42)
    static let text1 = Color.white.opacity(0.93)
    static let text2 = Color.white.opacity(0.62)
    static let text3 = Color.white.opacity(0.38)
    static let fill = Color.white.opacity(0.055)
    static let stroke = Color.white.opacity(0.09)
}

// MARK: - Root

struct RootView: View {
    @Environment(RelayStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            if let notice = store.notice { NoticeBar(text: notice) }
            if store.pick != .idle { PickBanner() }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if store.sessions.isEmpty {
                        Intro()
                    } else {
                        SessionDock()
                    }
                    ForEach(Array(store.flows.enumerated()), id: \.element.id) { i, flow in
                        FlowCard(flowID: flow.id, number: i + 1)
                            .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
                    }
                    NewFlowButton()
                    if store.sessions.isEmpty {
                        Button("Just looking? Load a demo flow") { store.loadDemo() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text3)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
            ActivityFooter()
        }
        .foregroundStyle(Theme.text1)
        .background(LinearGradient(colors: [Color.white.opacity(0.04), .clear], startPoint: .top, endPoint: .center))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
        .preferredColorScheme(.dark)
    }
}

struct Intro: View {
    var body: some View {
        Text("Wire your sessions together: one session's answer becomes the next one's prompt. Turn on **Loop** and the reply comes back too.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.text2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }
}

// MARK: - Header

struct HeaderBar: View {
    @Environment(RelayStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 10) {
            RelayMark()
            Text("Relay").font(.system(size: 13.5, weight: .semibold, design: .rounded))
            LivePill()
            Spacer()
            Button { store.picker?.begin() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "eyedropper").font(.system(size: 11, weight: .semibold))
                    Text("Pick").font(.system(size: 11.5, weight: .semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(store.pick == .idle ? Color.white.opacity(0.1) : Theme.live.opacity(0.25)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("Pick up a session (⌥⌘P)")

            Menu {
                Button("New flow") { store.addFlow() }
                Button("Load demo flow") { store.loadDemo() }
                Divider()
                Toggle("Fade when not hovered", isOn: $store.fadeWhenIdle)
                Picker("Opacity", selection: $store.opacity) {
                    Text("100%").tag(1.0)
                    Text("85%").tag(0.85)
                    Text("70%").tag(0.7)
                }
                Divider()
                Button("Clear activity") { store.log.removeAll() }
                Divider()
                Button("Pick a pane  ⌥⌘P") { store.picker?.begin() }
                Button("Hide Relay  ⌃⌥K") { store.togglePanel?() }
                Button("Quit Relay") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.leading, 14).padding(.trailing, 10)
        .frame(height: 46)
        .background(WindowDragArea())
    }
}

struct RelayMark: View {
    var body: some View {
        ZStack {
            Circle().fill(Theme.claude).frame(width: 7, height: 7).offset(x: -5, y: 3)
            Circle().fill(Theme.codex).frame(width: 7, height: 7).offset(x: 5, y: -3)
            Capsule().fill(Color.white.opacity(0.5)).frame(width: 9, height: 1.5).rotationEffect(.degrees(-31))
        }
        .frame(width: 20, height: 20)
    }
}

struct LivePill: View {
    @Environment(RelayStore.self) private var store
    @State private var breathe = false

    var body: some View {
        let color = store.running ? Theme.live : Theme.paused
        Button { withAnimation(.snappy) { store.running.toggle() } } label: {
            HStack(spacing: 5) {
                if store.running {
                    Circle().fill(color).frame(width: 6, height: 6)
                        .opacity(breathe ? 0.35 : 1)
                        .animation(.easeInOut(duration: 1.1).repeatForever(), value: breathe)
                } else {
                    Image(systemName: "pause.fill").font(.system(size: 7, weight: .black))
                }
                Text(store.running ? "Live" : "Paused")
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help(store.running ? "Pause every flow" : "Resume flows")
        .onAppear { breathe = true }
    }
}

struct NoticeBar: View {
    @Environment(RelayStore.self) private var store
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.paused)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { store.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.text3)
        }
        .font(.system(size: 11))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.paused.opacity(0.12)))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

// MARK: - Picking

struct PickBanner: View {
    @Environment(RelayStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope").foregroundStyle(store.pick == .miss ? Theme.danger : Theme.live)
            Text(store.pick == .miss ? "That wasn't an iTerm pane. Click a terminal." : "Click the iTerm pane you want to dock")
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Cancel") { store.picker?.cancel() }.buttonStyle(.plain).foregroundStyle(Theme.text2)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.live.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.live.opacity(0.25)))
        .padding(.horizontal, 12).padding(.bottom, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// The small card that rides on your cursor while picking.
struct CursorChip: View {
    @Environment(RelayStore.self) private var store

    var body: some View {
        let miss = store.pick == .miss
        let tint = miss ? Theme.danger : Theme.live
        HStack(spacing: 9) {
            Image(systemName: miss ? "xmark.circle.fill" : "scope")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(miss ? "Not an iTerm pane" : "Click a terminal pane")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text("it docks straight away · right-click cancels")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 8).padding(.trailing, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(white: 0.11).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tint.opacity(0.75), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 9, y: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: store.pick)
    }
}

// MARK: - Docked sessions

struct SessionDock: View {
    @Environment(RelayStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("Sessions")
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(store.sessions) { s in
                        DockChip(session: s).transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                    Button { store.picker?.begin() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.text2)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    }
                    .buttonStyle(.plain)
                    .help("Pick up another session (⌥⌘P)")
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.top, 2)
    }
}

struct DockChip: View {
    @Environment(RelayStore.self) private var store
    let session: Session
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 5) {
            AgentGlyph(kind: session.kind, size: 16)
            Text(session.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(maxWidth: 120, alignment: .leading)
            StatusDot(session: session)
        }
        .padding(.leading, 5).padding(.trailing, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(targeted ? Theme.live : Theme.stroke, lineWidth: targeted ? 1.5 : 1))
        .opacity(session.gone ? 0.45 : 1)
        .scaleEffect(store.flashID == session.id ? 1.1 : 1)
        .contentShape(Rectangle())
        .onTapGesture { store.reveal(session.id) }
        .draggable(session.id) {
            HStack(spacing: 5) {
                AgentGlyph(kind: session.kind, size: 16)
                Text(session.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.15)))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let from = items.first, from != session.id, store.session(from) != nil else { return false }
            store.addFlow(a: from, b: session.id)
            return true
        } isTargeted: { t in withAnimation(.snappy) { targeted = t } }
        .contextMenu {
            Button("Reveal in iTerm") { store.reveal(session.id) }.disabled(session.isDemo)
            Button("New flow from here") { store.addFlow(a: session.id) }
            Divider()
            Button("Detach", role: .destructive) { store.detach(session.id) }
        }
        .help(session.gone ? "This pane was closed" : "Click to jump to this pane · drag onto a flow slot, or onto another session to start a flow")
    }
}

// MARK: - Shared bits

struct AgentGlyph: View {
    let kind: AgentKind
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().fill(kind.tint.opacity(0.2))
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.52, weight: .bold))
                .foregroundStyle(kind.tint)
        }
        .frame(width: size, height: size)
    }
}

struct StatusDot: View {
    let session: Session
    @State private var spin = false

    var body: some View {
        Group {
            if session.gone {
                Circle().strokeBorder(Theme.text3, lineWidth: 1)
            } else if session.working {
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(session.kind.tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
                    .onDisappear { spin = false }
            } else {
                Circle().fill(Theme.live.opacity(0.85))
            }
        }
        .frame(width: 7, height: 7)
        .help(session.gone ? "Closed" : (session.working ? "Working" : "Idle"))
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(hover || active ? Theme.text1 : Theme.text2)
                .frame(width: 22, height: 22)
                .background(Circle().fill(hover || active ? Color.white.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Theme.text3)
    }
}

struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(Theme.text3)
            .fixedSize()
    }
}

struct FieldBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.black.opacity(0.25))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
    }
}

// MARK: - Activity

struct ActivityFooter: View {
    @Environment(RelayStore.self) private var store
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    SectionLabel("Activity")
                    if let last = store.log.last {
                        LogLine(entry: last, compact: true)
                    } else {
                        Text("Nothing sent yet").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.text3)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.log.reversed()) { LogLine(entry: $0, compact: false) }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 10)
                }
                .frame(maxHeight: 150)
                .scrollIndicators(.never)
            }
        }
    }
}

struct LogLine: View {
    let entry: LogEntry
    let compact: Bool

    var body: some View {
        HStack(spacing: 6) {
            if !compact {
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.text3)
            }
            if let from = entry.from {
                AgentGlyph(kind: from, size: 13)
                if let to = entry.to {
                    Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text3)
                    AgentGlyph(kind: to, size: 13)
                }
            }
            Text(entry.text)
                .font(.system(size: 10.5))
                .foregroundStyle(entry.kind == .stop ? Theme.live : (entry.kind == .send ? Theme.text1 : Theme.text2))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
