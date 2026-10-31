import ConetChatSDK
import Foundation

/// Resolve CallKit / Incoming identity for a killed-app VoIP wake:
/// opaque push → `voice_offer_fetch` encrypted to mailbox route PGP →
/// `POST http://{entryIp}/post` (shell picks an IP ≠ mailbox B) → decrypt with
/// Keychain user PGP → EIP-191 `callerSignature` → exact-address BeamioTag.
enum BeamioVoiceOfferIdentity {
	struct Resolved: Equatable {
		var callerEoa: String
		var beamioTag: String
		var shortAddress: String
		var callId: String
		var sessionId: String
		/// Offer AES-GCM key (base64 32 bytes) — required for native Decline uplink.
		var sessionKey: String
		/// Offer `to` (local callee EOA when present).
		var to: String
	}

	/// Best-effort; failures leave CallKit on opaque "Beamio".
	static func resolve(
		callId: String,
		sessionId: String,
		completion: @escaping (Resolved?) -> Void
	) {
		guard !callId.isEmpty, sessionId.count >= 16,
		      let secrets = BeamioChatPgpKeychain.load(),
		      secrets.hasUserPrivate,
		      secrets.hasRoutePublic,
		      !Self.roster(from: secrets).isEmpty
		else {
			NSLog("[BeamioVoiceOffer] skip resolve — missing Keychain PGP/route/IP roster")
			completion(nil)
			return
		}

		fetchOfferArmor(callId: callId, sessionId: sessionId, secrets: secrets) { armor in
			guard let armor, armor.contains("BEGIN PGP MESSAGE") else {
				NSLog("[BeamioVoiceOffer] fetch failed callId=%@", callId)
				completion(nil)
				return
			}
			BeamioOpenPgpHost.shared.decrypt(armor: armor, privateKeyArmor: secrets.privateKeyArmor) { result in
				switch result {
				case .failure(let err):
					NSLog("[BeamioVoiceOffer] decrypt failed %@", err.localizedDescription)
					completion(nil)
				case .success(let plaintext):
					parseAndVerify(plaintext: plaintext, callId: callId, sessionId: sessionId, completion: completion)
				}
			}
		}
	}

	/// Live chat inbound (already decrypted + outer EIP-191 `from` recovered by
	/// the chat module). Same offer verify + BeamioTag path as mailbox fetch —
	/// used when VoIP wake already painted opaque "Beamio" and the offer
	/// arrives as a normal chat line before / instead of voice_offer_fetch.
	static func resolveFromInboundChatLine(
		line: String,
		from: String,
		completion: @escaping (Resolved?) -> Void
	) {
		let signer = from.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard signer.hasPrefix("0x"), signer.count == 42 else {
			completion(nil)
			return
		}
		parseAndVerify(
			plaintext: line,
			callId: "",
			sessionId: "",
			expectedCallerEoa: signer,
			completion: completion
		)
	}

	// MARK: - Fetch

	private static func fetchOfferArmor(
		callId: String,
		sessionId: String,
		secrets: BeamioChatPgpKeychain.Secrets,
		completion: @escaping (String?) -> Void
	) {
		let command: [String: Any] = [
			"command": "voice_offer_fetch",
			"callId": callId,
			"sessionId": sessionId,
			"timestamp": Int(Date().timeIntervalSince1970),
		]
		guard let cmdData = try? JSONSerialization.data(withJSONObject: command),
		      let cmdJson = String(data: cmdData, encoding: .utf8)
		else {
			completion(nil)
			return
		}
		// SI peel: JSON.parse(Buffer.from(decrypted, 'base64')) — encrypt base64(JSON), not raw JSON.
		let opaque = Data(cmdJson.utf8).base64EncodedString()
		BeamioOpenPgpHost.shared.encrypt(plaintext: opaque, publicKeyArmor: secrets.routePublicKeyArmor) { enc in
			switch enc {
			case .failure(let err):
				NSLog("[BeamioVoiceOffer] encrypt fetch cmd failed %@", err.localizedDescription)
				completion(nil)
			case .success(let armor):
				DispatchQueue.global(qos: .utility).async {
					var exclude: Set<String> = []
					if let ip = BeamioSiCipherPost.normalizeIp(secrets.mailboxIp) {
						exclude.insert(ip)
					}
					// Keep wall-clock under CallKit identity bg-task (~18s):
					// 3 entries × 5s timeout. Default 4×12s was cancelled mid-POST
					// (status=0) when chrome suspended at 3.5s → banner stayed "Beamio".
					let result = BeamioSiCipherPost.post(
						armor: armor,
						nodes: Self.roster(from: secrets),
						excludeIps: exclude,
						maxAttempts: 3,
						timeout: 5
					)
					if !result.ok {
						NSLog(
							"[BeamioVoiceOffer] SiPost failed status=%d err=%@",
							result.status,
							result.error.isEmpty ? "-" : result.error
						)
					}
					let offer = Self.extractOfferArmor(result.body)
					DispatchQueue.main.async { completion(offer) }
				}
			}
		}
	}

