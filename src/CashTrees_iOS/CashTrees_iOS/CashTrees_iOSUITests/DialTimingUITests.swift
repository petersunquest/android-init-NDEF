import XCTest

/// Device QA: time from tapping "Start voice call" in an open chat to the call
/// screen showing. Open the peer's chat first (or pass TEST_RUNNER_PEER_TAG to
/// tap that row in the chat list). Hangs up after ~10 s.
/// Results go to the test log as `[DialTiming]` lines and to screenshots.
final class DialTimingUITests: XCTestCase {
	private let bundleId = "com.beamio.beamio"

	@MainActor
	func testDialShowsCallScreen() throws {
		let app = XCUIApplication(bundleIdentifier: bundleId)
		app.activate()
		let env = ProcessInfo.processInfo.environment
		let callButton = app.buttons["Start voice call"]
		// The WebView does not always expose its text to accessibility, so the
		// chat row and the call button can also be given as screen fractions.
		func fraction(_ key: String) -> CGFloat? {
			env[key].flatMap { Double($0) }.map { CGFloat($0) }
		}
		// PRE_TAPS="0.54,0.94;0.5,0.22": screen-fraction taps, 3 s apart (tab, row).
		for pair in (env["PRE_TAPS"] ?? "").split(separator: ";") {
			let xy = pair.split(separator: ",").compactMap { Double($0) }
			guard xy.count == 2 else { continue }
			app.coordinate(withNormalizedOffset: CGVector(dx: xy[0], dy: xy[1])).tap()
			sleep(3)
		}
		if let ny = fraction("PEER_ROW_NY") {
			app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: ny)).tap()
			sleep(4)
		}
		let shot0 = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
		shot0.name = "chat-before-dial"
		shot0.lifetime = .keepAlways
		add(shot0)

		let endButton = app.buttons["End Call"]
		let byLabel = callButton.waitForExistence(timeout: 3)
		let tapAt = Date()
		if byLabel {
			callButton.tap()
		} else if let nx = fraction("CALL_NX"), let ny = fraction("CALL_NY") {
			app.coordinate(withNormalizedOffset: CGVector(dx: nx, dy: ny)).tap()
		} else {
			XCTFail("call button not found")
			return
		}
		let tapReturned = Date()
		var seenAt: Date?
		let deadline = Date().addingTimeInterval(10)
		while Date() < deadline {
			if endButton.exists {
				seenAt = Date()
				break
			}
		}
		let firstShot = XCUIScreen.main.screenshot()
		let tapMs = Int(tapReturned.timeIntervalSince(tapAt) * 1000)
		let seenMs = seenAt.map { Int($0.timeIntervalSince(tapAt) * 1000) } ?? -1
		print("[DialTiming] tapCall=\(Int(tapAt.timeIntervalSince1970 * 1000)) tapReturned=+\(tapMs) callScreenSeen=+\(seenMs)")
		let shot1 = XCTAttachment(screenshot: firstShot)
		shot1.name = "call-screen-first"
		shot1.lifetime = .keepAlways
		add(shot1)

		sleep(3)
		let shot2 = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
		shot2.name = "call-screen-3s"
		shot2.lifetime = .keepAlways
		add(shot2)
		sleep(6)
		// HOLD_SECONDS: keep the call up (e.g. to reach the ring timeout) before ending it here.
		if let hold = env["HOLD_SECONDS"].flatMap({ UInt32($0) }), hold > 0 {
			let deadline = Date().addingTimeInterval(TimeInterval(hold))
			while Date() < deadline, endButton.exists { sleep(2) }
			print("[DialTiming] hold ended callScreenStillUp=\(endButton.exists) at \(Int(Date().timeIntervalSince1970 * 1000))")
		}
		let shot3 = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
		shot3.name = "call-screen-9s"
		shot3.lifetime = .keepAlways
		add(shot3)
		if endButton.exists { endButton.tap() }
		sleep(2)
		XCTAssertGreaterThanOrEqual(seenMs, 0, "call screen never showed")
	}
}
