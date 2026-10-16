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
	/// Regular APNs `type=voiceCall` (alert fallback when PushKit VoIP is rejected).
	static let cashTreesIncomingVoiceCallPush = Notification.Name("cashTreesIncomingVoiceCallPush")
	/// Ask embedded PWA to re-run HTTP `registerPushDevice` (wallet may unlock late).
	static let cashTreesRequestWebPushFlush = Notification.Name("cashTreesRequestWebPushFlush")
}

enum CashTreesPushRegistration {
	private static let eoaKey = "cashTrees.push.boundEoa"
	private static let pgpKey = "cashTrees.push.boundPgpKeyId"
	private static let tokenKey = "cashTrees.push.deviceTokenHex"
	private static let voipTokenKey = "cashTrees.push.voipDeviceTokenHex"
	private static let alertApsEnvKey = "cashTrees.push.alertApsEnvironment"
	private static let voipApsEnvKey = "cashTrees.push.voipApsEnvironment"
	/// True after PushKit `didUpdate` in this process — cached VoIP from a prior
	/// App Store install must not flush until we get a live credential.
	private static var voipReceivedThisProcess = false
	/// Development cold-start may force-drop sticky production VoIP once.
	/// Must **not** re-run on every bind/flush — that wipes live PushKit hex
	/// before HTTP `registerPushDevice` and leaves force-quit CallKit dead.
	private static var didForceDevVoipDropThisProcess = false

	private(set) static var lastDeviceTokenHex: String? {
		get { UserDefaults.standard.string(forKey: tokenKey) }
		set {
			if let newValue, !newValue.isEmpty {
				UserDefaults.standard.set(newValue, forKey: tokenKey)
			} else {
				UserDefaults.standard.removeObject(forKey: tokenKey)
				UserDefaults.standard.removeObject(forKey: alertApsEnvKey)
			}
		}
	}

	/// PushKit VoIP token (distinct from regular APNs alert token). Required for CallKit Incoming.
	private(set) static var lastVoipDeviceTokenHex: String? {
		get { UserDefaults.standard.string(forKey: voipTokenKey) }
		set {
			if let newValue, !newValue.isEmpty {
				UserDefaults.standard.set(newValue, forKey: voipTokenKey)
			} else {
				UserDefaults.standard.removeObject(forKey: voipTokenKey)
				UserDefaults.standard.removeObject(forKey: voipApsEnvKey)
			}
		}
	}

	/// Signed `aps-environment` from the embedded provisioning profile
	/// (Dev profile → `development` even when Release.entitlements say
	/// production). App Store builds strip `embedded.mobileprovision` →
	/// fallback `production`.
	static func signedApsEnvironment() -> String {
		guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
		      let data = try? Data(contentsOf: url),
		      let ascii = String(data: data, encoding: .isoLatin1),
		      let start = ascii.range(of: "<?xml"),
		      let end = ascii.range(of: "</plist>")
		else {
			return "production"
		}
		let plistString = String(ascii[start.lowerBound...end.upperBound])
		guard let plistData = plistString.data(using: .utf8),
		      let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
		      let entitlements = plist["Entitlements"] as? [String: Any],
		      let value = entitlements["aps-environment"] as? String,
		      value == "production" || value == "development"
		else {
			return "development"
		}
		return value
	}

