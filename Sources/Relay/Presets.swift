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
    var roleA: String?        // what the top session is in this setup, e.g. "Reviewer"
    var roleB: String?        // …and the bottom one, e.g. "Author"

    var builtIn: Bool { id.hasPrefix("builtin.") }

    init(id: String, name: String, note: String = "", roles: (String, String)? = nil, loop: Bool, forward: String,
         back: String = "", stopPhrase: String = "", stopWatch: Flow.Watch = .either, maxRounds: Int = 10) {
        self.id = id
        self.name = name
        self.note = note
        self.roleA = roles?.0
        self.roleB = roles?.1
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
        roleA = flow.roleA
        roleB = flow.roleB
    }

    /// Whether the flow still has exactly this preset's settings (false once you edit them).
    func matches(_ f: Flow) -> Bool {
        loop == f.loop && forward == f.forward && (!loop || back == f.back)
            && stopPhrase == f.stopPhrase && stopWatch == f.stopWatch && maxRounds == f.maxRounds
    }

    /// "reviewer on top, author below", for the note shown after applying.
    var placement: String? {
        guard let roleA, let roleB else { return nil }
        return "\(roleA.lowercased()) on top, \(roleB.lowercased()) below"
    }

    // MARK: Built in
    //
    // Stop phrases only count as a reply's last line on its own (see Flow.signsOff), so the prompt that
    // goes to the session being watched says so explicitly, and asks it not to use the word otherwise.

    static let builtInGroups: [(title: String, presets: [Preset])] = [
        ("Plans", [planReview, planDiscussion]),
        ("Code", [prReview, reviewMyChanges]),
        ("Checks", [rootCauseCheck, secondOpinion]),
    ]

    static let builtIns: [Preset] = builtInGroups.flatMap(\.presets)

    static let planReview = Preset(
        id: "builtin.plan-review", name: "Plan review",
        note: "One session writes the plan, the other reviews it until LGTM",
        roles: ("Planner", "Reviewer"),
        loop: true,
        forward: "Review this plan. List blocking issues first, then nits, as short bullets.\n\nOnly if nothing is blocking, end your reply with a last line that says just: LGTM\nIf anything is blocking, don't write LGTM anywhere.\n\n{answer}",
        back: "Another AI reviewed your plan:\n\n{answer}\n\nFix the blocking issues and reply with the updated plan. If you disagree with a point, say why.",
        stopPhrase: "LGTM", stopWatch: .b, maxRounds: 6)

    static let planDiscussion = Preset(
        id: "builtin.plan-discussion", name: "Plan discussion",
        note: "Two peers talk a plan through until one signs off with AGREED",
        roles: ("Proposer", "Responder"),
        loop: true,
        forward: "Another AI proposed the plan below. Give your honest take as short bullets: what's solid, what's risky or missing, and what you'd change.\n\nIf you have any concerns, write them normally and don't use the word AGREED. Only if you're fully happy with the plan as it stands, end your reply with a last line that says just: AGREED\n\n{answer}",
        back: "Another AI responded to your plan:\n\n{answer}\n\nGo point by point: accept what's right and revise the plan, and push back where you disagree, saying why.\n\nIf you still have concerns, don't use the word AGREED. Only if you're now fully happy with the plan, end your reply with a last line that says just: AGREED",
        stopPhrase: "AGREED", stopWatch: .either, maxRounds: 6)

    /// How a reviewer ends each reply: approve, hand a deadlock to the human, or neither.
    private static let reviewerSignOff = """
        End your reply in exactly one of these ways:
        - Every point is resolved: a last line that says just: APPROVED
        - The only points left need a human decision: a last line that says just: NEEDS HUMAN
        - Anything else is still open: no sign-off line, and don't use either phrase.
        """

    /// What an author is asked to do with a review, shared by both code-review presets.
    private static func authorPrompt(_ subject: String) -> String {
        """
        A reviewer went through \(subject). Their review:

        {answer}

        Work through it point by point, keeping their numbering:
        - If a point is right, fix it in the code, then say what you changed and where.
        - If you disagree, push back: leave the code alone and explain why, pointing at the code that backs you up.
        - If the reviewer repeats a point you already pushed back on and brings nothing new, don't argue it again. Say it needs a human decision and give both positions, one line each.

        Don't agree just to move things along, and don't skip a point. Finish with a short summary: what you fixed, what you pushed back on, and what needs a human decision.
        """
    }

    static let prReview = Preset(
        id: "builtin.pr-review", name: "PR review",
        note: "The reviewer reviews; the author fixes or pushes back until it's approved",
        roles: ("Reviewer", "Author"),
        loop: true,
        forward: authorPrompt("your PR"),
        back: """
        The author responded to your review:

        {answer}

        Check every point against the code itself, not their description of it:
        - Where they say it's fixed, read the change and confirm it really fixes the problem without breaking something else.
        - Where they pushed back, judge the argument on its merits. If they're right, say so and drop the point. If not, explain what they're missing.
        - If you already answered their pushback on a point and they still disagree with nothing new, stop arguing it. Move it to a "Needs a human decision" list with your position and theirs, one line each.
        Also flag anything new that their changes introduced.

        Then list only what's still open, keeping the numbering.

        \(reviewerSignOff)
        """,
        stopPhrase: "APPROVED, NEEDS HUMAN", stopWatch: .a, maxRounds: 6)

    static let reviewMyChanges = Preset(
        id: "builtin.review-my-changes", name: "Review my changes",
        note: "Like PR review, but it starts from the author's own summary",
        roles: ("Author", "Reviewer"),
        loop: true,
        forward: """
        The author of the current changes wrote:

        {answer}

        Review the changes themselves (the working tree and recent commits), not just this description.
        - If you haven't reviewed them yet, do a full review: correctness bugs first, then risky edge cases and missing tests. Number your findings.
        - If this is a response to your earlier review, check each point: confirm every claimed fix in the code, and judge each pushback on its merits. Where they're right, say so and drop the point.
        - If you already answered their pushback on a point and they still disagree with nothing new, stop arguing it. Move it to a "Needs a human decision" list with your position and theirs, one line each.

        Then list only what's still open.

        \(reviewerSignOff)
        """,
        back: authorPrompt("your changes"),
        stopPhrase: "APPROVED, NEEDS HUMAN", stopWatch: .b, maxRounds: 6)

    static let rootCauseCheck = Preset(
        id: "builtin.root-cause-check", name: "Root-cause check",
        note: "One session diagnoses a failure; the other tries to disprove it",
        roles: ("Investigator", "Skeptic"),
        loop: true,
        forward: """
        Another engineer investigated a failure and concluded:

        {answer}

        Try to disprove it. Check the evidence yourself where you can (logs, data, code) instead of taking it on trust:
        - Does the evidence actually show this cause, or does it only fit it?
        - What else could explain the same symptoms, and what would tell the explanations apart?
        - What is claimed without proof?
        List the gaps as numbered points, most serious first. If a point has gone round once already and can't be settled with evidence either of you can get, stop pressing it: move it to a "Needs a human decision" list and say what evidence is missing.

        End your reply in exactly one of these ways:
        - The root cause holds up and you have no open doubt: a last line that says just: CONFIRMED
        - The only points left need a human decision: a last line that says just: NEEDS HUMAN
        - Anything else is still open: no sign-off line, and don't use either phrase.
        """,
        back: """
        A second engineer challenged your conclusion:

        {answer}

        Answer each point, keeping the numbering:
        - If evidence can settle it, go and get it, and show it: the exact query, log line, or code path.
        - If the challenge is right, say so and revise the root cause.
        - If you can't get the evidence (no access, or the data is gone), say so plainly instead of guessing.

        Don't defend the original conclusion for its own sake. End with the root cause as you now understand it, and how sure you are.
        """,
        stopPhrase: "CONFIRMED, NEEDS HUMAN", stopWatch: .b, maxRounds: 5)

    static let secondOpinion = Preset(
        id: "builtin.second-opinion", name: "Second opinion",
        note: "One-way: send an answer off for a quick check",
        roles: ("Source", "Checker"),
        loop: false,
        forward: "Here's another AI's answer. Check it for mistakes, gaps, or anything you'd do differently. Keep it brief.\n\n{answer}")
}
