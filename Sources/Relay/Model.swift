import SwiftUI
import Observation

enum AgentKind: String, Codable {
    case claude, codex, shell

    var label: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .shell: "Shell"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "hexagon"
        case .shell: "terminal"
        }
    }

    var tint: Color {
        switch self {
        case .claude: Theme.claude
        case .codex: Theme.codex
        case .shell: Theme.shell
        }
    }

    // iTerm's tab title ends in "(claude)" / "(codex)"; Claude Code's process title is its version number.
    static func detect(name: String, job: String) -> AgentKind {
        let n = name.lowercased(), j = job.lowercased()
        if n.hasSuffix("(claude)") || j == "claude" || j.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil {
            return .claude
        }
        if n.hasSuffix("(codex)") || j.contains("codex") { return .codex }
        return .shell
    }
}

struct Session: Identifiable, Equatable, Codable {
    let id: String          // iTerm session id (the UUID part of $ITERM_SESSION_ID)
    var name: String
    var kind: AgentKind
    var tty = ""
    var path = ""
    var screen = ""
    var working = false
    var gone = false
    var isDemo = false
    var alias = ""
    var lastAnswer = ""     // from the agent's most recent Stop hook
    var agentSession = ""   // Claude session id / Codex thread id, once a hook has reported it

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, tty, path, isDemo, alias, lastAnswer, agentSession
    }

    init(id: String, name: String, kind: AgentKind, tty: String = "", path: String = "", screen: String = "",
         working: Bool = false, isDemo: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.tty = tty
        self.path = path
        self.screen = screen
        self.working = working
        self.isDemo = isDemo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(AgentKind.self, forKey: .kind)
        tty = try c.decodeIfPresent(String.self, forKey: .tty) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        isDemo = try c.decodeIfPresent(Bool.self, forKey: .isDemo) ?? false
        alias = try c.decodeIfPresent(String.self, forKey: .alias) ?? ""
        lastAnswer = try c.decodeIfPresent(String.self, forKey: .lastAnswer) ?? ""
        agentSession = try c.decodeIfPresent(String.self, forKey: .agentSession) ?? ""
    }

    /// Your rename if you gave one, else the tab title without iTerm's status glyph and "(claude)" suffix.
    var title: String {
        if !alias.isEmpty { return alias }
        var t = name.trimmingCharacters(in: .whitespaces)
        if let first = t.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first), t.dropFirst().hasPrefix(" ") {
            t = String(t.dropFirst(2))
        }
        for suffix in [" (claude)", " (codex)"] where t.lowercased().hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        return t.isEmpty ? kind.label : t
    }

    var folder: String { (path as NSString).lastPathComponent }

    var ttyName: String { (tty as NSString).lastPathComponent }

    var screenLines: [String] {
        var lines = screen.components(separatedBy: "\n").map { line in
            var l = Substring(line)
            while let last = l.last, last.isWhitespace { l = l.dropLast() }
            return String(l)
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return Array(lines.suffix(12))
    }

    static func isWorking(name: String, screen: String) -> Bool {
        if let first = name.first, "◐◓◑◒⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏".contains(first) { return true }
        return screen.suffix(3000).range(of: "esc to interrupt", options: .caseInsensitive) != nil
    }
}

/// One session's answer becomes another session's prompt. With `loop` on, the reply comes back too.
struct Flow: Identifiable, Equatable, Codable {
    enum Slot { case a, b }
    enum Watch: String, Codable { case either, a, b }

    var id = UUID()
    var a: String?
    var b: String?
    var forward = ""          // prompt wrapped around A's answer on its way to B
    var back = ""             // prompt wrapped around B's answer on its way back to A
    var loop = false
    var stopPhrase = ""
    var stopWatch = Watch.either
    var maxRounds = 10
    var enabled = false       // on after Start; answers only move while a flow is on

