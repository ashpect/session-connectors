import SwiftUI

// A flow reads top to bottom: session A, the lane(s) carrying answers between them, session B,
// then when to stop. One-way has a single lane down; Loop adds a lane back up with its own prompt.

struct FlowCard: View {
    @Environment(RelayStore.self) private var store
    let flowID: UUID
    let number: Int

    var body: some View {
        let flow = store.binding(flowID)
        let f = flow.wrappedValue
        let a = store.session(f.a), b = store.session(f.b)
        VStack(alignment: .leading, spacing: 0) {
            FlowHeader(flow: flow, number: number, a: a, b: b)
                .padding(.bottom, 10)
            SlotView(flow: flow, slot: .a)
            if let a, let b {
                Lanes(flow: flow, a: a, b: b)
            } else {
                PendingConnector()
            }
            SlotView(flow: flow, slot: .b)
            if let a, let b {
                FlowFooter(flow: flow, a: a, b: b)
                    .padding(.top, 12)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.fill))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(f.busy != nil ? Theme.live.opacity(0.4) : Theme.stroke)
        )
    }
}

struct FlowHeader: View {
    @Environment(RelayStore.self) private var store
    @Binding var flow: Flow
    let number: Int
    let a: Session?
    let b: Session?

    var body: some View {
        HStack(spacing: 8) {
            SectionLabel("Flow \(number)")
            if let a, let b {
                HStack(spacing: 3) {
                    AgentGlyph(kind: a.kind, size: 13)
                    Image(systemName: flow.loop ? "arrow.left.arrow.right" : "arrow.right")
                        .font(.system(size: 7.5, weight: .heavy))
                        .foregroundStyle(Theme.text3)
                    AgentGlyph(kind: b.kind, size: 13)
                }
            }
            Spacer()
            ModeToggle(loop: $flow.loop)
            Menu {
                Button("Swap top and bottom") { store.swap(flow.id) }.disabled(!flow.isComplete)
                Divider()
                Button("Delete flow", role: .destructive) { store.removeFlow(flow.id) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

struct ModeToggle: View {
    @Binding var loop: Bool
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            option("One-way", icon: "arrow.down", selected: !loop) { loop = false }
            option("Loop", icon: "arrow.triangle.2.circlepath", selected: loop) { loop = true }
        }
        .padding(2)
        .background(Capsule().fill(Color.black.opacity(0.28)))
        .overlay(Capsule().strokeBorder(Theme.stroke))
    }

    private func option(_ label: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { action() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
                Text(label).font(.system(size: 10.5, weight: .semibold))
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(selected ? Theme.text1 : Theme.text3)
            .background {
                if selected {
                    Capsule().fill(Color.white.opacity(0.15)).matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label == "Loop" ? "The second session's reply is sent back to the first" : "Answers only go down")
    }
}

// MARK: - Slots

struct SlotView: View {
    @Environment(RelayStore.self) private var store
    @Binding var flow: Flow
    let slot: Flow.Slot
    @State private var targeted = false

    var body: some View {
        Group {
            if let s = store.session(flow[slot]) {
                NodeCard(session: s, flow: $flow, slot: slot)
            } else {
                EmptySlot(flowID: flow.id, slot: slot, other: flow[slot == .a ? .b : .a])
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.live, lineWidth: 1.5).opacity(targeted ? 1 : 0))
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first, store.session(id) != nil else { return false }
            store.setSlot(flow.id, slot, to: id)
            return true
        } isTargeted: { t in withAnimation(.snappy) { targeted = t } }
    }
}

struct NodeCard: View {
    @Environment(RelayStore.self) private var store
    let session: Session
    @Binding var flow: Flow
    let slot: Flow.Slot
    @State private var renaming = false
    @State private var draft = ""
    @State private var ripple = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let tint = session.kind.tint
        let answering = flow.busy == session.id
        let busy = answering || session.working
        let peeking = store.peeking.contains(session.id)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                AgentGlyph(kind: session.kind, size: 30)
                    .background(
                        Circle()
                            .strokeBorder(tint, lineWidth: 1.5)
                            .scaleEffect(ripple ? 1.45 : 1)
                            .opacity(busy ? (ripple ? 0 : 0.9) : 0)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    if renaming {
                        TextField("Name", text: $draft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .focused($nameFocused)
                            .onSubmit(commitRename)
                            .onExitCommand { renaming = false }
                    } else {
                        Text(session.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .onTapGesture(count: 2, perform: startRename)
                            .help("Double-click to rename")
                    }
                    Text(subtitle(answering: answering))
                        .font(.system(size: 10.5))
                        .foregroundStyle(busy ? tint : Theme.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                IconButton(symbol: peeking ? "eye.fill" : "eye", help: "Peek at the pane", active: peeking) {
                    store.togglePeek(session.id)
                }
                Menu {
                    Button("Reveal in iTerm") { store.reveal(session.id) }.disabled(session.isDemo)
                    Button("Rename…", action: startRename)
                    Menu("Replace with") {
                        ForEach(store.sessions.filter { $0.id != session.id }) { s in
                            Button(s.title) { store.setSlot(flow.id, slot, to: s.id) }
                        }
                        Divider()
                        Button("Pick a pane…") { store.pick(into: flow.id, slot) }
                    }
                    Divider()
                    Button("Remove from flow") { store.setSlot(flow.id, slot, to: nil) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if !session.lastAnswer.isEmpty && !peeking {
                Text("\u{201C}\(Demo.gist(session.lastAnswer))\u{201D}")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .padding(.leading, 40)
                    .help(String(session.lastAnswer.prefix(600)))
            }
            if peeking {
                PaneMirror(session: session)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.17), tint.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(busy ? 0.65 : 0.25), lineWidth: 1)
        )
        .scaleEffect(store.flashID == session.id ? 1.025 : 1)
        .onAppear {
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { ripple = true }
        }
    }

    private func subtitle(answering: Bool) -> String {
        let state = session.gone ? "closed" : (answering ? "answering…" : (session.working ? "working…" : "idle"))
        return [session.kind.label, state, session.folder].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func startRename() {
        draft = session.title
        renaming = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename() {
        store.rename(session.id, to: draft)
        renaming = false
    }
}

struct EmptySlot: View {
    @Environment(RelayStore.self) private var store
    let flowID: UUID
    let slot: Flow.Slot
    let other: String?

    var body: some View {
        let candidates = store.sessions.filter { $0.id != other }
        let waiting = store.pickTarget?.flow == flowID && store.pickTarget?.slot == slot
        HStack(spacing: 10) {
            ZStack {
                Circle().strokeBorder(waiting ? Theme.live : Theme.text3.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Image(systemName: waiting ? "scope" : "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(waiting ? Theme.live : Theme.text2)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(waiting ? "Now click a pane in iTerm" : (slot == .a ? "Pick the first session" : "Pick where its answer goes"))
                    .font(.system(size: 12.5, weight: .semibold))
                Text(waiting ? "right-click cancels" : "Click here, then click a pane · or drag a session in")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 4)
            if !candidates.isEmpty, !waiting {
                Menu {
                    ForEach(candidates) { s in
                        Button(s.title) { store.setSlot(flowID, slot, to: s.id) }
                    }
                } label: {
                    Text("Choose").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(Theme.text2)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.12)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(waiting ? Theme.live.opacity(0.7) : Theme.text3.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .contentShape(Rectangle())
        .onTapGesture { store.pick(into: flowID, slot) }
    }
}

struct PaneMirror: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            let lines = session.screenLines
            if lines.isEmpty {
                Text(session.gone ? "This pane was closed." : "Reading the pane…").foregroundStyle(Theme.text3)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line).lineLimit(1).truncationMode(.tail)
                }
            }
        }
        .font(.system(size: 9.5, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.7))
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .bottomLeading)
        .padding(.horizontal, 9).padding(.bottom, 9).padding(.top, 20)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.35)))
        .overlay(alignment: .topTrailing) {
            Text(session.isDemo ? "DEMO" : "LIVE")
                .font(.system(size: 8.5, weight: .bold)).tracking(0.8)
                .foregroundStyle(session.isDemo ? Theme.text3 : Theme.live.opacity(0.8))
                .padding(7)
        }
    }
}

// MARK: - Lanes

struct Lanes: View {
    @Environment(RelayStore.self) private var store
    @Binding var flow: Flow
    let a: Session
    let b: Session

    var body: some View {
        let live = flow.enabled && flow.halted == nil && store.running
        HStack(alignment: .top, spacing: 10) {
            Lane(direction: .down, from: a, to: b, template: $flow.forward, pulse: flow.forwardPulse, live: live)
            if flow.loop {
                Lane(direction: .up, from: b, to: a, template: $flow.back, pulse: flow.backPulse, live: live)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                LoopGhost(from: b, to: a) { flow.loop = true }
                    .transition(.opacity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
    }
}

struct Lane: View {
    enum Direction { case down, up }
    let direction: Direction
    let from: Session
    let to: Session
    @Binding var template: String
    let pulse: Int
    let live: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            LaneLine(direction: direction, from: from.kind.tint, to: to.kind.tint, pulse: pulse, live: live)
                .frame(width: 12)
            PromptBubble(from: from, to: to, template: $template)
                .padding(.vertical, 9)
        }
        .frame(maxWidth: .infinity)
    }
}

struct LaneLine: View {
    let direction: Lane.Direction
    let from: Color
    let to: Color
    let pulse: Int
    let live: Bool
    @State private var progress: CGFloat = -1

    var body: some View {
        GeometryReader { g in
            let h = g.size.height, down = direction == .down
            ZStack(alignment: .top) {
                Capsule()
                    .fill(LinearGradient(colors: [from.opacity(live ? 0.9 : 0.35), to.opacity(live ? 0.9 : 0.35)],
                                         startPoint: down ? .top : .bottom, endPoint: down ? .bottom : .top))
                    .frame(width: 2, height: max(0, h - 4))
                    .offset(y: 2)
                Image(systemName: down ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(to.opacity(live ? 1 : 0.4))
                    .offset(y: down ? h - 9 : -2)
                if progress >= 0 {
                    Circle()
                        .fill(.white)
                        .frame(width: 7, height: 7)
                        .shadow(color: to, radius: 5)
                        .offset(y: (down ? progress : 1 - progress) * (h - 7))
                }
            }
            .frame(width: g.size.width)
        }
        .onChange(of: pulse) {
            progress = 0
            withAnimation(.easeInOut(duration: 0.8)) { progress = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { progress = -1 }
        }
    }
}

struct PromptBubble: View {
    let from: Session
    let to: Session
    @Binding var template: String
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("\(from.kind.label) → \(to.kind.label)".uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(Theme.text3)
                Spacer(minLength: 2)
                Image(systemName: editing ? "checkmark" : "pencil")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(editing ? Theme.live : Theme.text3)
                    .onTapGesture { editing ? finish() : begin() }
            }
            if editing {
                TextField("Instructions to send with the answer…", text: $template, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .lineLimit(2...8)
                    .focused($focused)
                HStack(spacing: 10) {
                    Button("Insert answer here") { template += (template.isEmpty ? "" : "\n\n") + "{answer}" }
                        .buttonStyle(.plain)
                        .foregroundStyle(from.kind.tint)
                    Spacer()
                    Button("Done", action: finish).buttonStyle(.plain).foregroundStyle(Theme.text1)
                }
                .font(.system(size: 10.5, weight: .medium))
                Text("No {answer}? The answer goes at the end.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.text3)
            } else {
                Text(preview)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.24)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(editing ? to.kind.tint.opacity(0.6) : Theme.stroke)
        )
        .contentShape(Rectangle())
        .onTapGesture { if !editing { begin() } }
        .help(editing ? "" : "Click to edit what gets sent")
    }

    /// The prompt with the answer shown as a colored token where it'll be placed.
    private var preview: AttributedString {
        var token = AttributedString(" \(from.kind.label)'s answer ")
        token.foregroundColor = from.kind.tint
        token.backgroundColor = from.kind.tint.opacity(0.17)
        token.font = .system(size: 11, weight: .semibold)

        let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            var rest = AttributedString("  as-is")
            rest.foregroundColor = Theme.text3
            return token + rest
        }
        let parts = t.components(separatedBy: "{answer}")
        var out = AttributedString()
        for (i, part) in parts.enumerated() {
            out += AttributedString(part)
            if i < parts.count - 1 { out += token }
        }
        if parts.count == 1 { out += AttributedString("\n") + token }
        return out
    }

    private func begin() {
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    private func finish() {
        editing = false
        focused = false
    }
}

struct LoopGhost: View {
    let from: Session
    let to: Session
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { action() }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 14, weight: .medium))
                Text("Loop back").font(.system(size: 11, weight: .semibold))
                Text("Send \(from.kind.label)'s reply back up to \(to.kind.label)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.text3)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(hover ? Theme.text1 : Theme.text2)
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.text3.opacity(hover ? 0.6 : 0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .frame(width: 124)
        .padding(.vertical, 9)
    }
}

/// Between two slots before both are filled.
struct PendingConnector: View {
    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.text3.opacity(0.5))
                    .frame(width: 1.5, height: 20)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .heavy)).foregroundStyle(Theme.text3)
            }
            .frame(width: 12)
            Text("its answer goes to")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Stop rules + run

struct FlowFooter: View {
    @Environment(RelayStore.self) private var store
    @Binding var flow: Flow
    let a: Session
    let b: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack(spacing: 6) {
                FieldLabel(text: "Stop when")
                if flow.loop {
                    Menu {
                        Button("either says") { flow.stopWatch = .either }
                        Button("\(a.kind.label) says") { flow.stopWatch = .a }
                        Button("\(b.kind.label) says") { flow.stopWatch = .b }
                    } label: {
                        Text(watchLabel).font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                } else {
                    Text(a.kind.label).font(.system(size: 11, weight: .semibold))
                }
                FieldLabel(text: "says")
                TextField("LGTM", text: $flow.stopPhrase)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(FieldBackground())
                    .frame(maxWidth: 110)
                Spacer(minLength: 4)
                Menu {
                    ForEach([3, 5, 10, 20, 50], id: \.self) { n in
                        Button("\(n) rounds") { flow.maxRounds = n }
                    }
                } label: {
                    Text("max \(flow.maxRounds)").font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(Theme.text2)
                .help("Stop after this many rounds, whatever they say")
            }
            HStack(spacing: 8) {
                FlowStatus(flow: flow, a: a, b: b)
                Spacer(minLength: 6)
                RunButton(flow: flow)
            }
        }
    }

    private var watchLabel: String {
        switch flow.stopWatch {
        case .either: "either"
        case .a: a.kind.label
        case .b: b.kind.label
        }
    }
}

struct FlowStatus: View {
    @Environment(RelayStore.self) private var store
    let flow: Flow
    let a: Session
    let b: Session

    var body: some View {
        let busy = store.session(flow.busy)
        let (icon, text, color): (String, String, Color) =
            if !store.running { ("pause.circle.fill", "Relay is paused", Theme.paused) }
            else if let halted = flow.halted { ("checkmark.seal.fill", "Done in \(flow.rounds) round\(flow.rounds == 1 ? "" : "s") · \(halted)", Theme.live) }
            else if let busy { ("ellipsis.circle.fill", "Round \(flow.rounds) · \(busy.kind.label) is replying", busy.kind.tint) }
            else if flow.enabled && flow.rounds > 0 { ("arrow.triangle.2.circlepath", "Round \(flow.rounds) · waiting for the next answer", Theme.text2) }
            else if flow.enabled { ("dot.radiowaves.right", "On · \(a.kind.label)'s next answer goes to \(b.kind.label)", Theme.live) }
            else if flow.rounds > 0 { ("stop.circle", "Stopped after \(flow.rounds) round\(flow.rounds == 1 ? "" : "s")", Theme.text3) }
            else { ("circle.dashed", a.lastAnswer.isEmpty ? "Off · Start, then \(a.kind.label)'s next answer goes down" : "Off · Start sends \(a.kind.label)'s latest answer", Theme.text3) }
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
            if busy?.isDemo == true {
                Text("DEMO")
                    .font(.system(size: 8, weight: .bold)).tracking(0.6)
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().strokeBorder(Theme.text3.opacity(0.5)))
                    .help("Demo sessions answer with canned replies")
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(color)
    }
}

struct RunButton: View {
    @Environment(RelayStore.self) private var store
    let flow: Flow

    var body: some View {
        let running = flow.enabled && flow.halted == nil
        Button {
            running ? store.stop(flow.id) : store.start(flow.id)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: running ? "stop.fill" : (flow.rounds > 0 || flow.halted != nil ? "arrow.clockwise" : "play.fill"))
                    .font(.system(size: 9, weight: .bold))
                Text(running ? "Stop" : (flow.rounds > 0 || flow.halted != nil ? "Run again" : "Start"))
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(running ? Theme.text1 : Color.black.opacity(0.85))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(running ? Color.white.opacity(0.14) : Theme.live))
        }
        .buttonStyle(.plain)
        .disabled(!store.running)
        .help(running ? "Stop this flow" : "Turn the flow on: answers start moving between the sessions")
    }
}

struct NewFlowButton: View {
    @Environment(RelayStore.self) private var store

    var body: some View {
        if store.flows.allSatisfy(\.isComplete) {
            Button { store.addFlow() } label: {
                Label("New flow", systemImage: "plus")
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text2)
        }
    }
}
