import XCTest

/// Device QA: lock the phone, answer the CallKit incoming call with the slider,
/// press the system call screen's Video button, then record what follows
/// (unlock prompt, Beamio call screen, local video). Start the call from the
/// peer phone after this test has locked the device. Screenshots are attached.
final class LockScreenVideoUITests: XCTestCase {
	private let bundleId = "com.beamio.beamio"

	@MainActor
	private func shot(_ name: String) {
		let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
		a.name = name
		a.lifetime = .keepAlways
		add(a)
	}

	@MainActor
	private func dump(_ app: XCUIApplication, _ name: String) {
		let seen = app.descendants(matching: .any).allElementsBoundByIndex.prefix(80)
			.map { "\($0.elementType.rawValue):\($0.identifier):\($0.label)" }
		print("[LockVideo] \(name): \(seen)")
	}

	@MainActor
	func testAnswerOnLockScreenThenVideo() throws {
		let app = XCUIApplication(bundleIdentifier: bundleId)
		let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
		app.activate()
		sleep(3)
		XCUIDevice.shared.press(.home)
		sleep(1)
		XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
		print("[LockVideo] locked at \(Int(Date().timeIntervalSince1970 * 1000))")

		let slider = springboard.descendants(matching: .any).matching(
			NSPredicate(format: "label CONTAINS[c] 'slide to answer' OR identifier CONTAINS[c] 'slide to answer'")
		).firstMatch
		let deadline = Date().addingTimeInterval(150)
		while Date() < deadline, !slider.exists { sleep(1) }
		guard slider.exists else {
			dump(springboard, "no-slider")
			XCTFail("No slide-to-answer control within 150 s")
			return
		}
		print("[LockVideo] ringing seen at \(Int(Date().timeIntervalSince1970 * 1000))")
		shot("1-lock-ringing")
		let frame = slider.frame
		let screen = springboard.frame
		let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: (frame.minX + 28) / screen.width, dy: frame.midY / screen.height))
		let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: frame.midY / screen.height))
		start.press(forDuration: 0.1, thenDragTo: end)
		print("[LockVideo] answered at \(Int(Date().timeIntervalSince1970 * 1000))")
		sleep(4)
		shot("2-after-answer")
		dump(springboard, "after-answer")

		let video = springboard.buttons.matching(
			NSPredicate(format: "label ==[c] 'Video' OR label ==[c] 'FaceTime' OR label CONTAINS[c] 'camera'")
		).firstMatch
		guard video.waitForExistence(timeout: 6) else {
			XCTFail("No Video button on the system call screen")
			return
		}
		print("[LockVideo] video enabled=\(video.isEnabled)")
		video.tap()
		print("[LockVideo] video tapped at \(Int(Date().timeIntervalSince1970 * 1000))")
		sleep(3)
		shot("3-after-video-tap")
		dump(springboard, "after-video-tap")
		// Without a passcode a Home press finishes the unlock; with one the
		// passcode screen stays (this test does not enter passcodes).
		XCUIDevice.shared.press(.home)
		sleep(6)
		shot("4-after-unlock")
		print("[LockVideo] beamio state=\(app.state.rawValue)")
		dump(app, "beamio-after-unlock")
		sleep(6)
		shot("5-12s")
		let end2 = app.buttons["End Call"]
		if end2.exists { end2.tap() }
		sleep(2)
	}
}
