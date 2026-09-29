import Foundation

/// A reusable flow setup: mode, both prompts, and the stop rule. It doesn't include the sessions,
/// so the same preset works for any pair of panes.
struct Preset: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var note = ""
    var loop: Bool
    var forward: String
    var back: String
    var stopPhrase: String
    var stopWatch: Flow.Watch
    var maxRounds: Int

    var builtIn: Bool { id.hasPrefix("builtin.") }

    init(id: String, name: String, note: String = "", loop: Bool, forward: String, back: String = "",
         stopPhrase: String = "", stopWatch: Flow.Watch = .either, maxRounds: Int = 10) {
        self.id = id
        self.name = name
        self.note = note
        self.loop = loop
        self.forward = forward
        self.back = back
        self.stopPhrase = stopPhrase
        self.stopWatch = stopWatch
        self.maxRounds = maxRounds
    }

    init(from flow: Flow, name: String) {
        self.init(id: UUID().uuidString, name: name, loop: flow.loop, forward: flow.forward, back: flow.back,
                  stopPhrase: flow.stopPhrase, stopWatch: flow.stopWatch, maxRounds: flow.maxRounds)
    }

    /// Whether the flow still has exactly this preset's settings (false once you edit them).
    func matches(_ f: Flow) -> Bool {
        loop == f.loop && forward == f.forward && (!loop || back == f.back)
            && stopPhrase == f.stopPhrase && stopWatch == f.stopWatch && maxRounds == f.maxRounds
    }

    static let builtIns: [Preset] = [
        Preset(
            id: "builtin.plan-review", name: "Plan review",
            note: "One session writes the plan, the other reviews it until LGTM",
            loop: true,
            forward: "Review this plan. List blocking issues first, then nits, as short bullets. If nothing is blocking, say LGTM.\n\n{answer}",
            back: "Another AI reviewed your plan:\n\n{answer}\n\nFix the blocking issues and update the plan. If you disagree with a point, say why.",
            stopPhrase: "LGTM", stopWatch: .b, maxRounds: 6),
        Preset(
            id: "builtin.plan-discussion", name: "Plan discussion",
            note: "Two peers talk a plan through until they agree",
            loop: true,
            forward: "Another AI proposed the plan below. Give your honest take as short bullets: what's solid, what's risky or missing, and what you'd change. If you'd sign off on it as it stands, say AGREED.\n\n{answer}",
            back: "Another AI responded to your plan:\n\n{answer}\n\nGo point by point: accept what's right and revise the plan, and push back where you disagree, saying why. If you now fully agree, say AGREED.",
            stopPhrase: "AGREED", stopWatch: .either, maxRounds: 6),
        Preset(
            id: "builtin.second-opinion", name: "Second opinion",
            note: "One-way: send an answer off for a quick check",
            loop: false,
            forward: "Here's another AI's answer. Check it for mistakes, gaps, or anything you'd do differently. Keep it brief.\n\n{answer}"),
    ]
}