	private static func roster(from secrets: BeamioChatPgpKeychain.Secrets) -> [BeamioChatPgpKeychain.SiNode] {
		if !secrets.siNodes.isEmpty { return secrets.siNodes }
		return secrets.entryDomains.compactMap { raw in
			guard let ip = BeamioSiCipherPost.normalizeIp(raw) else { return nil }
			return BeamioChatPgpKeychain.SiNode(ip: ip, domain: "", region: "")
		}
	}

	private static func extractOfferArmor(_ text: String) -> String? {
		guard !text.isEmpty else { return nil }
		func fromObject(_ obj: [String: Any]) -> String? {
			guard obj["ok"] as? Bool == true,
			      let offer = obj["offerArmor"] as? String,
			      offer.contains("BEGIN PGP MESSAGE")
			else { return nil }
			return offer
		}
		if let data = text.data(using: .utf8),
		   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
		   let offer = fromObject(obj)
		{
			return offer
		}
		if let rangeStart = text.range(of: "{"),
		   let rangeEnd = text.range(of: "}", options: .backwards),
		   rangeStart.lowerBound < rangeEnd.upperBound
		{
			let slice = String(text[rangeStart.lowerBound..<rangeEnd.upperBound])
			if let sliceData = slice.data(using: .utf8),
			   let obj = try? JSONSerialization.jsonObject(with: sliceData) as? [String: Any],
			   let offer = fromObject(obj)
			{
				return offer
			}
		}
		return nil
	}

	// MARK: - Verify

