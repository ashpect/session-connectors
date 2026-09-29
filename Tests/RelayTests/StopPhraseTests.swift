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

    func testBuiltInPromptsAskForTheSignOffLine() {
        for preset in Preset.builtIns where !preset.stopPhrase.isEmpty {
            XCTAssertTrue(preset.forward.contains("last line that says just: \(preset.stopPhrase)"), preset.name)
        }
    }
}

final class ComposeTests: XCTestCase {
    func testAnswerPlacement() {
        XCTAssertEqual(Flow.compose("", answer: "A"), "A")
        XCTAssertEqual(Flow.compose("Review:\n\n{answer}\n\nThanks", answer: "A"), "Review:\n\nA\n\nThanks")
        XCTAssertEqual(Flow.compose("Review this.", answer: "A"), "Review this.\n\nA")
    }
}
