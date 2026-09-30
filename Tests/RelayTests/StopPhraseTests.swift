import XCTest
@testable import Relay

final class StopPhraseTests: XCTestCase {
    // The reply that ended a real loop in round 1 when any mention of the phrase counted.
    func testMentioningThePhraseDoesNotStop() {
        let reply = """
        Not AGREED. The direction is right, but the plan misses a contract that changed on main.

        What's solid
        - Keeping the design, the seven tools and no schema change: agreed.
        """
        XCTAssertFalse(Flow.signsOff(reply, with: "AGREED"))
        XCTAssertFalse(Flow.signsOff("I'm not AGREED yet.", with: "AGREED"))
        XCTAssertFalse(Flow.signsOff("Mostly fine.\n\nNot agreed", with: "AGREED"))
        XCTAssertFalse(Flow.signsOff("AGREED?", with: "AGREED"))
        XCTAssertFalse(Flow.signsOff("LGTM — once the lock is added", with: "LGTM"))
        XCTAssertFalse(Flow.signsOff("AGREED\n\nOne more thing: add a test.", with: "AGREED"))
    }

    func testAFinalLineWithJustThePhraseStops() {
        XCTAssertTrue(Flow.signsOff("Looks good to me.\n\nAGREED", with: "AGREED"))
        XCTAssertTrue(Flow.signsOff("All addressed.\n\n**AGREED**\n\n", with: "AGREED"))
        XCTAssertTrue(Flow.signsOff("Nothing blocking.\nLGTM.", with: "LGTM"))
        XCTAssertTrue(Flow.signsOff("agreed", with: "AGREED"))
        XCTAssertTrue(Flow.signsOff("Ship it!", with: "ship it"))
        XCTAssertTrue(Flow.signsOff("`APPROVED`", with: "APPROVED"))
    }

    func testEmptyPhraseNeverStops() {
        XCTAssertFalse(Flow.signsOff("AGREED", with: ""))
        XCTAssertFalse(Flow.signsOff("", with: "AGREED"))
    }

    // The prompt that reaches the session being watched has to ask for the sign-off line:
    // `forward` goes to the bottom session (B), `back` goes to the top one (A).
    func testBuiltInPromptsAskForTheSignOffLine() {
        for preset in Preset.builtIns {
            for phrase in Flow.phrases(preset.stopPhrase) {
                let ask = "last line that says just: \(phrase)"
                if preset.stopWatch != .a { XCTAssertTrue(preset.forward.contains(ask), "\(preset.name) forward, \(phrase)") }
                if preset.stopWatch != .b { XCTAssertTrue(preset.back.contains(ask), "\(preset.name) back, \(phrase)") }
            }
        }
    }

    func testSeveralStopPhrases() {
        let phrases = "APPROVED, NEEDS HUMAN"
        XCTAssertEqual(Flow.phrases(phrases), ["APPROVED", "NEEDS HUMAN"])
        XCTAssertEqual(Flow.phrases("LGTM | SHIP IT ,, "), ["LGTM", "SHIP IT"])
        XCTAssertEqual(Flow.signOff("All fixed.\n\nAPPROVED", phrases: phrases), "APPROVED")
        XCTAssertEqual(Flow.signOff("Needs a human decision\n1. Unknown codes: I say pass through, author says raise.\n\n**NEEDS HUMAN**", phrases: phrases), "NEEDS HUMAN")
        XCTAssertNil(Flow.signOff("This needs human input on point 1, but point 2 is still open.", phrases: phrases))
        XCTAssertNil(Flow.signOff("Not approved; needs human review later.", phrases: phrases))
    }

    // The real deadlock from testing: six rounds of "still missing" / "I still disagree", neither signing off.
    func testADeadlockedReplyKeepsGoingUntilSomeoneHandsOff() {
        let stuck = "1. [P2] Requested unknown-coupon behavior remains missing. Implement the fallback, update the docstring, and add the regression test."
        XCTAssertNil(Flow.signOff(stuck, phrases: "APPROVED, NEEDS HUMAN"))
    }

