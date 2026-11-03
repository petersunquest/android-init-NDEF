import ConetChatSDK
import Foundation
import Security

/// Voice protocol v3: paid temporary channels (wire spec: CoNET-SI `voiceForward.ts`,
/// PWA `vendor/conet-chat-sdk/src/voice-v3.ts`).
///
/// The callee creates four channels when it answers: caller voice / video
/// (`cv`, `cV`) and callee voice / video (`ev`, `eV`). Each has its own
/// temporary wallet T, AES key, write key and locator. The payer wallet signs T;
/// T signs every `voice_listen`, bound to the relay's route key ID. Each side
/// picks the relays for its own two channels. Nothing here is logged.
enum BeamioVoiceV3 {
	static let payValidSec: Int64 = 12 * 60 * 60

	/// A relay node: route key ID (= Guardian domain), IP, armored route key.
	struct Relay: Equatable {
		var domain: String
		var ip: String
		var armor: String
	}

	/// One channel's secrets (the receiver's AES key, HMAC write key, locator).
	struct Channel: Equatable {
		var sid: String
		var key: Data
		var wk: Data

		var locator: Data? { BeamioVoiceChannelV2.locator(fromSessionId: sid) }
		var keyB64: String { key.base64EncodedString() }
		var wkB64: String { wk.base64EncodedString() }
	}

	/// A channel this side listens on: temporary wallet and its payment proof.
	struct Own: Equatable {
		var channel: Channel
		/// T private key, 64 hex without 0x. Memory only.
		var tkHex: String
		var tempAddress: String
		/// `{payer, notAfter, maxBytes, maxSeconds, sig}` as JSON text.
		var payJson: String
		var relay: Relay?
	}

	/// A channel this side sends to.
	struct Peer: Equatable {
		var channel: Channel
		var relay: Relay?
	}

	struct Call: Equatable {
		var callId: String
		var ownVoice: Own
		var ownVideo: Own
		var peerVoice: Peer
		var peerVideo: Peer
	}

	// MARK: - Wire text (must match CoNET-SI)

	static func payText(temp: String, notAfter: Int64, maxBytes: Int64 = 0, maxSeconds: Int64 = 0) -> String {
		[
			"conet.voice.sse.pay.v3",
			"temp=\(temp.lowercased())",
			"notAfter=\(notAfter)",
			"maxBytes=\(maxBytes)",
			"maxSeconds=\(maxSeconds)",
		].joined(separator: "\n")
	}

	static func listenText(sid: String, wk: String, relayKeyId: String, timestamp: Int64) -> String {
		["conet.voice.sse.listen.v3", sid, wk, relayKeyId.uppercased(), String(timestamp)].joined(separator: "|")
	}

	// MARK: - Random material

	static func randomBytes(_ n: Int) -> Data {
		var bytes = [UInt8](repeating: 0, count: n)
		_ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
		return Data(bytes)
	}

	static func newChannel() -> Channel {
		Channel(
			sid: randomBytes(16).map { String(format: "%02x", $0) }.joined(),
			key: randomBytes(32),
			wk: randomBytes(32)
		)
	}

	// MARK: - Signing (BeamioOpenPgpHost; call off the main thread)

	private static func waitResult(seconds: Double = 10, _ run: (@escaping (Result<String, Error>) -> Void) -> Void) -> String? {
		let sem = DispatchSemaphore(value: 0)
		var out: String?
		run { result in
			out = try? result.get()
			sem.signal()
		}
		_ = sem.wait(timeout: .now() + seconds)
		return out
	}

