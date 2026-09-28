import AppKit

struct ITermError: Error {
    let message: String
}

struct Snapshot {
    let id, name, tty, job, path, contents: String
}

/// Talks to iTerm2 through AppleScript (osascript), off the main thread.
enum ITerm {
    static let bundleID = "com.googlecode.iterm2"
    private static let queue = DispatchQueue(label: "relay.iterm", qos: .userInitiated)
    private static let US = "\u{1F}", RS = "\u{1E}"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    /// The pane that has focus in iTerm's front window.
    static func currentSession(completion: @escaping (Result<Session, ITermError>) -> Void) {
        let script = """
        set US to character id 31
        tell application "iTerm2"
            if (count of windows) is 0 then return ""
            tell current session of current window
                set j to variable named "jobName"
                if j is missing value then set j to ""
                set p to variable named "path"
                if p is missing value then set p to ""
                return (id as text) & US & (name as text) & US & (tty as text) & US & j & US & p & US & (contents as text)
            end tell
        end tell
        """
        run(script) { result in
            completion(result.flatMap { out in
                guard let snap = parse(out) else { return .failure(ITermError(message: "No iTerm window is open.")) }
                return .success(Session(id: snap.id, name: snap.name, kind: .detect(name: snap.name, job: snap.job),
                                        tty: snap.tty, path: snap.path, screen: snap.contents,
                                        working: Session.isWorking(name: snap.name, screen: snap.contents)))
            })
        }
    }

    static func snapshots(ids: [String], completion: @escaping (Result<[String: Snapshot], ITermError>) -> Void) {
        let wanted = ids.map { "\"\($0)\"" }.joined(separator: ", ")
        let script = """
        set US to character id 31
        set RS to character id 30
        set wanted to {\(wanted)}
        set out to ""
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set sid to (id of s) as text
                        if wanted contains sid then
                            tell s
                                set j to variable named "jobName"
                                if j is missing value then set j to ""
                                set p to variable named "path"
                                if p is missing value then set p to ""
                                set out to out & sid & US & (name as text) & US & (tty as text) & US & j & US & p & US & (contents as text) & RS
                            end tell
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return out
        """
        run(script) { result in
            completion(result.map { out in
                var snaps: [String: Snapshot] = [:]
                for record in out.components(separatedBy: RS) {
                    if let s = parse(record) { snaps[s.id] = s }
                }
                return snaps
            })
        }
    }

    /// Every pane in every iTerm window.
    static func allSessions(completion: @escaping (Result<[Snapshot], ITermError>) -> Void) {
        let script = """
        set US to character id 31
        set RS to character id 30
        set out to ""
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        tell s
                            set j to variable named "jobName"
                            if j is missing value then set j to ""
                            set p to variable named "path"
                            if p is missing value then set p to ""
                            set out to out & ((id of s) as text) & US & (name as text) & US & (tty as text) & US & j & US & p & US & (contents as text) & RS
                        end tell
                    end repeat
                end repeat
            end repeat
        end tell
        return out
        """
        run(script) { result in
            completion(result.map { out in out.components(separatedBy: RS).compactMap(parse) })
        }
    }

    static func reveal(id: String) {
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if ((id of s) as text) is "\(id)" then
                            select w
                            select t
                            select s
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
        run(script) { _ in }
    }

    /// Types `text` into a pane as one bracketed paste, then presses Return, exactly as if you'd
    /// pasted it yourself. Multi-line text stays one message.
    static func paste(id: String, text: String, completion: @escaping (Result<Void, ITermError>) -> Void) {
        let script = """
        on run argv
            set sid to item 1 of argv
            set payload to item 2 of argv
            set ESC to character id 27
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if ((id of s) as text) is sid then
                                tell s to write text (ESC & "[200~" & payload & ESC & "[201~") newline no
                                delay 0.4
                                tell s to write text (character id 13) newline no
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "missing"
        end run
        """
        run(script, args: [id, text]) { result in
            switch result {
            case .success("ok"): completion(.success(()))
            case .success: completion(.failure(ITermError(message: "That pane is gone.")))
            case .failure(let e): completion(.failure(e))
            }
        }
    }

    private static func parse(_ record: String) -> Snapshot? {
        let f = record.components(separatedBy: US)
        guard f.count >= 6, !f[0].isEmpty else { return nil }
        return Snapshot(id: f[0].trimmingCharacters(in: .whitespacesAndNewlines), name: f[1], tty: f[2], job: f[3],
                        path: f[4], contents: f[5...].joined(separator: US))
    }

    private static func run(_ source: String, args: [String] = [], completion: @escaping (Result<String, ITermError>) -> Void) {
        queue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-"] + args
            let input = Pipe(), out = Pipe(), err = Pipe()
            p.standardInput = input
            p.standardOutput = out
            p.standardError = err
            let result: Result<String, ITermError>
            do {
                try p.run()
                input.fileHandleForWriting.write(Data(source.utf8))
                try? input.fileHandleForWriting.close()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    var text = String(decoding: data, as: UTF8.self)
                    if text.hasSuffix("\n") { text.removeLast() }
                    result = .success(text)
                } else if errText.contains("-1743") {
                    result = .failure(ITermError(message: "Relay can't read iTerm yet. Allow it in System Settings → Privacy & Security → Automation → Relay → iTerm2."))
                } else {
                    result = .failure(ITermError(message: "iTerm didn't answer: \(errText.trimmingCharacters(in: .whitespacesAndNewlines))"))
                }
            } catch {
                result = .failure(ITermError(message: "Couldn't run osascript: \(error.localizedDescription)"))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
