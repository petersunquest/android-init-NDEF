import XCTest

/// Device QA: screenshot the phone every TEST_RUNNER_SNAP_EVERY seconds (default 4)
/// for TEST_RUNNER_SNAP_SECONDS (default 40), whatever app is in front.
final class SnapUITests: XCTestCase {
	@MainActor
	func testSnapshots() throws {
		let env = ProcessInfo.processInfo.environment
		let total = Double(env["SNAP_SECONDS"] ?? "40") ?? 40
		let every = UInt32(env["SNAP_EVERY"] ?? "4") ?? 4
		let start = Date()
		var n = 0
		while Date().timeIntervalSince(start) < total {
			let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
			a.name = String(format: "snap-%02d", n)
			a.lifetime = .keepAlways
			add(a)
			print("[Snap] \(n) at \(Int(Date().timeIntervalSince1970 * 1000))")
			n += 1
			sleep(every)
		}
	}
}