	/// New temporary wallet T and the payer's signature over it. Blocking.
	static func newPaidChannel(payerKeyHex: String, payerEoa: String) -> Own? {
		let tk = randomBytes(32).map { String(format: "%02x", $0) }.joined()
		guard let temp = nativeOrWebView("address", native: { BeamioNativeEthSigner.address(privateKeyHex: tk) }, webView: {
			waitResult({ BeamioOpenPgpHost.shared.walletAddress(privateKeyHex: tk, completion: $0) })
		}) else { return nil }
		let notAfter = Int64(Date().timeIntervalSince1970) + payValidSec
		let text = payText(temp: temp, notAfter: notAfter)
		guard let sig = nativeOrWebView("pay", native: { BeamioNativeEthSigner.signEip191(privateKeyHex: payerKeyHex, message: text) }, webView: {
			waitResult({ BeamioOpenPgpHost.shared.signEip191(privateKeyHex: payerKeyHex, message: text, completion: $0) })
		}) else { return nil }
		let pay: [String: Any] = ["payer": payerEoa.lowercased(), "notAfter": notAfter, "maxBytes": 0, "maxSeconds": 0, "sig": sig]
		guard let data = try? JSONSerialization.data(withJSONObject: pay), let json = String(data: data, encoding: .utf8) else { return nil }
		return Own(channel: newChannel(), tkHex: tk, tempAddress: temp.lowercased(), payJson: json, relay: nil)
	}

	/// `voice_listen` v3 for one own channel on its relay. Blocking.
	static func listenCommand(_ own: Own, relay: Relay) -> [String: Any]? {
		let ts = Int64(Date().timeIntervalSince1970)
		let text = listenText(sid: own.channel.sid, wk: own.channel.wkB64, relayKeyId: relay.domain, timestamp: ts)
		guard let tempSig = nativeOrWebView("listen", native: { BeamioNativeEthSigner.signEip191(privateKeyHex: own.tkHex, message: text) }, webView: {
			waitResult({ BeamioOpenPgpHost.shared.signEip191(privateKeyHex: own.tkHex, message: text, completion: $0) })
		}),
		      let payData = own.payJson.data(using: .utf8),
		      let pay = try? JSONSerialization.jsonObject(with: payData) as? [String: Any]
		else { return nil }
		return [
			"command": "voice_listen",
			"v": 3,
			"sessionId": own.channel.sid,
			"wk": own.channel.wkB64,
			"timestamp": ts,
			"temp": own.tempAddress,
			"tempSig": tempSig,
			"pay": pay,
		]
	}

	// MARK: - Accept wire

	private static func channel(from obj: Any?) -> Channel? {
		guard let d = obj as? [String: Any],
		      let sid = (d["sid"] as? String)?.lowercased(), BeamioVoiceChannelV2.locator(fromSessionId: sid) != nil,
		      let key = Data(base64Encoded: d["key"] as? String ?? ""), key.count == 32,
		      let wk = Data(base64Encoded: d["wk"] as? String ?? ""), wk.count == 32
		else { return nil }
		return Channel(sid: sid, key: key, wk: wk)
	}

	private static func relay(domain: String, ip: String, keyB64: String) -> Relay? {
		let d = domain.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
		guard !d.isEmpty else { return nil }
		if let known = RelayNodes.node(domain: d) { return known }
		guard let data = Data(base64Encoded: keyB64, options: .ignoreUnknownCharacters),
		      let armor = String(data: data, encoding: .utf8), armor.contains("BEGIN PGP PUBLIC KEY")
		else { return nil }
		return Relay(domain: d, ip: BeamioSiCipherPost.normalizeIp(ip) ?? "", armor: armor)
	}

	private static func ownChannel(from obj: Any?) -> Own? {
		guard let c = channel(from: obj), let d = obj as? [String: Any],
		      let tk = d["tk"] as? String, let pay = d["pay"] as? [String: Any]
		else { return nil }
		let tkHex = BeamioChatWalletKeychain.normalizeKey(tk)
		guard !tkHex.isEmpty, let payData = try? JSONSerialization.data(withJSONObject: pay),
		      let payJson = String(data: payData, encoding: .utf8)
		else { return nil }
		guard let temp = waitResult({ BeamioOpenPgpHost.shared.walletAddress(privateKeyHex: tkHex, completion: $0) }) else { return nil }
		return Own(channel: c, tkHex: tkHex, tempAddress: temp.lowercased(), payJson: payJson, relay: nil)
	}

	private static func peerChannel(from obj: Any?) -> Peer? {
		guard let c = channel(from: obj), let d = obj as? [String: Any] else { return nil }
		let r = relay(domain: d["relay"] as? String ?? "", ip: d["relayIp"] as? String ?? "", keyB64: d["relayKey"] as? String ?? "")
		guard let r else { return nil }
		return Peer(channel: c, relay: r)
	}

