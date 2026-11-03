import CallKit
import ConetChatSDK
import Foundation
import UIKit

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
			// Warm entries stay ready while any call rings, dials or is up.
			if callObserver.calls.contains(where: { !$0.hasEnded }) {
				BeamioEntryPool.shared.hold("call")
			} else {
				BeamioEntryPool.shared.release("call")
				BeamioEntryPool.shared.release("incomingCall")
			}
		}
	}

	/// Main queue.
	static func install() {
		guard !installed else { return }
		installed = true
		// Start the SDK's warm entry pool (foreground / hold driven).
		_ = BeamioEntryPool.shared
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
		trackAppForeground()
	}

	/// The app does not run in the background: tell the chat module when the
	/// app goes to the background and comes back. The module pauses the
	/// mailbox listen in the background unless a call rings, dials or is up,
	/// and reconnects at once in the foreground. Main queue.
	private static func trackAppForeground() {
		let center = NotificationCenter.default
		center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
			BeamioConetChatModule.appDidEnterBackground(reason: "didEnterBackground")
		}
		center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
			BeamioConetChatModule.appWillEnterForeground(reason: "willEnterForeground")
		}
		// Launched by a VoIP push with no scene on screen: the app is in the background.
		if UIApplication.shared.applicationState == .background {
			BeamioConetChatModule.appDidEnterBackground(reason: "launchedInBackground")
		}
	}

	/// VoIP ring: open the mailbox listen now, page or not. Main queue.
	static func wakeForCallPush() {
		install()
		// Warm entries from the cached node table now; the chain check runs alongside.
		BeamioEntryPool.shared.hold("incomingCall")
		BeamioEntryPool.shared.warmNow()
		BeamioGuardianNodeWatch.shared.kick()
		let started = BeamioConetChatModule.wake(reason: "incomingCall")
		BeamioNativeVoiceSignaling.qaTrail("chat listen for call push started=\(started)")
	}
}