    func testHandOffPhraseStopsTheFlowAndFlagsIt() {
        func run(_ answer: String) -> Flow {
            let store = RelayStore()
            store.loadDemo()
            store.apply(.prReview, to: store.flows[0].id)
            store.flows[0].enabled = true
            store.sessionFinished(store.flows[0].a!, answer: answer)
            return store.flows[0]
        }
        let approved = run("Both fixes check out.\n\nAPPROVED")
        XCTAssertNotNil(approved.halted)
        XCTAssertFalse(approved.needsYou)

        let handedOff = run("Needs a human decision\n1. Unknown codes.\n\nNEEDS HUMAN")
        XCTAssertNotNil(handedOff.halted)
        XCTAssertTrue(handedOff.needsYou)
        XCTAssertEqual(handedOff.rounds, 0, "nothing more is sent after a hand-off")

        let open = run("2. Still open: the lock is taken after the read.")
        XCTAssertNil(open.halted)
        XCTAssertEqual(open.rounds, 1, "an open review goes on to the author")
    }

    // The demo flow has to be able to finish: its canned reviewer reply signs off the way the preset asks.
    func testDemoLoopCanFinish() {
        let store = RelayStore()
        store.loadDemo()
        let flow = store.flows[0]
        XCTAssertEqual(flow.presetID, Preset.planReview.id)
        XCTAssertNil(Flow.signOff(Demo.reply(for: .codex, turn: 1), phrases: flow.stopPhrase))
        XCTAssertEqual(Flow.signOff(Demo.reply(for: .codex, turn: 2), phrases: flow.stopPhrase), "LGTM")
    }

    func testPreviewSkipsListMarkers() {
        XCTAssertEqual(Demo.gist("1. **[P1] Divide the discount by 100.** `COUPONS` holds whole percents."), "1. [P1] Divide the discount by 100")
        XCTAssertEqual(Demo.gist("**Marmalade**\nA playful nod."), "Marmalade")
    }

    func testBuiltInPresetsAreWellFormed() {
        XCTAssertEqual(Set(Preset.builtIns.map(\.id)).count, Preset.builtIns.count, "ids are unique")
        for preset in Preset.builtIns {
            XCTAssertTrue(preset.builtIn, preset.name)
            XCTAssertTrue(preset.forward.contains("{answer}"), "\(preset.name) forward places the answer")
            if preset.loop { XCTAssertTrue(preset.back.contains("{answer}"), "\(preset.name) back places the answer") }
            XCTAssertNotNil(preset.placement, "\(preset.name) names both roles")
            XCTAssertFalse(preset.forward.hasPrefix(" ") || preset.forward.contains("\n        "), "\(preset.name) has stray indentation")
        }
    }

    // A reviewer's verdicts from the PR review preset, as they'd really be phrased.
    func testReviewVerdicts() {
        XCTAssertFalse(Flow.signsOff("1. Fixed, confirmed.\n2. Still open: the lock is taken after the read.\n\nNot approved yet.", with: "APPROVED"))
        XCTAssertFalse(Flow.signsOff("APPROVED once point 2 is fixed.", with: "APPROVED"))
        XCTAssertTrue(Flow.signsOff("1. Fixed, confirmed.\n2. Your pushback is right, dropping it.\n\nNothing left open.\n\nAPPROVED", with: "APPROVED"))
    }

    func testSwappingAFlowSwapsItsRoles() {
        let store = RelayStore()
        store.apply(.prReview, to: store.flows[0].id)
        XCTAssertEqual(store.flows[0].roleA, "Reviewer")
        XCTAssertEqual(store.flows[0].stopWatch, .a)
        store.swap(store.flows[0].id)
        XCTAssertEqual(store.flows[0].roleA, "Author")
        XCTAssertEqual(store.flows[0].roleB, "Reviewer")
        XCTAssertEqual(store.flows[0].stopWatch, .b)
        XCTAssertEqual(store.flows[0].forward, Preset.prReview.back)
    }
}

final class ComposeTests: XCTestCase {
    func testAnswerPlacement() {
        XCTAssertEqual(Flow.compose("", answer: "A"), "A")
        XCTAssertEqual(Flow.compose("Review:\n\n{answer}\n\nThanks", answer: "A"), "Review:\n\nA\n\nThanks")
        XCTAssertEqual(Flow.compose("Review this.", answer: "A"), "Review this.\n\nA")
    }
}