	/// Drop UserDefaults tokens minted for a **mismatched** APS host only
	/// (e.g. App Store production hex on a development-signed build).
	///
	/// Untagged caches are **adopted** (tagged as current env), never wiped.
	/// Launch-time untagged drop raced PushKit remint: wipe → tear registry →
	/// no `didUpdate` → empty `ios_voip` forever → force-quit CallKit never wakes.
	@discardableResult
	static func invalidateStalePushTokensForSignedApsEnvironment() -> Bool {
		let current = signedApsEnvironment()
		var dropped = false
		_ = didForceDevVoipDropThisProcess // retained for binary compat / future use
		if lastVoipDeviceTokenHex != nil {
			let stored = UserDefaults.standard.string(forKey: voipApsEnvKey)
			if voipReceivedThisProcess {
				// keep live PushKit credential
			} else if let stored, stored != current {
				NSLog(
					"[CashTreesPush] drop voip token — aps env %@ → %@ (mismatch)",
					stored,
					current
				)
				lastVoipDeviceTokenHex = nil
				voipReceivedThisProcess = false
				dropped = true
			} else if stored == nil {
				UserDefaults.standard.set(current, forKey: voipApsEnvKey)
				NSLog("[CashTreesPush] tag voip as %@ (adopt untagged)", current)
			}
		}
		if lastDeviceTokenHex != nil {
			let stored = UserDefaults.standard.string(forKey: alertApsEnvKey)
			if let stored, stored != current {
				NSLog(
					"[CashTreesPush] drop alert token — aps env %@ → %@ (mismatch)",
					stored,
					current
				)
				lastDeviceTokenHex = nil
				dropped = true
			} else if stored == nil {
				UserDefaults.standard.set(current, forKey: alertApsEnvKey)
				NSLog("[CashTreesPush] tag alert as %@ (adopt untagged)", current)
			}
		}
		return dropped
	}

	/// True when we have **no** VoIP hex to flush to the PWA.
	/// Do **not** require `voipReceivedThisProcess` — cold start often has a valid
	/// UserDefaults hex before PushKit re-fires; treating that as "refresh needed"
	/// tore down PushKit, wiped the hex, and left force-quit CallKit unable to wake.
	static var needsVoipCredentialRefresh: Bool {
		let hex = (lastVoipDeviceTokenHex ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		guard !hex.isEmpty else { return true }
		let current = signedApsEnvironment()
		let stored = UserDefaults.standard.string(forKey: voipApsEnvKey)
		return stored != nil && stored != current
	}

	/// Live PushKit hex minted in this process — forceRefresh must not tear it down.
	static var hasLiveVoipCredentialThisProcess: Bool {
		voipReceivedThisProcess && !(lastVoipDeviceTokenHex ?? "").isEmpty
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

	/// Clear **alert** APNs only. VoIP PushKit must survive bind — PushKit does
	/// **not** reliably re-fire `credentialsUpdated` after a clear, so wiping
	/// voip left the PWA without `ios_voip` and force-quit CallKit never woke.
	static func clearCachedAlertApnsToken() {
		lastDeviceTokenHex = nil
		NSLog("[CashTreesPush] cleared cached ios (alert) token")
	}

	/// Drop both alert + VoIP (logout / recovery only — **not** bindIdentity).
	static func clearCachedApnsTokens() {
		lastDeviceTokenHex = nil
		lastVoipDeviceTokenHex = nil
		NSLog("[CashTreesPush] cleared cached ios + ios_voip tokens")
	}

	/// PWA `bindPushIdentity({ eoa, pgpKeyId? })`.
	/// Keeps the PushKit VoIP token and immediately re-dispatches it so the PWA
	/// can register `platform: ios_voip` (required for force-quit CallKit wake).
	static func bindIdentity(eoa: String?, pgpKeyId: String?) {
		let eoaTrim = eoa?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let pgpTrim = pgpKeyId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		boundEoa = eoaTrim.isEmpty ? nil : eoaTrim
		boundPgpKeyId = pgpTrim.isEmpty ? nil : pgpTrim
		// Flush existing hex FIRST so PWA can HTTP-register for CallKit wake.
		// Do not clear alert/voip on every bind — that raced PushKit and wiped
		// pending tokens before EIP-191 register completed.
		notifyWebOfCachedVoipTokenIfNeeded()
		notifyWebOfCachedTokenIfNeeded()
		// Only tear down PushKit when we truly have no usable voip hex.
		if needsVoipCredentialRefresh {
			BeamioVoipIncomingBootstrap.shared.forceRefreshVoipCredentials()
		}
		requestAuthorizationAndRegister()
		// Soft register — do NOT unregister on every bind (that wiped tokens
		// mid-HTTP-register and left force-quit CallKit with empty ios_voip).
		ensureRemoteNotificationsRegistered(dropCache: needsVoipCredentialRefresh)
		for delay in [2.0, 5.0, 12.0, 25.0] {
			DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
				notifyWebOfCachedVoipTokenIfNeeded()
				notifyWebOfCachedTokenIfNeeded()
				NotificationCenter.default.post(name: .cashTreesRequestWebPushFlush, object: nil)
			}
		}
	}

	/// Flush cached alert + VoIP tokens to the WebView (webContentReady / bind).
	static func flushCachedTokensToWeb() {
		notifyWebOfCachedVoipTokenIfNeeded()
		notifyWebOfCachedTokenIfNeeded()
	}

	static func requestAuthorizationAndRegister() {
		let center = UNUserNotificationCenter.current()
		center.requestAuthorization(options: [.badge, .alert, .sound]) { granted, _ in
			if !granted {
				CashTreesWebConsoleRelay.logNative("push auth denied or not granted")
			}
			DispatchQueue.main.async {
				ensureRemoteNotificationsRegistered(dropCache: false)
			}
		}
	}

	/// Unconditional APNs re-register (Dev install / install-over token refresh).
	static func forceRegisterForRemoteNotifications() {
		DispatchQueue.main.async {
			ensureRemoteNotificationsRegistered(dropCache: true)
		}
	}

	/// Register for APNs. Only unregister→re-register when `dropCache` (stale APS
	/// env / install-over). Routine bind must keep the live token so PWA HTTP
	/// `registerPushDevice` can write `ios` / `ios_voip` for CallKit wake.
	private static func ensureRemoteNotificationsRegistered(dropCache: Bool) {
		if dropCache {
			UIApplication.shared.unregisterForRemoteNotifications()
			CashTreesWebConsoleRelay.logNative("push unregister then re-register")
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
				UIApplication.shared.registerForRemoteNotifications()
				CashTreesWebConsoleRelay.logNative(
					"push registerForRemoteNotifications boundEoa=\(boundEoa ?? "none")"
				)
			}
			return
		}
		UIApplication.shared.registerForRemoteNotifications()
		CashTreesWebConsoleRelay.logNative(
			"push registerForRemoteNotifications (keep cache) boundEoa=\(boundEoa ?? "none")"
		)
	}

