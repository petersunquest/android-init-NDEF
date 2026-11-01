import XCTest

/// Device QA callee helper. Keeps Beamio in the foreground, waits for an
/// incoming call (start it from the peer phone), then acts per env:
/// TEST_RUNNER_ACTION = accept | decline | none, TEST_RUNNER_HANGUP_AFTER = seconds
/// after Accept before this side taps End (0 = leave the call up).
/// Prints `[Incoming]` lines with wall-clock ms and attaches screenshots.
final class IncomingActionUITests: XCTestCase {
	private let bundleId = "com.beamio.beamio"

	private func now() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

	@MainActor
	private func shot(_ name: String) {
		let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
		a.name = name
		a.lifetime = .keepAlways
		add(a)
	}

	@MainActor
	func testHandleIncoming() throws {
		let env = ProcessInfo.processInfo.environment
		let action = env["ACTION"] ?? "accept"
		let hangupAfter = UInt32(env["HANGUP_AFTER"] ?? "0") ?? 0
		let app = XCUIApplication(bundleIdentifier: bundleId)
		let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
		app.activate()
		print("[Incoming] waiting at \(now())")

		let accept = springboard.buttons.matching(
			NSPredicate(format: "label IN {'Accept','Answer'} OR identifier IN {'Accept','Answer'}")
		).firstMatch
		let decline = springboard.buttons.matching(
			NSPredicate(format: "label IN {'Decline'} OR identifier IN {'Decline'}")
		).firstMatch
		let deadline = Date().addingTimeInterval(150)
		while Date() < deadline, !accept.exists, !decline.exists { usleep(200_000) }
		guard accept.exists || decline.exists else {
			shot("no-incoming")
			XCTFail("No incoming call within 150 s")
			return
		}
		print("[Incoming] ringing seen at \(now())")
		shot("1-ringing")
		sleep(3)
		switch action {
		case "decline":
			decline.tap()
			print("[Incoming] declined at \(now())")
		case "accept":
			accept.tap()
			print("[Incoming] accepted at \(now())")
		default:
			print("[Incoming] no action")
		}
		sleep(4)
		shot("2-after-action")
		if action == "accept" && hangupAfter > 0 {
			sleep(hangupAfter)
			let end = app.buttons["End Call"]
			if end.waitForExistence(timeout: 3) {
				end.tap()
				print("[Incoming] hung up at \(now())")
			} else {
				print("[Incoming] End Call not found")
			}
			sleep(3)
			shot("3-after-hangup")
		}
	}
}
