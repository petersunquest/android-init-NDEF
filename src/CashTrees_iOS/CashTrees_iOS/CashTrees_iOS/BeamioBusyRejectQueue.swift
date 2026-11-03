import Foundation

/// Busy callee: a second call arrives while we are in a call (or another call
/// rings here). Its caller must get `voice_call_reject_v1` reason=busy at once,
/// so it hears the busy tone and sees "On another call" while it still dials.
///
/// The reject is sealed with the same OpenPGP host the dialer cancel already
/// uses during a live call, so it no longer waits for our own call to end.
/// Only an offer that is not resolved yet waits: it goes out when the offer
/// resolves, or when our call ends (either side hangs up), whichever comes
/// first. Each call gets one busy reject: the shell can see the same call
/// twice (chat offer, then its VoIP push). Pure: no UIKit, so it can be unit-tested.
nonisolated struct BeamioBusyRejectQueue<Offer> {
	struct Waiting: Equatable {
		var callId: String
		var sessionId: String
		var reason: String
	}

	enum Decision {
		/// Send the busy reject for this offer now.
		case sendNow(Offer)
		/// The offer is not resolved yet: it waits for the resolve or our call's end.
		case wait
		/// This call already got its busy reject: nothing to send.
		case alreadySent
	}

	private(set) var waiting: [Waiting] = []
	/// Call and session ids that already got a busy reject (newest last).
	private(set) var sent: [String] = []
	static var sentMemory: Int { 64 }

	/// A busy call arrived.
	mutating func busyCallArrived(callId: String, sessionId: String, reason: String, resolved: Offer?) -> Decision {
		if wasSent(callId: callId, sessionId: sessionId) {
			waiting.removeAll { Self.matches($0, callId, sessionId) }
			return .alreadySent
		}
		if let resolved {
			waiting.removeAll { Self.matches($0, callId, sessionId) }
			markSent(callId: callId, sessionId: sessionId)
			return .sendNow(resolved)
		}
		if !waiting.contains(where: { Self.matches($0, callId, sessionId) && $0.reason == reason }) {
			waiting.append(Waiting(callId: callId, sessionId: sessionId, reason: reason))
		}
		return .wait
	}

	/// An offer resolved: when its busy reject was waiting, take it to send now.
	mutating func offerResolved(callId: String, sessionId: String) -> Waiting? {
		guard let i = waiting.firstIndex(where: { Self.matches($0, callId, sessionId) }) else { return nil }
		let hit = waiting.remove(at: i)
		markSent(callId: hit.callId, sessionId: hit.sessionId)
		markSent(callId: callId, sessionId: sessionId)
		return hit
	}

	/// Our own call ended (we or the peer hung up): everything still waiting goes now.
	mutating func ownCallEnded() -> [Waiting] {
		let all = waiting
		waiting.removeAll()
		for item in all { markSent(callId: item.callId, sessionId: item.sessionId) }
		return all
	}

	func wasSent(callId: String, sessionId: String) -> Bool {
		(!callId.isEmpty && sent.contains(callId)) || (!sessionId.isEmpty && sent.contains(sessionId))
	}

	private mutating func markSent(callId: String, sessionId: String) {
		for id in [callId, sessionId] where !id.isEmpty && !sent.contains(id) {
			sent.append(id)
		}
		if sent.count > Self.sentMemory { sent.removeFirst(sent.count - Self.sentMemory) }
	}

	private static func matches(_ w: Waiting, _ id: String, _ session: String) -> Bool {
		(!id.isEmpty && (w.callId == id || w.sessionId == id))
			|| (!session.isEmpty && (w.sessionId == session || w.callId == session))
	}
}
