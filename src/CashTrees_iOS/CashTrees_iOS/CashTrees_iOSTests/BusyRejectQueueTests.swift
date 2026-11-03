import Testing
@testable import CashTrees_iOS

/// Busy callee: the busy reject goes to the new caller at once, not when our own
/// call ends, and each call gets it only once.
struct BusyRejectQueueTests {
	typealias Queue = BeamioBusyRejectQueue<String>

	private func sentNow(_ d: Queue.Decision) -> String? {
		if case .sendNow(let offer) = d { return offer }
		return nil
	}

	private func isWait(_ d: Queue.Decision) -> Bool {
		if case .wait = d { return true }
		return false
	}

	private func isAlreadySent(_ d: Queue.Decision) -> Bool {
		if case .alreadySent = d { return true }
		return false
	}

	@Test func inCallIncomingSendsBusyAtOnce() {
		var q = Queue()
		// We are in a call; the second caller's offer is already resolved.
		#expect(sentNow(q.busyCallArrived(callId: "b", sessionId: "sb", reason: "busy", resolved: "offer-b")) == "offer-b")
		#expect(q.waiting.isEmpty)
	}

	@Test func peerHangsUpFirstAfterTheRejectWentOut() {
		var q = Queue()
		_ = q.busyCallArrived(callId: "b", sessionId: "sb", reason: "busy", resolved: "offer-b")
		// The other party of our call hangs up first (no local CallKit End): nothing to send twice.
		#expect(q.ownCallEnded().isEmpty)
	}

	@Test func peerHangsUpFirstWhileTheOfferWasNotResolved() {
		var q = Queue()
		#expect(isWait(q.busyCallArrived(callId: "b", sessionId: "sb", reason: "busy", resolved: nil)))
		// Our call ends from the other side: the waiting reject still goes out.
		#expect(q.ownCallEnded() == [.init(callId: "b", sessionId: "sb", reason: "busy")])
		#expect(q.waiting.isEmpty)
	}

	@Test func lateOfferGoesOutWhenItResolvesDuringOurCall() {
		var q = Queue()
		_ = q.busyCallArrived(callId: "b", sessionId: "sb", reason: "busy", resolved: nil)
		#expect(q.offerResolved(callId: "other", sessionId: "") == nil)
		// Found by the session id as well as the call id.
		#expect(q.offerResolved(callId: "", sessionId: "sb") == .init(callId: "b", sessionId: "sb", reason: "busy"))
		#expect(q.ownCallEnded().isEmpty)
	}

	@Test func theSameBusyCallWaitsOnce() {
		var q = Queue()
		_ = q.busyCallArrived(callId: "b", sessionId: "sb", reason: "busy", resolved: nil)
		_ = q.busyCallArrived(callId: "b", sessionId: "sb", reason: "busy", resolved: nil)
		#expect(q.waiting.count == 1)
		// Resolved on the repeat: sent now and no longer waiting.
		#expect(sentNow(q.busyCallArrived(callId: "b", sessionId: "sb", reason: "busy", resolved: "offer-b")) == "offer-b")
		#expect(q.waiting.isEmpty)
	}

	/// RC3b b1: the chat offer sent the reject, then the VoIP push for the same
	/// call came in with no cached offer; it must not queue a second reject.
	@Test func theSameCallGetsOneRejectOnly() {
		var q = Queue()
		#expect(sentNow(q.busyCallArrived(callId: "b", sessionId: "sb", reason: "busy", resolved: "offer-b")) == "offer-b")
		#expect(isAlreadySent(q.busyCallArrived(callId: "b", sessionId: "sb", reason: "busy", resolved: nil)))
		#expect(isAlreadySent(q.busyCallArrived(callId: "", sessionId: "sb", reason: "busy", resolved: "offer-b")))
		#expect(q.waiting.isEmpty)
		#expect(q.ownCallEnded().isEmpty)
		// Also after the late-resolve and call-end paths.
		_ = q.busyCallArrived(callId: "c", sessionId: "sc", reason: "busy", resolved: nil)
		_ = q.offerResolved(callId: "c", sessionId: "sc")
		#expect(isAlreadySent(q.busyCallArrived(callId: "c", sessionId: "sc", reason: "busy", resolved: "offer-c")))
		_ = q.busyCallArrived(callId: "d", sessionId: "sd", reason: "busy", resolved: nil)
		_ = q.ownCallEnded()
		#expect(isAlreadySent(q.busyCallArrived(callId: "d", sessionId: "", reason: "busy", resolved: nil)))
	}

	@Test func sentMemoryIsBounded() {
		var q = Queue()
		for i in 0..<100 {
			_ = q.busyCallArrived(callId: "c\(i)", sessionId: "", reason: "busy", resolved: "o")
		}
		#expect(q.sent.count == Queue.sentMemory)
		#expect(q.wasSent(callId: "c99", sessionId: ""))
		#expect(!q.wasSent(callId: "c0", sessionId: ""))
	}
}