	/// Caller side: `accept.ch` → our two channels (with T) and the callee's two. Blocking.
	static func callFromAccept(callId: String, ch: [String: Any]) -> Call? {
		guard let cv = ownChannel(from: ch["cv"]), let cV = ownChannel(from: ch["cV"]),
		      let ev = peerChannel(from: ch["ev"]), let eV = peerChannel(from: ch["eV"])
		else { return nil }
		return Call(callId: callId, ownVoice: cv, ownVideo: cV, peerVoice: ev, peerVideo: eV)
	}

	static func wire(_ c: Channel) -> [String: Any] {
		["sid": c.sid, "key": c.keyB64, "wk": c.wkB64]
	}

	/// Accept `ch` (callee side): the caller's two channels with T, our two with relays.
	static func acceptChannels(cv: Own, cV: Own, ev: Own, eV: Own) -> [String: Any]? {
		func ownWire(_ o: Own) -> [String: Any]? {
			guard let data = o.payJson.data(using: .utf8),
			      let pay = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
			else { return nil }
			var w = wire(o.channel)
			w["tk"] = "0x" + o.tkHex
			w["pay"] = pay
			return w
		}
		func relayWire(_ o: Own) -> [String: Any]? {
			guard let r = o.relay else { return nil }
			var w = wire(o.channel)
			w["relay"] = r.domain
			w["relayIp"] = r.ip
			w["relayKey"] = Data(r.armor.utf8).base64EncodedString()
			return w
		}
		guard let cvw = ownWire(cv), let cVw = ownWire(cV), let evw = relayWire(ev), let eVw = relayWire(eV) else { return nil }
		return ["cv": cvw, "cV": cVw, "ev": evw, "eV": eVw]
	}

	/// `voice_channel_ready_v3` body for our two relays.
	static func channelReadyBody(callId: String, voice: Relay, video: Relay) -> [String: Any] {
		[
			"type": "voice_channel_ready_v3",
			"callId": callId,
			"voice": voice.domain,
			"voiceIp": voice.ip,
			"voiceKey": Data(voice.armor.utf8).base64EncodedString(),
			"video": video.domain,
			"videoIp": video.ip,
			"videoKey": Data(video.armor.utf8).base64EncodedString(),
		]
	}

	/// The peer's relays from `voice_channel_ready_v3`.
	static func relays(fromReady json: [String: Any]) -> (voice: Relay?, video: Relay?) {
		(
			relay(domain: json["voice"] as? String ?? "", ip: json["voiceIp"] as? String ?? "", keyB64: json["voiceKey"] as? String ?? ""),
			relay(domain: json["video"] as? String ?? "", ip: json["videoIp"] as? String ?? "", keyB64: json["videoKey"] as? String ?? "")
		)
	}

	// MARK: - Relay node cache

	/// Route keys of all nodes, handed over by the page (`setNativeVoiceRelayNodes`)
	/// and cached for a cold start that answers without the page. Public data.
	enum RelayNodes {
		private static let lock = NSLock()
		private static var cache: [Relay]?

		private static var fileURL: URL? {
			FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
				.appendingPathComponent("beamio-voice-relays.json")
		}

