import Testing
@testable import CashTrees_iOS

/// "Incoming call · Beamio voice call" APNs alerts must leave Notification
/// Center once their call is over (SE 2026-11-04: left behind after the caller
/// cancelled), while chat alerts and alerts of a ringing call stay.
struct CallAlertTrayTests {
	typealias T = BeamioCallAlertTray

	private func note(_ id: String, type: String, callId: String) -> T.Delivered {
		T.Delivered(identifier: id, type: type, callId: callId)
	}

	@Test func cancelledCallAlertIsRemoved() {
		let notes = [note("a", type: "voiceCall", callId: "8e0fd8e7")]
		#expect(T.staleIdentifiers(notes, liveCallIds: []) == ["a"])
	}

	@Test func ringingCallAlertStays() {
		let notes = [note("a", type: "voiceCall", callId: "c1")]
		#expect(T.staleIdentifiers(notes, liveCallIds: ["c1"]).isEmpty)
	}

	@Test func onlyTheEndedCallsAlertGoes() {
		let notes = [
			note("old", type: "voiceCall", callId: "c-old"),
			note("live", type: "voiceCall", callId: "c-live"),
		]
		#expect(T.staleIdentifiers(notes, liveCallIds: ["c-live"]) == ["old"])
	}

	@Test func chatAlertsAreLeftAlone() {
		let notes = [
			note("chat", type: "chat", callId: ""),
			note("other", type: "", callId: ""),
		]
		#expect(T.staleIdentifiers(notes, liveCallIds: []).isEmpty)
	}

	@Test func readsServerPayloadKeys() {
		let d = T.delivered(identifier: "x", userInfo: ["type": "voiceCall", "callId": "abc"])
		#expect(d == note("x", type: "voiceCall", callId: "abc"))
		let snake = T.delivered(identifier: "y", userInfo: ["type": "voiceCall", "call_id": "def"])
		#expect(snake.callId == "def")
		let chat = T.delivered(identifier: "z", userInfo: ["aps": ["badge": 1]])
		#expect(chat.type.isEmpty)
	}
}
