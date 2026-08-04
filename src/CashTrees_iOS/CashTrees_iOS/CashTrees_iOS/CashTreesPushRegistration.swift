//
//  CashTreesPushRegistration.swift
//  CashTrees_iOS
//
//  APNs device token registration + PWA identity bind (EOA / pgpKeyId).
//

import Foundation
import UIKit
import UserNotifications

extension Notification.Name {
	static let cashTreesPushDeviceTokenUpdated = Notification.Name("cashTreesPushDeviceTokenUpdated")
}

enum CashTreesPushRegistration {
	private static let eoaKey = "cashTrees.push.boundEoa"
	private static let pgpKey = "cashTrees.push.boundPgpKeyId"
	private static let tokenKey = "cashTrees.push.deviceTokenHex"

	private(set) static var lastDeviceTokenHex: String? {
		get { UserDefaults.standard.string(forKey: tokenKey) }
		set {
			if let newValue, !newValue.isEmpty {
				UserDefaults.standard.set(newValue, forKey: tokenKey)
			} else {
				UserDefaults.standard.removeObject(forKey: tokenKey)
			}
		}
	}

	static var boundEoa: String? {
		get { UserDefaults.standard.string(forKey: eoaKey) }
		set {
			if let newValue, !newValue.isEmpty {
				UserDefaults.standard.set(newValue, forKey: eoaKey)
			} else {
				UserDefaults.standard.removeObject(forKey: eoaKey)
			}
		}
	}

	static var boundPgpKeyId: String? {
		get { UserDefaults.standard.string(forKey: pgpKey) }
		set {
			if let newValue, !newValue.isEmpty {
				UserDefaults.standard.set(newValue, forKey: pgpKey)
			} else {
				UserDefaults.standard.removeObject(forKey: pgpKey)
			}
		}
	}

	/// PWA `bindPushIdentity({ eoa, pgpKeyId? })`.
	static func bindIdentity(eoa: String?, pgpKeyId: String?) {
		let eoaTrim = eoa?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let pgpTrim = pgpKeyId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		boundEoa = eoaTrim.isEmpty ? nil : eoaTrim
		boundPgpKeyId = pgpTrim.isEmpty ? nil : pgpTrim
		requestAuthorizationAndRegister()
		notifyWebOfCachedTokenIfNeeded()
	}

	static func requestAuthorizationAndRegister() {
		let center = UNUserNotificationCenter.current()
		center.requestAuthorization(options: [.badge, .alert, .sound]) { granted, _ in
			guard granted else {
				CashTreesWebConsoleRelay.logNative("push auth denied or not granted")
				return
			}
			DispatchQueue.main.async {
				UIApplication.shared.registerForRemoteNotifications()
			}
		}
	}

	static func handleDidRegister(deviceToken: Data) {
		let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
		lastDeviceTokenHex = hex
		NotificationCenter.default.post(
			name: .cashTreesPushDeviceTokenUpdated,
			object: nil,
			userInfo: ["deviceToken": hex]
		)
	}

	static func handleDidFail(error: Error) {
		CashTreesWebConsoleRelay.logNative("push register failed: \(error.localizedDescription)")
	}

	static func notifyWebOfCachedTokenIfNeeded() {
		guard let hex = lastDeviceTokenHex, !hex.isEmpty else { return }
		NotificationCenter.default.post(
			name: .cashTreesPushDeviceTokenUpdated,
			object: nil,
			userInfo: ["deviceToken": hex]
		)
	}

	static func payloadForWebEvent(deviceToken hex: String) -> [String: Any] {
		var payload: [String: Any] = [
			"action": "pushDeviceToken",
			"deviceToken": hex,
			"platform": "ios",
			"bundleId": Bundle.main.bundleIdentifier ?? "com.beamio.beamio",
		]
		if let eoa = boundEoa { payload["eoa"] = eoa }
		if let pgp = boundPgpKeyId { payload["pgpKeyId"] = pgp }
		return payload
	}
}
