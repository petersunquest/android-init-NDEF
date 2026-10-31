import XCTest

/// One-shot helper: bring Beamio forward then press Home so CallKit can paint.
final class BackgroundBeamioForCallKitUITests: XCTestCase {
	private let bundleId = "com.beamio.beamio"

	@MainActor
	func testPressHomeToBackgroundBeamio() throws {
		let app = XCUIApplication(bundleIdentifier: bundleId)
		if app.state == .notRunning {
			app.launch()
		} else {
			app.activate()
		}
		sleep(3)
		XCUIDevice.shared.press(.home)
		sleep(2)
		XCTAssertTrue(true, "Home pressed; Beamio should be backgrounded")
	}
}
