import Foundation
import UserNotifications

/// The server sends a visible APNs alert ("Incoming call · Beamio voice call",
/// `type=voiceCall`) next to the VoIP push, as a fallback that wakes CallKit.
/// CallKit shows the call itself, so the alert must not stay in Notification
/// Center once the call is over (SE 2026-11-04: still there after the caller
/// cancelled).
nonisolated enum BeamioCallAlertTray {
	/// One delivered notification, reduced to what the filter needs.
	struct Delivered: Equatable {
		let identifier: String
		let type: String
		let callId: String
	}

	static func delivered(identifier: String, userInfo: [AnyHashable: Any]) -> Delivered {
		Delivered(
			identifier: identifier,
			type: (userInfo["type"] as? String) ?? "",
			callId: (userInfo["callId"] as? String) ?? (userInfo["call_id"] as? String) ?? ""
		)
	}

	/// Call alerts whose call is no longer ringing or connected in CallKit.
	static func staleIdentifiers(_ notes: [Delivered], liveCallIds: Set<String>) -> [String] {
		notes
			.filter { $0.type == "voiceCall" && !liveCallIds.contains($0.callId) }
			.map(\.identifier)
	}

	/// Remove call alerts for calls that are not live. `liveCallIds` is read on
	/// the main queue by the caller.
	static func removeStale(liveCallIds: Set<String>, reason: String) {
		UNUserNotificationCenter.current().getDeliveredNotifications { notes in
			let ids = staleIdentifiers(
				notes.map { delivered(identifier: $0.request.identifier, userInfo: $0.request.content.userInfo) },
				liveCallIds: liveCallIds
			)
			guard !ids.isEmpty else { return }
			UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
			NSLog("[BeamioCallAlertTray] removed %ld call alert(s) reason=%@", ids.count, reason)
		}
	}
}
