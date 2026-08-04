//
//  CashTreesNativeAppStateBridge.swift
//  CashTrees_iOS
//
//  PWA → Native generic app state (footer badges, app icon badge, background chat local push).
//

import Foundation
import UIKit
import UserNotifications

extension Notification.Name {
	static let cashTreesAppLifecycle = Notification.Name("cashTreesAppLifecycle")
}

enum CashTreesNativeAppStateBridge {
	private static let backgroundChatNotifyId = "beamio.chat.background"

	static func applyFromWebPayload(_ state: [String: Any]?) {
		let badge = resolveAppIconBadge(from: state)
		applyAppIconBadge(badge)

		// When PWA is backgrounded but still running, remote APNs often will not fire
		// (mailbox still sees the SSE client). Present a local system notification + badge.
		if let push = state?["backgroundChatNotify"] as? [String: Any] {
			let title = (push["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
			let body = (push["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
			let present = push["present"] as? Bool ?? true
			if present {
				presentBackgroundChatNotification(
					badge: badge,
					title: (title?.isEmpty == false ? title! : "Beamio"),
					body: (body?.isEmpty == false ? body! : defaultChatBody(for: badge))
				)
			}
		}
	}

	/// Explicit bridge action (same payload as `backgroundChatNotify` inside publishAppState).
	static func notifyBackgroundChat(from body: [String: Any]?) {
		let badge = parseNonNegativeInt(body?["badge"])
			?? parseNonNegativeInt(body?["appIconBadge"])
			?? 0
		let title = (body?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
		let message = (body?["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
		applyAppIconBadge(badge)
		presentBackgroundChatNotification(
			badge: badge,
			title: (title?.isEmpty == false ? title! : "Beamio"),
			body: (message?.isEmpty == false ? message! : defaultChatBody(for: badge))
		)
	}

	private static func defaultChatBody(for badge: Int) -> String {
		if badge <= 0 { return "New message" }
		if badge == 1 { return "1 new message" }
		return "\(badge) new messages"
	}

	private static func resolveAppIconBadge(from state: [String: Any]?) -> Int {
		guard let state else { return 0 }
		if let explicit = parseNonNegativeInt(state["appIconBadge"]) {
			return explicit
		}
		if let footer = state["footerBadges"] as? [String: Any],
		   let chat = parseNonNegativeInt(footer["chat"]) {
			return chat
		}
		return 0
	}

	private static func parseNonNegativeInt(_ value: Any?) -> Int? {
		switch value {
		case let v as Int:
			return max(0, min(v, 999))
		case let v as NSNumber:
			return max(0, min(v.intValue, 999))
		case let v as Double:
			return max(0, min(Int(v), 999))
		case let v as String:
			guard let n = Int(v.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
			return max(0, min(n, 999))
		default:
			return nil
		}
	}

	static func applyAppIconBadge(_ count: Int) {
		let safe = max(0, min(count, 999))
		DispatchQueue.main.async {
			if #available(iOS 16.0, *) {
				setBadgeCountModern(safe)
			} else {
				UIApplication.shared.applicationIconBadgeNumber = safe
			}
		}
	}

	@available(iOS 16.0, *)
	private static func setBadgeCountModern(_ count: Int) {
		let center = UNUserNotificationCenter.current()
		center.getNotificationSettings { settings in
			switch settings.authorizationStatus {
			case .notDetermined:
				center.requestAuthorization(options: [.badge, .alert, .sound]) { granted, _ in
					guard granted else { return }
					center.setBadgeCount(count) { _ in }
				}
			case .authorized, .provisional, .ephemeral:
				center.setBadgeCount(count) { _ in }
			case .denied:
				break
			@unknown default:
				break
			}
		}
	}

	private static func presentBackgroundChatNotification(badge: Int, title: String, body: String) {
		let center = UNUserNotificationCenter.current()
		center.getNotificationSettings { settings in
			let deliver: () -> Void = {
				let content = UNMutableNotificationContent()
				content.title = title
				content.body = body
				content.sound = .default
				if badge > 0 {
					content.badge = NSNumber(value: badge)
				}
				let request = UNNotificationRequest(
					identifier: backgroundChatNotifyId,
					content: content,
					trigger: nil
				)
				center.add(request, withCompletionHandler: nil)
			}

			switch settings.authorizationStatus {
			case .notDetermined:
				center.requestAuthorization(options: [.badge, .alert, .sound]) { granted, _ in
					guard granted else { return }
					DispatchQueue.main.async(execute: deliver)
				}
			case .authorized, .provisional, .ephemeral:
				DispatchQueue.main.async(execute: deliver)
			case .denied:
				break
			@unknown default:
				break
			}
		}
	}
}