	static func handleDidRegister(deviceToken: Data) {
		let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
		let env = signedApsEnvironment()
		lastDeviceTokenHex = hex
		UserDefaults.standard.set(env, forKey: alertApsEnvKey)
		CashTreesWebConsoleRelay.logNative(
			"push didRegister ios aps=\(env) token=\(hex.prefix(16))…\(hex.suffix(4)) len=\(hex.count)"
		)
		NSLog("[CashTreesPush] didRegister ios aps=%@ token=%@…", env, String(hex.prefix(12)))
		NotificationCenter.default.post(
			name: .cashTreesPushDeviceTokenUpdated,
			object: nil,
			userInfo: ["deviceToken": hex, "platform": "ios"]
		)
	}

	/// Parse APNs / local notification userInfo for voiceCall → CallKit bridge.
	@discardableResult
	static func postIncomingVoiceCallIfPresent(from userInfo: [AnyHashable: Any]) -> Bool {
		let type = (userInfo["type"] as? String) ?? ""
		guard type == "voiceCall" else { return false }
		let callId = (userInfo["callId"] as? String)
			?? (userInfo["call_id"] as? String)
			?? ""
		guard !callId.isEmpty else { return false }
		let sessionId = (userInfo["sessionId"] as? String)
			?? (userInfo["session_id"] as? String)
			?? ""
		let peerAddress = (userInfo["peerAddress"] as? String)
			?? (userInfo["peer_address"] as? String)
			?? ""
		let displayName = (userInfo["displayName"] as? String)
			?? (peerAddress.isEmpty ? nil : peerAddress)
			?? "Beamio call"
		let claimedTag = (userInfo["claimedTag"] as? String)
			?? (userInfo["claimed_tag"] as? String)
			?? ""
		NSLog(
			"[CashTreesPush] voiceCall alert callId=%@ sessionId=%@ name=%@",
			callId,
			sessionId,
			displayName
		)
		let info: [AnyHashable: Any] = [
			"callId": callId,
			"sessionId": sessionId,
			"peerAddress": peerAddress,
			"displayName": displayName,
			"claimedTag": claimedTag,
		]
		// Report CallKit immediately (works while force-quit / before WebView).
		BeamioVoipIncomingBootstrap.shared.reportFromUserInfo(info)
		NotificationCenter.default.post(
			name: .cashTreesIncomingVoiceCallPush,
			object: nil,
			userInfo: info
		)
		return true
	}