    var rounds = 0            // A → B sends in this run
    var backSends = 0
    var halted: String?
    var busy: String?         // the session currently answering something this flow sent it
    var pendingUntil: Date?   // an answer is waiting out the send delay until then…
    var pendingTo: String?    // …on its way to this session
    var forwardPulse = 0
    var backPulse = 0

    private enum CodingKeys: String, CodingKey {
        case id, a, b, forward, back, loop, stopPhrase, stopWatch, maxRounds
    }

    var isComplete: Bool { a != nil && b != nil }

    subscript(slot: Slot) -> String? {
        get { slot == .a ? a : b }
        set { if slot == .a { a = newValue } else { b = newValue } }
    }

    /// An empty prompt sends the answer as-is; `{answer}` places it; otherwise it goes at the end.
    static func compose(_ template: String, answer: String) -> String {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return answer }
        if t.contains("{answer}") { return t.replacingOccurrences(of: "{answer}", with: answer) }
        return t + "\n\n" + answer
    }
}

struct LogEntry: Identifiable {
    enum Kind { case send, stop, info }
    let id = UUID()
    let date = Date()
    let kind: Kind
    var from: AgentKind?
    var to: AgentKind?
    let text: String
}

enum PickState: Equatable {
    case idle, armed, miss
}

@Observable
final class RelayStore {
    var sessions: [Session] = []
    var flows: [Flow] = [Flow()]
    var log: [LogEntry] = []
    var running = true
    var pick: PickState = .idle
    var pickTarget: (flow: UUID, slot: Flow.Slot)?
    var fadeWhenIdle = true
    var opacity = 1.0
    var notice: String?
    var flashID: String?
    var peeking: Set<String> = []
    var inFlight = 0
    var showingSettings = false
    var sendDelay = 0.0       // seconds to wait after an answer before pasting it into the next session

    var simulating: Bool { inFlight > 0 }

    @ObservationIgnored weak var picker: PickController?
    @ObservationIgnored var togglePanel: (() -> Void)?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var saveTimer: Timer?
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var simTurns: [String: Int] = [:]
    @ObservationIgnored private var threadPanes: [String: String] = [:]    // Codex thread id → pane
    @ObservationIgnored private var awaiting: [String: (text: String, at: Date)] = [:]  // pasted, not yet confirmed
    @ObservationIgnored private var outbox: [String: [String]] = [:]       // waiting for a busy pane
    @ObservationIgnored private var lastStop: [String: String] = [:]
    @ObservationIgnored private var lastSaved = Data()
    @ObservationIgnored private var pendingWork: [UUID: () -> Void] = [:]
    @ObservationIgnored private var persists = false   // only the real app (not --snapshot renders) writes state

    func session(_ id: String?) -> Session? { id.flatMap { id in sessions.first { $0.id == id } } }

    func index(of flowID: UUID) -> Int? { flows.firstIndex { $0.id == flowID } }

    /// A binding that survives the flow being deleted mid-animation.
    func binding(_ flowID: UUID) -> Binding<Flow> {
        Binding(
            get: { self.flows.first { $0.id == flowID } ?? Flow() },
            set: { value in if let i = self.index(of: flowID) { self.flows[i] = value } }
        )
    }

    // MARK: Sessions

