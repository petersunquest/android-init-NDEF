import CallKit
import ConetChatSDK
import Foundation

/// Call layer side of the native chat module's mailbox listen.
///
/// - While a call rings, dials or is up, the page's `pause` is deferred, so the
///   listen stays connected (other senders' messages and the peer's call
///   control keep arriving).
/// - A VoIP push wakes the listen from the stored identity without waiting for
///   the page (`wakeForCallPush` → `BeamioConetChatModule.wake`); a call that
///   ends releases it.
/// - The module recognises a peer's `voice_end_v1` / `voice_call_timeout_v1`
///   Chat message and hands it to `applyPeerCallControl` (same rule as Android).
/// - Every module event still reaches `observeChatEvent` (offers, status trail).
enum BeamioNativeChatHooks {
	private static var installed = false
	private static let callObserver = CXCallObserver()
	private static let callDelegate = CallEndDelegate()

	private final class CallEndDelegate: NSObject, CXCallObserverDelegate {
		func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
			if call.hasEnded { BeamioConetChatModule.release(reason: "callEnded") }
		}
	}

	/// Main queue.
	static func install() {
		guard !installed else { return }
		installed = true
		callObserver.setDelegate(callDelegate, queue: .main)
		BeamioConetChatModule.keepListenWhile = {
			callObserver.calls.contains { !$0.hasEnded }
		}
		BeamioConetChatModule.callControlObserver = { type, callId, sessionId, from in
			BeamioNativeVoiceSignaling.applyPeerCallControl(type: type, callId: callId, sessionId: sessionId, from: from)
		}
		BeamioConetChatModule.nativeObserver = { payload in
			BeamioNativeVoiceSignaling.observeChatEvent(payload)
		}
	}

	/// VoIP ring: open the mailbox listen now, page or not. Main queue.
	static func wakeForCallPush() {
		install()
		let started = BeamioConetChatModule.wake(reason: "incomingCall")
		BeamioNativeVoiceSignaling.qaTrail("chat listen for call push started=\(started)")
	}
}