	static func handleDidFail(error: Error) {
		CashTreesWebConsoleRelay.logNative("push register failed: \(error.localizedDescription)")
	}

	static func notifyWebOfCachedTokenIfNeeded() {
		guard let hex = lastDeviceTokenHex, !hex.isEmpty else { return }
		NotificationCenter.default.post(
			name: .cashTreesPushDeviceTokenUpdated,
			object: nil,
			userInfo: ["deviceToken": hex, "platform": "ios"]
		)
	}

	static func handleVoipDidRegister(deviceTokenHex hex: String) {
		let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard !trimmed.isEmpty else { return }
		let env = signedApsEnvironment()
		lastVoipDeviceTokenHex = trimmed
		UserDefaults.standard.set(env, forKey: voipApsEnvKey)
		voipReceivedThisProcess = true
		CashTreesWebConsoleRelay.logNative(
			"push didRegister ios_voip aps=\(env) token=\(trimmed.prefix(16))…\(trimmed.suffix(4))"
		)
		NSLog("[CashTreesPush] didRegister ios_voip aps=%@ token=%@…", env, String(trimmed.prefix(12)))
		NotificationCenter.default.post(
			name: .cashTreesPushDeviceTokenUpdated,
			object: nil,
			userInfo: ["deviceToken": trimmed, "platform": "ios_voip"]
		)
	}

	static func clearVoipDeviceToken() {
		lastVoipDeviceTokenHex = nil
		voipReceivedThisProcess = false
	}

	/// Re-post VoIP hex to the WebView for HTTP `ios_voip` register.
	/// Never invalidate/wipe here — cold-start flush used to drop the only VoIP
	/// hex before PushKit re-minted, so PWA never HTTP-registered `ios_voip`.
	static func notifyWebOfCachedVoipTokenIfNeeded() {
		guard let hex = lastVoipDeviceTokenHex, !hex.isEmpty else {
			NSLog(
				"[CashTreesPush] skip VoIP re-notify — no voip hex (thisProcess=%d)",
				voipReceivedThisProcess ? 1 : 0
			)
			return
		}
		NotificationCenter.default.post(
			name: .cashTreesPushDeviceTokenUpdated,
			object: nil,
			userInfo: ["deviceToken": hex, "platform": "ios_voip"]
		)
		NSLog(
			"[CashTreesPush] re-notify VoIP token hexPrefix=%@ live=%d",
			String(hex.prefix(16)),
			voipReceivedThisProcess ? 1 : 0
		)
	}

	static func payloadForWebEvent(deviceToken hex: String, platform: String = "ios") -> [String: Any] {
		let isVoip = platform == "ios_voip"
		var payload: [String: Any] = [
			"action": "pushDeviceToken",
			"token": hex,
			"deviceToken": hex,
			"platform": isVoip ? "ios_voip" : "ios",
			"bundleId": Bundle.main.bundleIdentifier ?? "com.beamio.beamio",
			"fullScreenIntent": true,
			"callKit": true,
			"nativeCallUi": true,
		]
		if let eoa = boundEoa { payload["eoa"] = eoa }
		if let pgp = boundPgpKeyId { payload["pgpKeyId"] = pgp }
		return payload
	}
}