    /// Docks a picked pane. It fills the slot you picked for, or else the first open slot.
    func dock(_ s: Session) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            if let i = sessions.firstIndex(where: { $0.id == s.id }) {
                var updated = s
                updated.alias = sessions[i].alias
                updated.lastAnswer = sessions[i].lastAnswer
                updated.agentSession = sessions[i].agentSession
                sessions[i] = updated
            } else {
                sessions.append(s)
                note(.info, from: s.kind, "Docked \(s.title)")
            }
            if let target = pickTarget, let i = index(of: target.flow) {
                flows[i][target.slot] = s.id
            } else if !flows.contains(where: { $0.a == s.id || $0.b == s.id }) {
                if let i = flows.firstIndex(where: { $0.a == nil }) {
                    flows[i].a = s.id
                } else if let i = flows.firstIndex(where: { $0.b == nil && $0.a != s.id }) {
                    flows[i].b = s.id
                }
            }
            pickTarget = nil
        }
        flash(s.id)
    }

    func detach(_ id: String) {
        withAnimation(.snappy) {
            sessions.removeAll { $0.id == id }
            for i in flows.indices {
                if flows[i].a == id { flows[i].a = nil }
                if flows[i].b == id { flows[i].b = nil }
            }
            peeking.remove(id)
        }
    }

    func rename(_ id: String, to alias: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func reveal(_ id: String) {
        guard session(id)?.isDemo == false else { return }
        ITerm.reveal(id: id)
    }

    func togglePeek(_ id: String) {
        withAnimation(.snappy) {
            if peeking.contains(id) { peeking.remove(id) } else { peeking.insert(id) }
        }
    }

    func flash(_ id: String) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { flashID = id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            withAnimation(.easeOut(duration: 0.3)) { if self?.flashID == id { self?.flashID = nil } }
        }
    }

    /// Pick a pane straight into one side of a flow.
    func pick(into flowID: UUID, _ slot: Flow.Slot) {
        if pick != .idle { picker?.cancel() }
        pickTarget = (flowID, slot)
        picker?.begin()
    }

    // MARK: Flows

    func addFlow(a: String? = nil, b: String? = nil) {
        withAnimation(.snappy) { flows.append(Flow(a: a, b: b)) }
    }

    func removeFlow(_ id: UUID) {
        withAnimation(.snappy) { flows.removeAll { $0.id == id } }
    }

    func setSlot(_ flowID: UUID, _ slot: Flow.Slot, to sessionID: String?) {
        guard let i = index(of: flowID) else { return }
        withAnimation(.snappy) { flows[i][slot] = sessionID }
    }

    func swap(_ flowID: UUID) {
        guard let i = index(of: flowID) else { return }
        withAnimation(.snappy) {
            let f = flows[i]
            flows[i].a = f.b
            flows[i].b = f.a
            flows[i].forward = f.back
            flows[i].back = f.forward
            flows[i].stopWatch = f.stopWatch == .a ? .b : (f.stopWatch == .b ? .a : .either)
        }
    }

    private func resetRun(_ i: Int) {
        flows[i].rounds = 0
        flows[i].backSends = 0
        flows[i].halted = nil
        flows[i].busy = nil
        flows[i].pendingUntil = nil
        flows[i].pendingTo = nil
        pendingWork[flows[i].id] = nil
    }

    /// Turns the flow on. If A has an answer already (and isn't mid-turn), it goes down right away;
    /// otherwise A's next answer does.
    func start(_ flowID: UUID) {
        guard let i = index(of: flowID), let a = flows[i].a, let src = session(a), let dst = session(flows[i].b) else { return }
        guard running else { notice = "Relay is paused. Press Paused to go live."; return }
        withAnimation(.snappy) {
            resetRun(i)
            flows[i].enabled = true
        }
        simTurns = [:]
        if src.isDemo {
            simTurns[a] = 1
            note(.info, from: src.kind, "Started · demo run with canned replies")
            sessionFinished(a, answer: Demo.reply(for: src.kind, turn: 1), only: flowID)
        } else if !src.lastAnswer.isEmpty && !src.working {
            note(.info, from: src.kind, to: dst.kind, "Started · sending \(src.kind.label)'s latest answer")
            sessionFinished(a, answer: src.lastAnswer, only: flowID)
        } else {
            note(.info, from: src.kind, to: dst.kind, "On · \(src.kind.label)'s next answer goes to \(dst.kind.label)")
        }
    }

    /// Turns the flow on without sending anything now; the first session's next answer starts it.
    func arm(_ flowID: UUID) {
        guard let i = index(of: flowID), let src = session(flows[i].a), let dst = session(flows[i].b) else { return }
        withAnimation(.snappy) {
            resetRun(i)
            flows[i].enabled = true
        }
        note(.info, from: src.kind, to: dst.kind, "On · \(src.kind.label)'s next answer goes to \(dst.kind.label)")
    }

    func stop(_ flowID: UUID) {
        guard let i = index(of: flowID) else { return }
        withAnimation(.snappy) {
            flows[i].enabled = false
            flows[i].busy = nil
            flows[i].pendingUntil = nil
            flows[i].pendingTo = nil
        }
        pendingWork[flowID] = nil
        note(.info, "Stopped a flow")
    }

    // MARK: Engine

    /// A session finished a turn with `answer`: every running flow it feeds passes the answer on.
    func sessionFinished(_ id: String, answer: String, only flowID: UUID? = nil) {
        guard running else { return }
        for i in flows.indices where flowID == nil || flows[i].id == flowID {
            let f = flows[i]
            guard f.enabled, f.halted == nil, let a = f.a, let b = f.b else { continue }
            if a == id {
                deliver(i, from: a, to: b, forward: true, answer: answer)
            } else if f.loop, b == id {
                deliver(i, from: b, to: a, forward: false, answer: answer)
            }
        }
    }

    private func deliver(_ i: Int, from: String, to: String, forward: Bool, answer: String) {
        let f = flows[i]
        guard let src = session(from), let dst = session(to) else { return }

        let watching = f.stopWatch == .either || (f.stopWatch == .a) == forward || !f.loop
        if !f.stopPhrase.isEmpty, watching, answer.range(of: f.stopPhrase, options: .caseInsensitive) != nil {
            withAnimation(.snappy) {
                flows[i].halted = "\(src.kind.label) said \u{201C}\(f.stopPhrase)\u{201D}"
                flows[i].busy = nil
            }
            note(.stop, from: src.kind, "\(src.kind.label) said \u{201C}\(f.stopPhrase)\u{201D} · done in \(f.rounds) round\(f.rounds == 1 ? "" : "s")")
            return
        }
        if forward, f.rounds >= f.maxRounds {
            withAnimation(.snappy) {
                flows[i].halted = "Hit the \(f.maxRounds)-round limit"
                flows[i].busy = nil
            }
            note(.stop, from: src.kind, "Stopped after \(f.maxRounds) rounds")
            return
        }

        let message = Flow.compose(forward ? f.forward : f.back, answer: answer)
        let flowID = f.id
        let work = { [weak self] in
            guard let self, let j = index(of: flowID), flows[j].enabled, flows[j].halted == nil, running else { return }
            pendingWork[flowID] = nil
            withAnimation(.snappy) {
                self.flows[j].pendingUntil = nil
                self.flows[j].pendingTo = nil
            }
            commit(j, from: src, to: dst, forward: forward, answer: answer, message: message)
        }
        guard sendDelay > 0 else { return work() }

        // Wait out the delay first. A newer answer replaces the waiting one; Stop cancels it.
        let fire = Date().addingTimeInterval(sendDelay)
        pendingWork[flowID] = work
        withAnimation(.snappy) {
            flows[i].pendingUntil = fire
            flows[i].pendingTo = to
        }
        note(.info, from: src.kind, to: dst.kind, "Sending to \(dst.kind.label) in \(Int(sendDelay))s")
        DispatchQueue.main.asyncAfter(deadline: .now() + sendDelay) { [weak self] in
            guard let self, let j = index(of: flowID), flows[j].pendingUntil == fire else { return }
            pendingWork[flowID]?()
        }
    }

    /// Skip the rest of the send delay.
    func sendNow(_ flowID: UUID) {
        pendingWork[flowID]?()
    }

    private func commit(_ i: Int, from src: Session, to dst: Session, forward: Bool, answer: String, message: String) {
        if forward {
            flows[i].rounds += 1
            flows[i].forwardPulse += 1
        } else {
            flows[i].backSends += 1
            flows[i].backPulse += 1
        }
        note(.send, from: src.kind, to: dst.kind, "\(Demo.gist(answer)) · \(message.count.formatted()) chars")
        withAnimation(.snappy) { flows[i].busy = dst.id }
        flash(dst.id)
        if dst.isDemo {
            simulateReply(from: dst.id, flowID: flows[i].id)
        } else {
            send(message, to: dst.id)
        }
    }

    /// Pastes into the pane now, or once it finishes what it's doing.
    private func send(_ text: String, to pane: String) {
        if let s = session(pane), s.working || awaiting[pane] != nil {
            outbox[pane, default: []].append(text)
            note(.info, to: s.kind, "\(s.kind.label) is busy, message queued")
            return
        }
        paste(text, into: pane)
    }

    private func paste(_ text: String, into pane: String) {
        let sentAt = Date()
        awaiting[pane] = (text, sentAt)
        setWorking(pane, true)
        ITerm.paste(id: pane, text: text) { [weak self] result in
            guard let self, case .failure(let e) = result else { return }
            awaiting[pane] = nil
            setWorking(pane, false)
            haltFlows(busyWith: pane, reason: "Couldn't send: \(e.message)")
        }
        // If the agent never reports the prompt, say so instead of looking busy forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, awaiting[pane]?.at == sentAt else { return }
            awaiting[pane] = nil
            let name = session(pane)?.kind.label ?? "The pane"
            notice = "Sent to \(name), but it hasn't confirmed receiving it. Check that pane, and that Relay's hooks are trusted there."
        }
    }

    private func flushOutbox(_ pane: String) {
        guard var queue = outbox[pane], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        outbox[pane] = queue.isEmpty ? nil : queue
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.paste(next, into: pane) }
    }

    private func haltFlows(busyWith pane: String, reason: String) {
        for i in flows.indices where flows[i].busy == pane {
            withAnimation(.snappy) {
                flows[i].halted = reason
                flows[i].busy = nil
            }
        }
        notice = reason
    }

    // MARK: Hook events

    /// Claude Code / Codex told us (through relay-hook) that a prompt went in or a turn ended.
    func handle(_ e: HookEvent) {
        resolvePane(e) { [weak self] pane in
            Self.debug("hook \(e.agent) \(e.event) session=\(e.session.prefix(8)) pane=\(e.pane.isEmpty ? "-" : String(e.pane.prefix(8))) → \(pane.map { String($0.prefix(8)) } ?? "unmatched")")
            guard let self, let pane, let i = sessions.firstIndex(where: { $0.id == pane }) else { return }
            if !e.session.isEmpty { sessions[i].agentSession = e.session }
            switch e.event {
            case "UserPromptSubmit":
                awaiting[pane] = nil
                withAnimation(.snappy) { self.sessions[i].working = true }
            case "Stop":
                let key = e.turn.isEmpty ? String(e.answer.hashValue) : e.turn
                guard lastStop[pane] != key else { return }
                lastStop[pane] = key
                awaiting[pane] = nil
                withAnimation(.snappy) { self.sessions[i].working = false }
                if !e.answer.isEmpty { sessions[i].lastAnswer = e.answer }
                for j in flows.indices where flows[j].busy == pane {
                    withAnimation(.snappy) { self.flows[j].busy = nil }
                }
                if !e.answer.isEmpty { sessionFinished(pane, answer: e.answer) }
                flushOutbox(pane)
            default:
                break
            }
        }
    }

    /// Which docked pane an event belongs to. Claude's hooks run inside the pane, so they carry its
    /// id. Codex usually runs turns in a background daemon, so a Codex thread is matched to its pane
    /// (by the text we pasted, the folder, or what's on screen) and the match is remembered.
    private func resolvePane(_ e: HookEvent, completion: @escaping (String?) -> Void) {
        if e.agent != "codex", !e.pane.isEmpty { return completion(e.pane) }
        func remember(_ pane: String?) {
            if let pane, !e.session.isEmpty { threadPanes[e.session] = pane }
            completion(pane)
        }
        // We typed this exact prompt into a pane a moment ago: strongest evidence there is.
        if e.event == "UserPromptSubmit", !e.prompt.isEmpty {
            let key = String(Self.normalize(e.prompt).prefix(160))
            if let hit = awaiting.first(where: { String(Self.normalize($0.value.text).prefix(160)) == key }) {
                return remember(hit.key)
            }
        }
        if let p = threadPanes[e.session] { return completion(p) }
        if !e.pane.isEmpty, session(e.pane)?.kind == .codex { return remember(e.pane) }
        if !e.tty.isEmpty, let s = sessions.first(where: { $0.tty == e.tty }) { return remember(s.id) }

        // Look across every iTerm pane (docked or not) running this agent in this folder.
        // A finished answer's end is what's visible on screen; a fresh prompt's start is.
        let lastLine = e.answer.split(whereSeparator: \.isNewline).last { !Self.normalize(String($0)).isEmpty }.map(String.init) ?? ""
        let snippet = e.event == "Stop"
            ? String(Self.normalize(lastLine).suffix(40))
            : String(Self.normalize(e.prompt).prefix(40))
        let kind = AgentKind(rawValue: e.agent) ?? .shell
        ITerm.allSessions { [weak self] result in
            guard let self, case .success(let all) = result else { return completion(nil) }
            let here = all.filter { AgentKind.detect(name: $0.name, job: $0.job) == kind && Self.samePath($0.path, e.cwd) }
            var match: Snapshot?
            if here.count == 1 {
                match = here[0]
            } else if !snippet.isEmpty {
                let hits = here.filter { Self.normalize($0.contents).contains(snippet) }
                if hits.count == 1 { match = hits[0] }
            }
            // Only claim the thread if the pane it matched is one you docked.
            guard let match, sessions.contains(where: { $0.id == match.id }) else {
                if let match { threadPanes[e.session] = match.id }
                return completion(nil)
            }
            remember(match.id)
        }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"[*_`#>•›⏺│|\-]"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func samePath(_ a: String, _ b: String) -> Bool {
        func clean(_ p: String) -> String {
            var p = (p as NSString).resolvingSymlinksInPath.lowercased()
            if p.hasPrefix("/private/") { p.removeFirst("/private".count) }
            while p.hasSuffix("/") && p.count > 1 { p.removeLast() }
            return p
        }
        return !a.isEmpty && !b.isEmpty && clean(a) == clean(b)
    }

    // MARK: Demo replies

    /// Demo sessions only: the target "works" for a moment, then answers with a canned reply.
    private func simulateReply(from id: String, flowID: UUID) {
        inFlight += 1
        setWorking(id, true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self else { return }
            inFlight -= 1
            setWorking(id, false)
            guard let i = index(of: flowID), flows[i].enabled, flows[i].halted == nil, flows[i].busy == id,
                  let s = session(id) else { return }
            let turn = (simTurns[id] ?? 0) + 1
            simTurns[id] = turn
            let reply = Demo.reply(for: s.kind, turn: turn)
            if let j = sessions.firstIndex(where: { $0.id == id }) {
                sessions[j].screen = Demo.screen(for: s.kind, reply: reply)
                sessions[j].lastAnswer = reply
            }
            withAnimation(.snappy) { self.flows[i].busy = nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.sessionFinished(id, answer: reply) }
        }
    }

    private func setWorking(_ id: String, _ working: Bool) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy) { sessions[i].working = working }
    }

    func note(_ kind: LogEntry.Kind, from: AgentKind? = nil, to: AgentKind? = nil, _ text: String) {
        Self.debug("[\(kind)] \(from?.label ?? "")\(to.map { " → " + $0.label } ?? "") \(text)")
        log.append(LogEntry(kind: kind, from: from, to: to, text: text))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    /// With ~/.relay/debug present, Relay logs what it hears and does to ~/.relay/relay.log.
    static func debug(_ line: String) {
        guard FileManager.default.fileExists(atPath: RelayPaths.dir + "/debug") else { return }
        let path = RelayPaths.dir + "/relay.log"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        h.seekToEndOfFile()
        h.write(Data("\(Date().formatted(.dateTime.hour().minute().second())) \(line)\n".utf8))
        try? h.close()
    }

    // MARK: Live mirror of docked iTerm panes

    func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let ids = sessions.filter { !$0.isDemo && !$0.gone }.map(\.id)
        guard !ids.isEmpty, !polling, ITerm.isRunning else { return }
        polling = true
        ITerm.snapshots(ids: ids) { [weak self] result in
            guard let self else { return }
            polling = false
            switch result {
            case .failure(let e):
                notice = e.message
            case .success(let snaps):
                for i in sessions.indices where ids.contains(sessions[i].id) {
                    var s = sessions[i]
                    if let snap = snaps[s.id] {
                        s.name = snap.name
                        s.kind = AgentKind.detect(name: snap.name, job: snap.job)
                        s.tty = snap.tty
                        s.path = snap.path
                        s.screen = snap.contents
                        // Once hooks report for a session they own its busy state; until then, guess from the screen.
                        if s.agentSession.isEmpty && awaiting[s.id] == nil {
                            s.working = Session.isWorking(name: snap.name, screen: snap.contents)
                        }
                    } else {
                        s.gone = true
                        s.working = false
                    }
                    if s != sessions[i] { sessions[i] = s }
                }
            }
        }
    }

    // MARK: Saved state

    private struct Saved: Codable {
        var sessions: [Session]
        var flows: [Flow]
        var threadPanes: [String: String]
        var sendDelay: Double?
        var fadeWhenIdle: Bool?
        var opacity: Double?
    }

    func load() {
        guard let data = FileManager.default.contents(atPath: RelayPaths.state),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        sessions = saved.sessions
        flows = saved.flows.isEmpty ? [Flow()] : saved.flows
        threadPanes = saved.threadPanes
        sendDelay = saved.sendDelay ?? 0
        fadeWhenIdle = saved.fadeWhenIdle ?? true
        opacity = saved.opacity ?? 1
        lastSaved = data
    }

    func startSaving() {
        persists = true
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.save() }
    }

    func save() {
        guard persists else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let saved = Saved(sessions: sessions, flows: flows, threadPanes: threadPanes,
                          sendDelay: sendDelay, fadeWhenIdle: fadeWhenIdle, opacity: opacity)
        guard let data = try? encoder.encode(saved),
              data != lastSaved else { return }
        try? FileManager.default.createDirectory(atPath: RelayPaths.dir, withIntermediateDirectories: true)
        if FileManager.default.createFile(atPath: RelayPaths.state, contents: data) { lastSaved = data }
    }

    static func hookInstalled(_ agent: AgentKind) -> Bool {
        let path = NSHomeDirectory() + (agent == .claude ? "/.claude/settings.json" : "/.codex/hooks.json")
        return (try? String(contentsOfFile: path, encoding: .utf8))?.contains(RelayPaths.hook) ?? false
    }

    /// Relay only hears about turns through hooks in Claude Code and Codex; say so if they're missing.
    func checkHooks() {
        var missing: [String] = []
        if !Self.hookInstalled(.claude) { missing.append("Claude Code") }
        if !Self.hookInstalled(.codex) { missing.append("Codex") }
        if !missing.isEmpty {
            notice = "Relay's hooks aren't installed in \(missing.joined(separator: " or ")), so it can't hear when their turns end."
        }
    }

    // MARK: Demo

    func loadDemo() {
        let claude = Session(id: "demo-claude", name: "✳ Rate limiter plan (claude)", kind: .claude,
                             tty: "/dev/ttys000", path: NSHomeDirectory() + "/code/api-gateway",
                             screen: Demo.claudeScreen, isDemo: true)
        let codex = Session(id: "demo-codex", name: "Review rate limiter plan | api-gateway (codex)", kind: .codex,
                            tty: "/dev/ttys001", path: NSHomeDirectory() + "/code/api-gateway",
                            screen: Demo.codexScreen, isDemo: true)
        for s in [claude, codex] where session(s.id) == nil { sessions.append(s) }
        var flow = Flow(a: claude.id, b: codex.id)
        flow.forward = "Review the updated plan. List blocking issues first, then nits. Say LGTM if nothing is blocking."
        flow.back = "Codex reviewed your plan:\n\n{answer}\n\nFix the blocking issues and update PLAN.md."
        flow.loop = true
        flow.stopPhrase = "LGTM"
        flow.stopWatch = .b
        withAnimation(.snappy) {
            flows.removeAll { !$0.isComplete }
            flows.insert(flow, at: 0)
        }
    }
}

