import Foundation

/// Where Relay keeps its socket, saved state, and the hook binary Claude Code / Codex run.
enum RelayPaths {
    static let dir = NSHomeDirectory() + "/.relay"
    static let socket = dir + "/relay.sock"
    static let state = dir + "/state.json"
    static let presets = dir + "/presets.json"
    static let hook = dir + "/relay-hook"
    static let hookLog = dir + "/hook.log"
}

/// One turn event from Claude Code or Codex, as reported by `relay-hook`.
struct HookEvent {
    let agent: String       // "claude" | "codex"
    let event: String       // "Stop" | "UserPromptSubmit"
    let session: String     // the agent's own session / thread id
    let cwd: String
    let turn: String
    let answer: String      // last_assistant_message (Stop)
    let prompt: String      // prompt (UserPromptSubmit)
    let pane: String        // iTerm session id, when the hook ran inside the pane's process tree
    let tty: String

    init(_ d: [String: Any]) {
        func s(_ k: String) -> String { d[k] as? String ?? "" }
        agent = s("agent"); event = s("event"); session = s("session"); cwd = s("cwd"); turn = s("turn")
        answer = s("answer"); prompt = s("prompt"); pane = s("pane"); tty = s("tty")
    }
}

/// `relay-hook <agent>`: runs as a Claude Code / Codex hook. Reads the hook JSON on stdin, forwards
/// the useful bits to Relay over its socket, prints nothing, and always exits 0 so it can never
/// get in the agent's way (if Relay isn't running, the event is simply dropped).
enum HookCLI {
    static func run() -> Never {
        let agent = CommandLine.arguments.dropFirst().first ?? "unknown"
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        let env = ProcessInfo.processInfo.environment

        // ITERM_SESSION_ID looks like "w0t0p1:1DF44FE5-…"; the part after the colon is iTerm's session id.
        // A Codex pane usually hands its turns to a shared background daemon (`codex app-server`), and
        // hooks then inherit the daemon's environment: its ITERM_SESSION_ID belongs to whichever pane
        // happened to start the daemon, possibly days ago. Don't pass that on; Relay works out the pane.
        let daemon = agent == "codex" && underCodexDaemon()
        let pane = daemon ? "" : env["ITERM_SESSION_ID"].flatMap { $0.split(separator: ":").last.map(String.init) } ?? ""
        let event: [String: Any] = [
            "agent": agent,
            "event": payload["hook_event_name"] as? String ?? "",
            "session": payload["session_id"] as? String ?? "",
            "cwd": payload["cwd"] as? String ?? "",
            "turn": payload["turn_id"] as? String ?? "",
            "answer": payload["last_assistant_message"] as? String ?? "",
            "prompt": payload["prompt"] as? String ?? "",
            "pane": pane,
            "tty": controllingTTY(),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: event)) ?? Data()
        let delivered = send(data)

        if FileManager.default.fileExists(atPath: RelayPaths.dir + "/debug") {
            let line = "\(Date()) \(agent) \(event["event"]!) pane=\(pane.isEmpty ? "-" : pane) daemon=\(daemon) tty=\(event["tty"]!) session=\(event["session"]!) delivered=\(delivered) answer=\((event["answer"] as! String).prefix(60).replacingOccurrences(of: "\n", with: " "))\n"
            if let h = FileHandle(forWritingAtPath: RelayPaths.hookLog) ?? {
                FileManager.default.createFile(atPath: RelayPaths.hookLog, contents: nil)
                return FileHandle(forWritingAtPath: RelayPaths.hookLog)
            }() {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            }
        }
        exit(0)
    }

    /// Walks up from the hook's parent to the nearest `codex` process and reports whether it's the daemon.
    private static func underCodexDaemon() -> Bool {
        var pid = getppid()
        for _ in 0..<8 where pid > 1 {
            guard let (parent, args) = processInfo(pid) else { return false }
            let words = args.split(separator: " ")
            if let exe = words.first, (exe as NSString).lastPathComponent == "codex" || exe.hasSuffix("/codex") {
                return words.contains("app-server")
            }
            pid = parent
        }
        return false
    }

    private static func processInfo(_ pid: pid_t) -> (parent: pid_t, args: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "ppid=,args=", "-p", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let line = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        p.waitUntilExit()
        guard let space = line.firstIndex(of: " "), let parent = pid_t(line[..<space]) else { return nil }
        return (parent, line[space...].trimmingCharacters(in: .whitespaces))
    }

    private static func controllingTTY() -> String {
        let fd = open("/dev/tty", O_RDONLY | O_NOCTTY)
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        return ttyname(fd).map { String(cString: $0) } ?? ""
    }

    private static func send(_ data: Data) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard var addr = unixAddress(RelayPaths.socket) else { return false }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return false }
        return data.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = write(fd, buf.baseAddress! + sent, buf.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }
}

func unixAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    return addr
}

/// Listens on ~/.relay/relay.sock for events from `relay-hook`.
final class HookServer {
    private let queue = DispatchQueue(label: "relay.hooks")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let onEvent: (HookEvent) -> Void

    init(onEvent: @escaping (HookEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() -> Bool {
        try? FileManager.default.createDirectory(atPath: RelayPaths.dir, withIntermediateDirectories: true)
        unlink(RelayPaths.socket)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = unixAddress(RelayPaths.socket) else { return false }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 32) == 0 else { return false }
        chmod(RelayPaths.socket, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        self.source = source
        return true
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let event = HookEvent(obj)
        DispatchQueue.main.async { self.onEvent(event) }
    }
}
