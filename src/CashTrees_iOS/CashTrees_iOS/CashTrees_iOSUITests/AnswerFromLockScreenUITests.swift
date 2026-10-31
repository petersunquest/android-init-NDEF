import XCTest

/// Locks the device, waits for the CallKit lock-screen incoming UI, and slides to
/// answer. Used to look at the system call window iOS shows after a lock-screen answer.
final class AnswerFromLockScreenUITests: XCTestCase {
	private let bundleId = "com.beamio.beamio"

	@MainActor
	func testSlideToAnswerOnLockScreen() throws {
		let app = XCUIApplication(bundleIdentifier: bundleId)
		let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

		if app.state == .notRunning {
			app.launch()
		} else {
			app.activate()
		}
		sleep(4)
		XCUIDevice.shared.press(.home)
		sleep(1)
		XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))

		let slider = springboard.descendants(matching: .any).matching(
			NSPredicate(format: "label CONTAINS[c] 'slide to answer' OR identifier CONTAINS[c] 'slide to answer'")
		).firstMatch
		let deadline = Date().addingTimeInterval(150)
		while Date() < deadline, !slider.exists {
			sleep(1)
		}
		guard slider.exists else {
			let seen = springboard.descendants(matching: .any).allElementsBoundByIndex.prefix(40).map { "\($0.elementType.rawValue):\($0.label)" }
			XCTFail("No slide-to-answer control within 150 s. Seen: \(seen)")
			return
		}
		let frame = slider.frame
		let screen = springboard.frame
		let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: (frame.minX + 28) / screen.width, dy: frame.midY / screen.height))
		let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: frame.midY / screen.height))
		start.press(forDuration: 0.1, thenDragTo: end)
		sleep(8)
		XCTAssertTrue(true, "Slid to answer; slider frame \(frame)")
	}
}