		static func save(fromBridge nodes: [[String: Any]]) {
			var out: [Relay] = []
			for n in nodes {
				guard let ip = BeamioSiCipherPost.normalizeIp(n["ip"] as? String ?? ""),
				      let domain = (n["domain"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !domain.isEmpty,
				      let armor = n["armor"] as? String, armor.contains("BEGIN PGP PUBLIC KEY")
				else { continue }
				out.append(Relay(domain: domain, ip: ip, armor: armor))
			}
			guard !out.isEmpty else { return }
			lock.lock()
			cache = out
			lock.unlock()
			let rows = out.map { ["ip": $0.ip, "domain": $0.domain, "armor": $0.armor] }
			if let url = fileURL, let data = try? JSONSerialization.data(withJSONObject: rows) {
				try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
				try? data.write(to: url, options: .atomic)
			}
			NSLog("[BeamioVoiceV3] relay nodes cached n=%d", out.count)
		}

		static func all() -> [Relay] {
			lock.lock()
			defer { lock.unlock() }
			if let cache { return cache }
			guard let url = fileURL, let data = try? Data(contentsOf: url),
			      let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
			else { return [] }
			let loaded = rows.compactMap { r -> Relay? in
				guard let ip = r["ip"], let d = r["domain"], let a = r["armor"] else { return nil }
				return Relay(domain: d, ip: ip, armor: a)
			}
			cache = loaded
			return loaded
		}

		static func node(domain: String) -> Relay? {
			let want = domain.uppercased()
			return all().first { $0.domain == want }
		}

		/// A random relay that is none of `excludeIps` and serves none of `excludeArmors`.
		static func pick(excludeIps: Set<String>, excludeArmors: [String]) -> Relay? {
			let norm = { (s: String) in s.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
			let avoid = Set(excludeArmors.map(norm).filter { !$0.isEmpty })
			var pool = all().filter { !excludeIps.contains($0.ip) && !avoid.contains(norm($0.armor)) }
			#if DEBUG || BEAMIO_QA
			// QA builds only: pin relays to canary nodes (Documents/qa-voice-relays.txt,
			// comma-separated route key IDs). Release builds never read it.
			if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
			   let raw = try? String(contentsOf: dir.appendingPathComponent("qa-voice-relays.txt"), encoding: .utf8)
			{
				let allow = Set(raw.split(whereSeparator: { $0 == "," || $0 == "\n" })
					.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
					.filter { !$0.isEmpty })
				if !allow.isEmpty { pool = pool.filter { allow.contains($0.domain) } }
			}
			#endif
			// Prefer a relay the SDK pool saw alive lately (answers at once); still random.
			let warm = BeamioVoiceV3.warmRelayIps()
			return pool.filter { warm.contains($0.ip) }.randomElement() ?? pool.randomElement()
		}
	}

	// MARK: - Chat message to the peer's mailbox

	/// Sign (our wallet), encrypt to the peer's user PGP, wrap to the peer's
	/// mailbox route key and post through an entry that is neither mailbox.
	/// The same path as every chat message (recipient-PGP, random entry). Blocking.
	static func postChatMessage(
		text: String,
		localEoa: String,
		peerUserPgp: String,
		peerRoute: String,
		noPush: Bool
	) -> Bool {
		guard let armor = sealChatMessage(text: text, localEoa: localEoa, peerUserPgp: peerUserPgp, peerRoute: peerRoute, noPush: noPush)
		else { return false }
		return postSealedChatMessage(armor: armor, peerRoute: peerRoute)
	}

	/// The signed, encrypted and wrapped chat message, ready to post (nothing is
	/// sent). The callee seals its accept while the phone rings: after Answer, with
	/// the app still in the background, the SDK's crypto WebView did not answer
	/// until the app came to the front (3–7 s in RC3b). Blocking.
	static func sealChatMessage(
		text: String,
		localEoa: String,
		peerUserPgp: String,
		peerRoute: String,
		noPush: Bool
	) -> String? {
		guard peerUserPgp.contains("BEGIN PGP PUBLIC KEY"), peerRoute.contains("BEGIN PGP PUBLIC KEY") else { return nil }
		// Our wallet's EIP-191 signature: native when the stored key is this wallet's
		// (no WebView round trip), else the SDK's signer as before.
		let stored = BeamioChatWalletKeychain.load()
		let walletKey = stored?.eoa.lowercased() == localEoa.lowercased() ? stored?.privateKeyHex : nil
		guard let sig = nativeOrWebView(
			"chat",
			native: { walletKey.flatMap { BeamioNativeEthSigner.signEip191(privateKeyHex: $0, message: text) } },
			webView: {
				waitResult({ done in
					BeamioConetChatSignBroker.requestEip191(message: text, timeout: 10) { done($0) }
				})
			}
		) else { return nil }
		let envelope: [String: Any] = [
			"timestamp": Int(Date().timeIntervalSince1970 * 1000),
			"text": text,
			"from": localEoa,
			"signMessage": sig,
		]
		guard let envData = try? JSONSerialization.data(withJSONObject: envelope),
		      let userArmor = waitResult({
		      	BeamioOpenPgpHost.shared.encrypt(plaintext: envData.base64EncodedString(), publicKeyArmor: peerUserPgp, completion: $0)
		      }), userArmor.contains("BEGIN PGP MESSAGE"),
		      let armor = waitResult({
		      	BeamioOpenPgpHost.shared.wrapArmorToMailboxWork(innerArmor: userArmor, mailboxRoutePublicArmor: peerRoute, noPush: noPush, completion: $0)
		      }), armor.contains("BEGIN PGP MESSAGE")
		else { return nil }
		return armor
	}

	/// Post a sealed chat message through an entry that is neither mailbox. Native
	/// HTTP only. Blocking.
	static func postSealedChatMessage(armor: String, peerRoute: String) -> Bool {
		var exclude = Set<String>()
		let norm = { (s: String) in s.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
		for r in RelayNodes.all() where norm(r.armor) == norm(peerRoute) { exclude.insert(r.ip) }
		if let own = BeamioSiCipherPost.normalizeIp(BeamioChatPgpKeychain.loadMailboxIp()) { exclude.insert(own) }
		let posted = BeamioSiCipherPost.post(
			armor: armor,
			nodes: BeamioChatPgpKeychain.loadSiNodes(),
			excludeIps: exclude,
			maxAttempts: 4,
			timeout: 8
		)
		return posted.ok
	}
}

extension BeamioVoiceV3 {
	/// Push wake: load the OpenPGP host now (the accept and the listens need it),
	/// so Answer does not wait for it. Entries come from the SDK's warm pool.
	static func prepareCallSetup() {
		BeamioOpenPgpHost.shared.ensureReady { _ in }
		BeamioVoiceRoutePgp.shared.ensureAlive(reason: "push wake")
	}

	/// Relays that answered a warm-up probe lately (alive now).
	static func warmRelayIps() -> Set<String> { BeamioEntryPool.shared.warmIps() }
}

extension BeamioVoiceV3 {
	/// First `voice_listen` of a channel, signed with T and encrypted to its relay
	/// ahead of time (callee, while it rings). Nothing is sent before Answer, so the
	/// relay learns nothing and nothing is paid until the listen opens. Memory only;
	/// used once, within 5 min (the relay accepts a listen timestamp ±10 min).
	enum PreparedListens {
		private static let lock = NSLock()
		private static var bySid: [String: (relay: String, armor: String, at: Date)] = [:]

		static func prepare(_ own: Own) {
			guard let relay = own.relay, let command = listenCommand(own, relay: relay),
			      let json = try? JSONSerialization.data(withJSONObject: command, options: []),
			      let armor = waitResult({ BeamioOpenPgpHost.shared.encrypt(plaintext: json.base64EncodedString(), publicKeyArmor: relay.armor, completion: $0) }),
			      armor.contains("BEGIN PGP MESSAGE")
			else { return }
			lock.lock()
			bySid[own.channel.sid] = (relay.domain, armor, Date())
			lock.unlock()
		}

		static func take(sid: String, relayDomain: String) -> String? {
			lock.lock()
			defer { lock.unlock() }
			let now = Date()
			bySid = bySid.filter { now.timeIntervalSince($0.value.at) < 300 }
			guard let hit = bySid.removeValue(forKey: sid), hit.relay == relayDomain else { return nil }
			return hit.armor
		}

		static func drop(sids: [String]) {
			lock.lock()
			sids.forEach { bySid.removeValue(forKey: $0) }
			lock.unlock()
		}
	}
}

extension BeamioVoiceV3 {
	private static let signPathLock = NSLock()
	nonisolated(unsafe) private static var lastSignPath = ""

	/// v3 channel signing: native secp256k1 first (same bytes as ethers), the SDK's
	/// crypto WebView only if that fails. Logs the path when it changes.
	static func nativeOrWebView(_ what: String, native: () -> String?, webView: () -> String?) -> String? {
		if let n = native() {
			signPathLock.lock()
			let changed = lastSignPath != "native"
			lastSignPath = "native"
			signPathLock.unlock()
			if changed { BeamioQALog.write("v3 sign path=native (\(what))") }
			return n
		}
		signPathLock.lock()
		lastSignPath = "webview"
		signPathLock.unlock()
		BeamioQALog.write("v3 sign path=webview (\(what)): native failed")
		return webView()
	}
}
