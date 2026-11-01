import UIKit
import UserNotifications

/// The peer turned on video while Beamio sits behind CallKit's call screen
/// (lock-screen answer, or the user stayed on the system call screen).
///
/// iOS gives an app no way to unlock the phone or move itself in front of the
/// CallKit screen. A tap is required: the CallKit Beamio icon or Video button,
/// or this local notification. A tap on the notification (after unlock when
/// locked) opens Beamio; the Beamio call screen then shows the peer's video.
///
/// Privacy: the text names only the verified @BeamioTag, never a wallet
/// address or message content.
enum BeamioPeerVideoNotice {
	static let notificationType = "beamioPeerVideo"
	private static let requestId = "beamio-peer-video"

	/// Call the shown notice belongs to; one notice per peer video start.
	private static var shownForCallId: String?
	/// Call whose peer video the user has already seen (tapped the notice, or
	/// Beamio was in front). Peers re-send the enable control several times a
	/// second, so without this the notice came back right after a tap.
	private static var seenForCallId: String?
	private static var activeObserver: NSObjectProtocol?

	/// Main thread. Called when the peer's video turns on or off.
	static func peerVideoChanged(enabled: Bool) {
		guard enabled else {
			// A later "video on" deserves a new notice.
			seenForCallId = nil
			clear(reason: "peer-off")
			return
		}
		let model = BeamioInCallScreenModel.shared
		guard model.live, !model.callId.isEmpty else { return }
		guard shownForCallId != model.callId, seenForCallId != model.callId else { return }
		let state = UIApplication.shared.applicationState
		if state == .active {
			// Beamio is in front: the call screen shows the video.
			seenForCallId = model.callId
			crumb("peer-video-notice-skip:active")
			return
		}
		// Inactive is a short transition (unlock, CallKit banner); the next
		// re-sent enable decides once the state settles.
		guard state == .background else { return }
		shownForCallId = model.callId
		armActiveObserver()

		let content = UNMutableNotificationContent()
		content.title = "Beamio"
		if let tag = BeamioIncomingCallPayload.normalizedBeamioTag(model.tag) {
			content.body = "\(tag) turned on video. Tap to watch."
		} else {
			content.body = "Video is on in your call. Tap to watch."
		}
		// No sound: call audio is playing.
		content.sound = nil
		content.userInfo = ["type": notificationType]
		let hasTag = !model.tag.isEmpty
		let request = UNNotificationRequest(identifier: requestId, content: content, trigger: nil)
		let center = UNUserNotificationCenter.current()
		center.add(request) { error in
			// Without alert permission iOS drops the notice silently; log why.
			center.getNotificationSettings { settings in
				crumb(
					"peer-video-notice-post:appState=\(state.rawValue):tag=\(hasTag ? "yes" : "no"):auth=\(settings.authorizationStatus.rawValue):alert=\(settings.alertSetting.rawValue):lock=\(settings.lockScreenSetting.rawValue):err=\(error == nil ? "-" : "yes")"
				)
			}
		}
	}

	/// The user tapped the notice. Returns true when it was ours.
	@discardableResult
	static func handleTap(userInfo: [AnyHashable: Any]) -> Bool {
		guard (userInfo["type"] as? String) == notificationType else { return false }
		DispatchQueue.main.async {
			let model = BeamioInCallScreenModel.shared
			crumb(
				"peer-video-notice-tap:live=\(model.live ? "yes" : "no"):appState=\(UIApplication.shared.applicationState.rawValue)"
			)
			if model.live {
				seenForCallId = model.callId
				model.ensureSurfaceVisible(source: "peer-video-notice")
			}
			clear(reason: "tap")
		}
		return true
	}

	/// Main thread. The call ended.
	static func callEnded() {
		seenForCallId = nil
		clear(reason: "call-end")
	}

	/// Main thread. Remove the notice (call ended, peer stopped, app active).
	static func clear(reason: String) {
		if let token = activeObserver {
			NotificationCenter.default.removeObserver(token)
			activeObserver = nil
		}
		guard shownForCallId != nil else { return }
		shownForCallId = nil
		let center = UNUserNotificationCenter.current()
		center.removeDeliveredNotifications(withIdentifiers: [requestId])
		center.removePendingNotificationRequests(withIdentifiers: [requestId])
		crumb("peer-video-notice-clear:\(reason)")
	}

	/// Once Beamio is in front, its call screen shows the video; drop the notice.
	private static func armActiveObserver() {
		guard activeObserver == nil else { return }
		activeObserver = NotificationCenter.default.addObserver(
			forName: UIApplication.didBecomeActiveNotification,
			object: nil,
			queue: .main
		) { _ in
			let model = BeamioInCallScreenModel.shared
			if model.live { seenForCallId = model.callId }
			clear(reason: "app-active")
		}
	}

	private static func crumb(_ line: String) {
		NSLog("[BeamioPeerVideo] %@", line)
		BeamioVoipIncomingBootstrap.shared.callKit.writeBusyQaBreadcrumb(line)
		BeamioNativeVoiceSignaling.qaTrail(line)
	}
}