enum Demo {
    static func reply(for kind: AgentKind, turn: Int) -> String {
        switch kind {
        case .claude:
            return "Updated PLAN.md to rev \(turn): switched to a sliding-window counter in Redis, added per-tenant limits, and return 429 with Retry-After."
        case .codex:
            return turn < 2
                ? "Review of rev \(turn): 2 blocking. (1) The Redis keys have no TTL, so idle tenants leak memory. (2) Limits are re-read on every request instead of cached. 1 nit: name the config flag."
                : "Review of rev \(turn): nothing blocking left. Nit: document the Retry-After header. LGTM."
        case .shell:
            return "exit 0"
        }
    }

    /// The first sentence of an answer, without markdown, for one-line previews.
    static func gist(_ s: String) -> String {
        let plain = s.replacingOccurrences(of: #"[*_`#>]"#, with: "", options: .regularExpression)
        let line = plain.split(whereSeparator: \.isNewline).first.map(String.init) ?? plain
        let sentence = line.range(of: ". ").map { String(line[..<$0.lowerBound]) } ?? line
        let t = sentence.trimmingCharacters(in: .whitespaces)
        return t.count > 44 ? String(t.prefix(44)) + "…" : t
    }

    /// What the demo pane looks like after it answers: the reply, then the agent's input box.
    static func screen(for kind: AgentKind, reply: String) -> String {
        var lines: [String] = [], line = ""
        for word in reply.split(separator: " ") {
            if line.count + word.count > 62 { lines.append(line); line = "" }
            line += (line.isEmpty ? "" : " ") + word
        }
        lines.append(line)
        let body = (kind == .claude ? "⏺ " : "• ") + lines.joined(separator: "\n  ")
        let chrome = kind == .claude
            ? "✻ Worked for 1m 12s\n\n────────────────────────────────────────────────\n›\n────────────────────────────────────────────────\n  ⏵⏵ accept edits on (shift+tab to cycle)"
            : "  Worked for 2m 40s\n\n› Ask Codex to do anything\n\n  ~/code/api-gateway"
        return body + "\n\n" + chrome
    }

    static let claudeScreen = """
    ## Plan: rate limiting for the API gateway

    1. Sliding-window counter per tenant, stored in Redis
    2. Limits come from the tenant's plan; cache them for 60s
    3. Over the limit: 429 with a Retry-After header

    Wrote PLAN.md.

    ✻ Worked for 2m 32s

    ────────────────────────────────────────────────
    ›
    ────────────────────────────────────────────────
      ⏵⏵ accept edits on (shift+tab to cycle)
    """

    static let codexScreen = """
    I read PLAN.md and the gateway middleware. Ready to review
    the next revision when it lands.

      Worked for 1m 05s

    › Ask Codex to do anything

      ~/code/api-gateway
    """
}
