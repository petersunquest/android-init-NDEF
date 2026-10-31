import Intents
import UIKit

/// CallKit's in-call "Video" button (shown enabled because the provider sets
/// `supportsVideo = true`).
///
/// CallKit cannot show third-party video and sends no `CXAction` for this
/// button. On the lock screen iOS asks the user to unlock, then opens Beamio
/// with an `INStartCallIntent` (video capability) or legacy
/// `INStartVideoCallIntent` user activity for the call's handle. We read it as
/// "turn on my video in the current call": raise the Beamio call screen and
/// run the same FaceTime toggle as the in-app Video button. The peer sees it
/// through the existing `voice_video_enable_v1` control + BJPG frames.
enum BeamioCallKitVideoButton {
	/// Activity types SwiftUI should route here (see `CashTrees_iOSApp`).
	static let activityTypes = ["INStartCallIntent", "INStartVideoCallIntent"]

	/// A request waits for the app to become active (the camera only runs in
	/// the foreground) and, on the dialer side, for the callee to accept.
	private static var pendingCallId: String?
	private static var pendingAt = Date.distantPast
	private static var activeObserver: NSObjectProtocol?
	/// Drop a request the user never followed up on, so the camera does not
	/// turn on long after the tap.
	private static let pendingLifetime: TimeInterval = 45

	static func isVideoRequest(_ activity: NSUserActivity) -> Bool {
		if activity.activityType == "INStartVideoCallIntent" { return true }
		guard let intent = activity.interaction?.intent else { return false }
		if let call = intent as? INStartCallIntent {
			return call.callCapability == .videoCall
		}
		// INStartVideoCallIntent is deprecated; match by class name.
		return String(describing: type(of: intent)) == "INStartVideoCallIntent"
	}

	/// Returns true when the activity was a video request for the live call.
	@discardableResult
	static func handle(_ activity: NSUserActivity, source: String) -> Bool {
		guard Thread.isMainThread else {
			DispatchQueue.main.async { handle(activity, source: source) }
			return false
		}
		let isVideo = isVideoRequest(activity)
		let model = BeamioInCallScreenModel.shared
		let handleLength = (activity.interaction?.intent as? INStartCallIntent)?
			.contacts?.first?.personHandle?.value?.count ?? -1
		crumb(
			"callkit-video-activity:\(source):type=\(activity.activityType):video=\(isVideo ? "yes" : "no"):live=\(model.live ? "yes" : "no"):handleLen=\(handleLength):appState=\(UIApplication.shared.applicationState.rawValue)"
		)
		guard isVideo else { return false }
		guard model.live, !model.isPrepared else {
			// Not from our call screen (calls are kept out of Recents), so
			// there is no call to add video to.
			NSLog("[BeamioCallKitVideo] video activity ignored; no live call")
			return false
		}
		pendingCallId = model.callId
		pendingAt = Date()
		model.ensureSurfaceVisible(source: "callkit-video")
		firePendingIfReady(reason: source)
		return true
	}

	/// Dialer: the callee accepted, so a waiting request can start now.
	static func callDidConnect() {
		DispatchQueue.main.async { firePendingIfReady(reason: "connected") }
	}

	private static func firePendingIfReady(reason: String) {
		guard let callId = pendingCallId else { return }
		let model = BeamioInCallScreenModel.shared
		guard model.live, model.callId == callId,
		      Date().timeIntervalSince(pendingAt) < pendingLifetime
		else {
			crumb("callkit-video-drop:\(reason):live=\(model.live ? "yes" : "no")")
			clearPending()
			return
		}
		guard UIApplication.shared.applicationState == .active else {
			armActiveObserver()
			crumb("callkit-video-wait-active:\(reason)")
			return
		}
		guard model.connected else {
			crumb("callkit-video-wait-connected:\(reason)")
			return
		}
		clearPending()
		if model.localVideoOn || model.videoToggleBusy {
			crumb("callkit-video-already-on:\(reason)")
			return
		}
		crumb("callkit-video-start:\(reason):callId=\(callId.prefix(8))")
		model.toggleFaceTime()
	}

	private static func armActiveObserver() {
		guard activeObserver == nil else { return }
		activeObserver = NotificationCenter.default.addObserver(
			forName: UIApplication.didBecomeActiveNotification,
			object: nil,
			queue: .main
		) { _ in
			firePendingIfReady(reason: "becameActive")
		}
	}

	private static func clearPending() {
		pendingCallId = nil
		if let token = activeObserver {
			NotificationCenter.default.removeObserver(token)
			activeObserver = nil
		}
	}

	private static func crumb(_ line: String) {
		NSLog("[BeamioCallKitVideo] %@", line)
		BeamioVoipIncomingBootstrap.shared.callKit.writeBusyQaBreadcrumb(line)
		BeamioNativeVoiceSignaling.qaTrail(line)
	}
}