	private static func parseAndVerify(
		plaintext: String,
		callId: String,
		sessionId: String,
		expectedCallerEoa: String? = nil,
		completion: @escaping (Resolved?) -> Void
	) {
		// Outer chat envelope may wrap the offer; walk nested `text` / flatten.
		guard let offer = extractVoiceOffer(from: plaintext) else {
			NSLog("[BeamioVoiceOffer] no voice_call_offer_v1 in plaintext")
			completion(nil)
			return
		}
		let claimedFrom = (offer["from"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let callerSig = (offer["callerSignature"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let canonical = buildCallerCanonicalText(offer: offer)
		guard !callerSig.isEmpty, !canonical.isEmpty else {
			NSLog("[BeamioVoiceOffer] missing callerSignature")
			completion(nil)
			return
		}
		BeamioOpenPgpHost.shared.verifyMessage(text: canonical, signature: callerSig) { verifyResult in
			switch verifyResult {
			case .failure(let err):
				NSLog("[BeamioVoiceOffer] verifyMessage failed %@", err.localizedDescription)
				completion(nil)
			case .success(let recovered):
				let eoa = recovered.trimmingCharacters(in: .whitespacesAndNewlines)
				guard eoa.lowercased().hasPrefix("0x"), eoa.count == 42 else {
					completion(nil)
					return
				}
				if let expected = expectedCallerEoa?.lowercased(), !expected.isEmpty,
				   expected != eoa.lowercased()
				{
					NSLog(
						"[BeamioVoiceOffer] outer signer=%@ != callerSignature=%@",
						expected,
						eoa
					)
					completion(nil)
					return
				}
				if !claimedFrom.isEmpty, claimedFrom.lowercased() != eoa.lowercased() {
					NSLog(
						"[BeamioVoiceOffer] claimed from=%@ != recovered=%@",
						claimedFrom,
						eoa
					)
				}
				let sessionKey = (offer["sessionKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
				let toField = (offer["to"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
				let offerCallId = (offer["callId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
				let offerSessionId = (offer["sessionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
				BeamioTagAddressLookup.fetchExactTag(for: eoa) { tag in
					let resolved = Resolved(
						callerEoa: eoa,
						beamioTag: tag ?? "",
						shortAddress: BeamioIncomingAddressFormat.short(eoa),
						callId: (offerCallId?.isEmpty == false ? offerCallId! : callId),
						sessionId: (offerSessionId?.isEmpty == false ? offerSessionId! : sessionId),
						sessionKey: sessionKey,
						to: toField
					)
					BeamioNativeVoiceSignaling.rememberOffer(resolved)
					NSLog(
						"[BeamioVoiceOffer] resolved callId=%@ tag=%@ short=%@ hasSessionKey=%@",
						resolved.callId.isEmpty ? callId : resolved.callId,
						resolved.beamioTag.isEmpty ? "-" : resolved.beamioTag,
						resolved.shortAddress,
						sessionKey.isEmpty ? "no" : "yes"
					)
					completion(resolved)
				}
			}
		}
	}

	private static func extractVoiceOffer(from plaintext: String) -> [String: Any]? {
		func walk(_ value: Any, depth: Int) -> [String: Any]? {
			guard depth < 8 else { return nil }
			if let dict = value as? [String: Any] {
				if let type = dict["type"] as? String, type == "voice_call_offer_v1" {
					return dict
				}
				if let text = dict["text"] as? String,
				   let nested = parseJsonObject(text)
				{
					if let hit = walk(nested, depth: depth + 1) { return hit }
				}
				for (_, v) in dict {
					if let hit = walk(v, depth: depth + 1) { return hit }
				}
			}
			if let s = value as? String, let nested = parseJsonObject(s) {
				return walk(nested, depth: depth + 1)
			}
			return nil
		}
		if let root = parseJsonObject(plaintext) {
			return walk(root, depth: 0)
		}
		// The offer armor is a Chat envelope: the PGP literal is base64(UTF-8 JSON),
		// exactly like every other Chat message (web worker and PWA both encode it
		// so). Decoding it here was missing, so a fetched offer never parsed and the
		// killed-app call stayed anonymous.
		let compact = plaintext.trimmingCharacters(in: .whitespacesAndNewlines)
		if let data = Data(base64Encoded: compact, options: [.ignoreUnknownCharacters])
			?? BeamioLenientBase64.decode(compact),
		   let text = String(data: data, encoding: .utf8),
		   let root = parseJsonObject(text)
		{
			return walk(root, depth: 0)
		}
		return nil
	}

	private static func parseJsonObject(_ s: String) -> [String: Any]? {
		guard let data = s.data(using: .utf8),
		      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return nil }
		return obj
	}

	/// Canonical text for `callerSignature` (no from / tag / signature itself).
	private static func buildCallerCanonicalText(offer: [String: Any]) -> String {
		func s(_ key: String) -> String {
			if let v = offer[key] as? String { return v }
			if let n = offer[key] as? NSNumber { return n.stringValue }
			return ""
		}
		func n(_ key: String) -> String {
			if let i = offer[key] as? Int { return String(i) }
			if let d = offer[key] as? Double { return String(Int(d)) }
			if let num = offer[key] as? NSNumber { return num.stringValue }
			if let str = offer[key] as? String { return str }
			return ""
		}
		let entryDomains: String = {
			if let arr = offer["entryDomains"] as? [String] {
				return arr.joined(separator: ",")
			}
			if let arr = offer["entryDomains"] as? [Any] {
				return arr.compactMap { $0 as? String }.joined(separator: ",")
			}
			return s("entryDomains")
		}()
		let to = s("to").lowercased()
		let temp = s("tempWalletAddress").lowercased()
		return [
			"CoNET voice_call_offer_v1",
			"callId:\(s("callId"))",
			"sessionId:\(s("sessionId"))",
			"to:\(to)",
			"createdAt:\(n("createdAt"))",
			"expiresAt:\(n("expiresAt"))",
			"timestamp:\(n("timestamp"))",
			"sessionKey:\(s("sessionKey"))",
			"tempWalletAddress:\(temp)",
			"entryDomains:\(entryDomains)",
			"codec:\(s("codec"))",
		].joined(separator: "\n")
	}
}
