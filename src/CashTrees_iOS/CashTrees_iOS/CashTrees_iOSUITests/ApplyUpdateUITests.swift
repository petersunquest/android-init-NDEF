import XCTest

/// Device QA helper: taps the "Restart" button of the Embedded PWA update banner so a
/// staged OTA bundle becomes active, exactly as a user would.
final class ApplyUpdateUITests: XCTestCase {
	private let bundleId = "com.beamio.beamio"

	@MainActor
	func testTapRestartOnUpdateBanner() throws {
		let app = XCUIApplication(bundleIdentifier: bundleId)
		if app.state == .notRunning { app.launch() } else { app.activate() }

		let restart = app.buttons.matching(NSPredicate(format: "label ==[c] 'Restart'")).firstMatch
		let restartText = app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Restart'")).firstMatch
		let deadline = Date().addingTimeInterval(60)
		while Date() < deadline, !restart.exists, !restartText.exists { sleep(1) }
		add(XCTAttachment(screenshot: app.screenshot()))
		if restart.exists {
			restart.tap()
		} else if restartText.exists {
			restartText.tap()
		} else {
			XCTFail("No Restart button found within 60 s")
			return
		}
		sleep(12)
		add(XCTAttachment(screenshot: app.screenshot()))
	}
}
