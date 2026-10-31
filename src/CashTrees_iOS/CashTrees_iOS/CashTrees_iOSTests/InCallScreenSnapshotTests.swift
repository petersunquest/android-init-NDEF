import SwiftUI
import XCTest
@testable import CashTrees_iOS

/// Renders the native call screen to a PNG so its layout can be reviewed without a
/// live call. Output path: the `IN_CALL_SNAPSHOT_PATH` environment variable.
final class InCallScreenSnapshotTests: XCTestCase {
	@MainActor
	func testRenderCallScreen() throws {
		let model = BeamioInCallScreenModel.shared
		model.begin(
			callId: "snapshot-call",
			sessionId: "snapshot-session",
			tag: "@rrr01",
			address: "0x909f82221b1005c071db358d9d6d43f4cbc5bf50"
		)
		let view = BeamioInCallScreen(model: model)
			.frame(width: 375, height: 667)
		let renderer = ImageRenderer(content: view)
		renderer.scale = 2
		guard let image = renderer.uiImage, let data = image.pngData() else {
			XCTFail("Could not render the call screen")
			return
		}
		let path = ProcessInfo.processInfo.environment["IN_CALL_SNAPSHOT_PATH"] ?? "/tmp/chat-sdk-accept/incall-render.png"
		try data.write(to: URL(fileURLWithPath: path))
		model.end(callId: "snapshot-call")
		XCTAssertGreaterThan(data.count, 10_000)
	}
}
