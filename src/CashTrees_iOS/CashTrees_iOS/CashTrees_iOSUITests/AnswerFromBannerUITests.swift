import XCTest

/// Real-gesture check for a CallKit Answer.
///
/// An incoming call is shown as a banner while the user is on the home screen. After
/// the user taps Answer, iOS leaves them on the home screen with only the green
/// status bar. The shell is expected to bring itself forward and show the call
/// screen. This test sends the app to the home screen, waits for the banner (start
/// the call from the other account while it waits), taps Answer, and asserts the app
/// became the foreground app.
final class AnswerFromBannerUITests: XCTestCase {
	private let bundleId = "com.beamio.beamio"

	@MainActor
	func testAnswerFromBannerBringsCallScreenForward() throws {
		let app = XCUIApplication(bundleIdentifier: bundleId)
		let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

		if app.state == .notRunning {
			app.launch()
		} else {
			app.activate()
		}
		sleep(5)
		XCUIDevice.shared.press(.home)
		sleep(2)

		// Wait for the CallKit banner; the caller starts the call during this window.
		let bannerText = springboard.staticTexts.matching(
			NSPredicate(format: "label CONTAINS[c] 'Beamio Audio' OR label BEGINSWITH '@'")
		)
		let deadline = Date().addingTimeInterval(150)
		while Date() < deadline, !bannerText.firstMatch.exists {
			sleep(1)
		}
		guard bannerText.firstMatch.exists else {
			XCTFail("No incoming-call banner appeared within 150 s")
			return
		}
		add(XCTAttachment(screenshot: springboard.screenshot()))

		// Prefer the labelled Accept button; fall back to the banner's right-hand
		// check mark (iPhone SE: x 331 pt, y 60 pt of 375 x 667).
		let labels = springboard.descendants(matching: .button).allElementsBoundByIndex.map { "\($0.label)|\($0.identifier)" }
		let named = springboard.descendants(matching: .button).matching(
			NSPredicate(format: "label IN {'Accept','Answer'} OR identifier IN {'Accept','Answer'}")
		).firstMatch
		if named.exists {
			named.tap()
		} else {
			springboard.coordinate(withNormalizedOffset: CGVector(dx: 331.0 / 375.0, dy: 60.0 / 667.0)).tap()
		}

		// Give the shell time to accept the call and bring itself forward.
		sleep(8)
		add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
		XCTAssertEqual(
			app.state,
			.runningForeground,
			"After Answer the app state was \(app.state.rawValue) (1 not running, 2 suspended, 3 background, 4 foreground). Buttons seen: \(labels)"
		)
	}
}
