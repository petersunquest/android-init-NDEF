import ConetChatSDK
import Foundation
import Security
import UIKit

/// Native voice signaling over entry nodes (`BeamioSiCipherPost`) — no PWA.
/// Decline / Accept: AES-GCM control body → `voice_uplink` encrypted to **caller mailbox route PGP**.
/// Dialer: native `voice_listen` on offer.sessionId to receive accept/reject + media.
enum BeamioNativeVoiceSignaling {
	enum Role: String {
		case callee
		case dialer
	}

	/// Dialer-only: VoIP wake + offerArmor for mailbox `voice_listen` (native owns push).
	struct DialerWake: Equatable {
		var callId: String
		var calleeEoa: String
		/// Ring expiry (ms).
		var expiresAt: Int64
		/// Push timestamp (unix sec).
		var pushTimestamp: Int64
		var offerArmor: String
		/// Per-call relay node (armored route key + IP); empty for the legacy own-mailbox path.
		var relayRouteArmored: String = ""
		var relayIp: String = ""
	}

	/// Active native temporary-relay call (callee after Answer, or dialer after startSystemCall).
	struct ActiveCall: Equatable {
		var role: Role
		var offer: BeamioVoiceOfferIdentity.Resolved
		/// Local `voice_listen` sessionId.
		var listenSessionId: String
		/// Peer listen session for uplink `targetSessionId` (dialer: empty until accept).
		var peerMediaSessionId: String
		/// Encrypt-to / uplink `to` (callee→caller EOA, dialer→callee EOA).
		var peerEoa: String
		var localEoa: String
		/// Dialer starts listen-only until remote accept enables PCM.
		var mediaEnabled: Bool
		/// Outgoing dialer wake fields (nil for callee).
		var dialerWake: DialerWake? = nil

		/// Callee accept listen id (compat alias).
		var acceptSessionId: String { listenSessionId }
	}

	private static let lock = NSLock()
	private static var cacheByCallId: [String: BeamioVoiceOfferIdentity.Resolved] = [:]
	private static var inFlightDecline: Set<String> = []
	private static var inFlightAccept: Set<String> = []
	private static var activeCall: ActiveCall?
	/// Busy rejects held until the sticky Incoming call ends. Sending them
	/// immediately boots `BeamioOpenPgpHost`'s WKWebView and SpringBoard
	/// drops the live banner (v68 decline stage).
	private static var deferredStickyDeclines: [(offer: BeamioVoiceOfferIdentity.Resolved, reason: String)] = []

	// MARK: - Caller cancel / hang-up seen by the shell

	/// Calls the caller has already ended, keyed by callId and by sessionId. A VoIP
	/// push makes iOS report the call at once, so the caller's cancel can arrive
	/// before the report exists (the app is still waking up). Remembering it lets
	/// the report be ended as soon as it is made.
	private static var remoteEnded: [String: Date] = [:]
	private static let remoteEndedTTL: TimeInterval = 600

	static func wasRemoteEnded(callId: String, sessionId: String) -> Bool {
		remoteEndedAgeSeconds(callId: callId, sessionId: sessionId) != nil
	}

	/// Seconds since `markRemoteEnded` for this call/session, or `nil` if not marked /
	/// expired. Soft FG uses a short window so history dumps of old ends soft-skip
	/// (no CallKit flash), while a close end-before-offer race (~seconds) can soft-allow.
	static func remoteEndedAgeSeconds(callId: String, sessionId: String) -> TimeInterval? {
		lock.lock()
		defer { lock.unlock() }
		let now = Date()
		remoteEnded = remoteEnded.filter { now.timeIntervalSince($0.value) < remoteEndedTTL }
		var stamped: Date?
		if !callId.isEmpty, let d = remoteEnded[callId] {
			stamped = d
		}
		if !sessionId.isEmpty, let d = remoteEnded[sessionId] {
			if stamped == nil || d > stamped! { stamped = d }
		}
		guard let stamped else { return nil }
		return now.timeIntervalSince(stamped)
	}

	/// Documents/voice-qa.log (pull with `devicectl device copy from`). A killed app
	/// woken by a call push has no console to read, so the cancel path leaves a
	/// short trail here too.
	static func qaTrail(_ line: String) {
		NSLog("[BeamioVoiceQA] %@", line)
		guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
		let url = dir.appendingPathComponent("voice-qa.log")
		let data = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
		if let handle = try? FileHandle(forWritingTo: url) {
			defer { try? handle.close() }
			_ = try? handle.seekToEnd()
			try? handle.write(contentsOf: data)
		} else {
			try? data.write(to: url, options: .atomic)
		}
	}

	private static func markRemoteEnded(callId: String, sessionId: String) {
		lock.lock()
		let now = Date()
		if !callId.isEmpty { remoteEnded[callId] = now }
		if !sessionId.isEmpty { remoteEnded[sessionId] = now }
		lock.unlock()
	}

	/// Incoming calls this device already declined or hung up, keyed by callId
	/// and sessionId. The PWA or a replayed chat offer can soft-report the same
	/// call again seconds later; that must not ring a call that is over.
	/// Persisted so a relaunch (or a cold start from a push) still knows.
	private static let locallyEndedKey = "beamio.voice.locallyEnded"
	private static let locallyEndedTTL: TimeInterval = 600

	/// Caller holds `lock`.
	private static func loadLocallyEnded(now: Date) -> [String: TimeInterval] {
		let raw = UserDefaults.standard.dictionary(forKey: locallyEndedKey) as? [String: TimeInterval] ?? [:]
		let cutoff = now.timeIntervalSince1970 - locallyEndedTTL
		return raw.filter { $0.value >= cutoff }
	}

	static func markLocallyEnded(callId: String, sessionId: String) {
		lock.lock()
		let now = Date()
		var map = loadLocallyEnded(now: now)
		if !callId.isEmpty { map[callId] = now.timeIntervalSince1970 }
		if !sessionId.isEmpty { map[sessionId] = now.timeIntervalSince1970 }
		UserDefaults.standard.set(map, forKey: locallyEndedKey)
		lock.unlock()
	}

	static func wasLocallyEnded(callId: String, sessionId: String) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		let map = loadLocallyEnded(now: Date())
		return (!callId.isEmpty && map[callId] != nil)
			|| (!sessionId.isEmpty && map[sessionId] != nil)
	}

	/// AES-relay `voice_end_v1` from the peer (browser Hang Up). Marks remote-ended
	/// so we do not bounce a hangup back, then tears CallKit + InCall.
	static func applyRemoteMediaEnd(callId: String, sessionId: String) {
		let cid = callId.trimmingCharacters(in: .whitespacesAndNewlines)
		let sid = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !cid.isEmpty || !sid.isEmpty else { return }
		markRemoteEnded(callId: cid, sessionId: sid)
		let callKit = BeamioVoipIncomingBootstrap.shared.callKit
		let pushAlias = callKit.lastReportedCallId
		// v83: only alias-mark/end when PushKit id is the same live call.
		let aliasLive = !pushAlias.isEmpty && pushAlias != cid
			&& callKit.cancelAliasesLastReported(callId: cid, sessionId: sid)
		if aliasLive {
			markRemoteEnded(callId: pushAlias, sessionId: sid)
		}
		qaTrail("aes remote end callId=\(cid.prefix(8)) alias=\(aliasLive ? pushAlias.prefix(8) : "-")")
		NSLog("[BeamioNativeVoice] AES peer ended callId=%@", cid)
		let end = {
			callKit.end(callId: cid, sessionId: sid)
			if aliasLive {
				callKit.end(callId: pushAlias, sessionId: sid)
			}
		}
		if Thread.isMainThread {
			end()
		} else {
			DispatchQueue.main.async(execute: end)
		}
	}

	/// Every inbound Chat message passes through the shell before it reaches the
	/// page, already decrypted and with its EIP-191 signer recovered (`from`). Act on
	/// a caller's cancel or hang-up here, natively: the page may not be running yet
	/// (killed or suspended app woken by a call push), and then nothing else would
	/// ever clear the ringing CallKit call.
	///
	/// Also paint `@BeamioTag` from a live `voice_call_offer_v1` chat line — VoIP
	/// first-report is opaque `"Beamio"`, and `voice_offer_fetch` often misses while
	/// the offer still arrives as a normal chat message.
	///
	/// `payload` is the bridge object the chat module emits (`chatModuleEvent`).
	static func observeChatEvent(_ payload: [String: Any]) {
		guard payload["action"] as? String == "chatModuleEvent",
		      let event = payload["event"] as? [String: Any]
		else { return }
		if let type = event["type"] as? String, type == "event:status" {
			qaTrail("chat status \((event["payload"] as? [String: Any])?["status"] as? String ?? "?")")
		}
		guard event["type"] as? String == "event:message",
		      let body = event["payload"] as? [String: Any],
		      let line = body["line"] as? String,
		      let from = (body["from"] as? String)?.lowercased(),
		      from.hasPrefix("0x"), from.count == 42
		else { return }
		qaTrail("chat message from=…\(from.suffix(6)) len=\(line.count)")

		if let signal = endSignal(in: line) {
			qaTrail("caller end signal type=\(signal.type) callId=\(signal.callId.prefix(8))")
			// The recovered signer must be the caller. The offer cache holds the caller
			// once the offer is known; without it the secret callId is the only check.
			if let offer = cachedOffer(callId: signal.callId, sessionId: signal.sessionId),
			   !offer.callerEoa.isEmpty,
			   offer.callerEoa.lowercased() != from
			{
				NSLog("[BeamioNativeVoice] cancel ignored — signer is not the caller callId=%@", signal.callId)
				return
			}
			let callKit = BeamioVoipIncomingBootstrap.shared.callKit
			let pushAlias = callKit.lastReportedCallId
			let aliasLive = !pushAlias.isEmpty && pushAlias != signal.callId
				&& callKit.cancelAliasesLastReported(
					callId: signal.callId,
					sessionId: signal.sessionId
				)
			// v83: historyLoad may replay an old voice_end while a newer CallKit
			// ring is live. Do not mark/end the live PushKit alias for that stale id.
			if callKit.hasLiveCallKitCall(),
			   !pushAlias.isEmpty,
			   signal.callId != pushAlias,
			   !aliasLive
			{
				qaTrail(
					"stale end ignored live=\(pushAlias.prefix(8)) end=\(signal.callId.prefix(8)) type=\(signal.type)"
				)
				NSLog(
					"[BeamioNativeVoice] stale end ignored — live=%@ end=%@ type=%@",
					pushAlias,
					signal.callId,
					signal.type
				)
				callKit.writeBusyQaBreadcrumb(
					"stale-end-ignored:live=\(pushAlias):end=\(signal.callId):type=\(signal.type)"
				)
				return
			}
			markRemoteEnded(callId: signal.callId, sessionId: signal.sessionId)
			if aliasLive {
				markRemoteEnded(callId: pushAlias, sessionId: signal.sessionId)
			}
			NSLog("[BeamioNativeVoice] caller ended callId=%@ type=%@", signal.callId, signal.type)
			DispatchQueue.main.async {
				callKit.end(
					callId: signal.callId,
					sessionId: signal.sessionId
				)
				if aliasLive {
					callKit.end(
						callId: pushAlias,
						sessionId: signal.sessionId
					)
				}
			}
			return
		}

		// Offer path: verify + BeamioTag, then replace opaque CallKit "Beamio".
		guard line.contains("voice_call_offer_v1") || line.contains("callerSignature") else {
			return
		}
		BeamioVoiceOfferIdentity.resolveFromInboundChatLine(line: line, from: from) { resolved in
			guard let resolved else { return }
			rememberOffer(resolved)
			let pushAlias = BeamioVoipIncomingBootstrap.shared.callKit.lastReportedCallId
			if !pushAlias.isEmpty, pushAlias != resolved.callId {
				aliasOffer(resolved, under: pushAlias)
			}
			let tag = resolved.beamioTag
			let short = resolved.shortAddress
			qaTrail(
				"chat offer → tag=\(tag.isEmpty ? "-" : tag) callId=\(resolved.callId.prefix(8)) push=\(pushAlias.prefix(8))"
			)
			DispatchQueue.main.async {
				let callKit = BeamioVoipIncomingBootstrap.shared.callKit
				let liveSame = callKit.hasLiveIncoming(
					forCallId: resolved.callId,
					sessionId: resolved.sessionId
				)
				// PushKit never reported (empty lastReportedCallId) — soft-report
				// CallKit while SSE/app is alive so FG/BG with mailbox open still rings.
				// Lock-screen wake still requires a working PushKit/APNs path.
				if pushAlias.isEmpty, !liveSame {
					let display: String = {
						let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
						if !t.isEmpty {
							return t.hasPrefix("@") ? t : "@\(t)"
						}
						if !short.isEmpty { return short }
						return "Beamio call"
					}()
					qaTrail(
						"chat offer empty-push → soft CallKit report callId=\(resolved.callId.prefix(8))"
					)
					NSLog(
						"[BeamioNativeVoice] empty-push chat offer → soft CallKit report callId=%@",
						resolved.callId
					)
					BeamioVoipIncomingBootstrap.shared.reportIncomingCallKit(
						callId: resolved.callId,
						sessionId: resolved.sessionId,
						peerAddress: resolved.callerEoa,
						displayName: display,
						claimedTag: tag,
						claimedAddress: short,
						mustReportForPushKit: false
					)
					return
				}
				callKit.updateVerifiedIdentity(
					callId: resolved.callId,
					sessionId: resolved.sessionId,
					tag: tag,
					shortAddress: short
				)
				if !pushAlias.isEmpty, pushAlias != resolved.callId {
					callKit.updateVerifiedIdentity(
						callId: pushAlias,
						sessionId: resolved.sessionId,
						tag: tag,
						shortAddress: short
					)
				}
			}
		}
	}

	private static func endSignal(in line: String) -> (type: String, callId: String, sessionId: String)? {
		func walk(_ value: Any, depth: Int) -> (String, String, String)? {
			guard depth < 8 else { return nil }
			if let text = value as? String {
				let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
				if let data = trimmed.data(using: .utf8),
				   let parsed = try? JSONSerialization.jsonObject(with: data)
				{
					return walk(parsed, depth: depth + 1)
				}
				// Chat envelopes are often base64(UTF-8 JSON), same as offer armor.
				if let data = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters])
					?? BeamioLenientBase64.decode(trimmed),
				   let decoded = String(data: data, encoding: .utf8),
				   let parsed = try? JSONSerialization.jsonObject(with: Data(decoded.utf8))
				{
					return walk(parsed, depth: depth + 1)
				}
				return nil
			}
			guard let obj = value as? [String: Any] else { return nil }
			if let type = obj["type"] as? String,
			   type == "voice_end_v1" || type == "voice_call_timeout_v1"
			{
				let callId = (obj["callId"] as? String) ?? ""
				let sessionId = (obj["sessionId"] as? String) ?? ""
				if callId.isEmpty && sessionId.isEmpty { return nil }
				return (type, callId, sessionId)
			}
			if let inner = obj["text"] as? String, let hit = walk(inner, depth: depth + 1) {
				return hit
			}
			for (_, v) in obj {
				if let hit = walk(v, depth: depth + 1) { return hit }
			}
			return nil
		}
		guard let hit = walk(line, depth: 0) else { return nil }
		return (type: hit.0, callId: hit.1, sessionId: hit.2)
	}

	static func rememberOffer(_ incoming: BeamioVoiceOfferIdentity.Resolved) {
		guard !incoming.callId.isEmpty else { return }
		lock.lock()
		// A later copy without relay fields (the PWA report) must not erase the
		// signed relay from the shell's own decrypt.
		var resolved = incoming
		if resolved.relayRouteArmored.isEmpty,
		   let prior = cacheByCallId[resolved.callId],
		   !prior.relayRouteArmored.isEmpty,
		   prior.sessionId == resolved.sessionId
		{
			resolved.relayRouteArmored = prior.relayRouteArmored
			resolved.relayIp = prior.relayIp
		}
		cacheByCallId[resolved.callId] = resolved
		if !resolved.sessionId.isEmpty {
			cacheByCallId[resolved.sessionId] = resolved
		}
		lock.unlock()
		// Read the caller's route key now, while the call is ringing and the
		// network is up. Answer, Decline and Hang Up all encrypt to that key.
		if !resolved.sessionKey.isEmpty {
			BeamioAddressPgp.prefetch(address: resolved.callerEoa)
		}
	}

	/// Alias PushKit / lastReported callId → same offer so cancel + tag updates
	/// still hit when chat offer `callId` differs from the VoIP registration key.
	static func aliasOffer(_ resolved: BeamioVoiceOfferIdentity.Resolved, under key: String) {
		let alias = key.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !alias.isEmpty else { return }
		lock.lock()
		cacheByCallId[alias] = resolved
		lock.unlock()
	}

	static func cachedOffer(callId: String, sessionId: String) -> BeamioVoiceOfferIdentity.Resolved? {
		lock.lock()
		defer { lock.unlock() }
		if !callId.isEmpty, let hit = cacheByCallId[callId] { return hit }
		if !sessionId.isEmpty, let hit = cacheByCallId[sessionId] { return hit }
		return nil
	}

	static func forgetOffer(callId: String, sessionId: String) {
		lock.lock()
		if !callId.isEmpty { cacheByCallId.removeValue(forKey: callId) }
		if !sessionId.isEmpty { cacheByCallId.removeValue(forKey: sessionId) }
		if activeCall?.offer.callId == callId || activeCall?.offer.sessionId == sessionId {
			activeCall = nil
		}
		lock.unlock()
	}

	static func currentActiveCall() -> ActiveCall? {
		lock.lock()
		defer { lock.unlock() }
		return activeCall
	}

	static func updateActiveCall(_ next: ActiveCall) {
		lock.lock()
		activeCall = next
		lock.unlock()
	}

	static func clearActiveCall() {
		lock.lock()
		activeCall = nil
		lock.unlock()
	}

	/// Mailbox `voice_listen` accepts `[0-9a-fA-F-]{16,64}` — 32 hex chars.
	static func randomMailboxVoiceSessionId() -> String {
		var bytes = [UInt8](repeating: 0, count: 16)
		_ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
		return bytes.map { String(format: "%02x", $0) }.joined()
	}

	// MARK: - Dialer (outgoing)

	/// Native owns dialer `voice_listen` + VoIP wake (offerArmor). PWA must not
	/// start worker listen on the same sessionId (SI session_conflict).
	static func attachOutgoingDialer(
		callId: String,
		sessionId: String,
		sessionKey: String,
		peerEoa: String,
		wake: DialerWake? = nil
	) {
		let trimmedCall = callId.trimmingCharacters(in: .whitespacesAndNewlines)
		let trimmedSession = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
		let trimmedKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
		let peer = peerEoa.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard !trimmedSession.isEmpty, !trimmedKey.isEmpty else {
			NSLog("[BeamioNativeVoice] dialer skip — missing sessionId/sessionKey")
			return
		}
		guard peer.hasPrefix("0x"), peer.count == 42 else {
			NSLog("[BeamioNativeVoice] dialer skip — bad peerEoa")
			return
		}
		guard let secrets = BeamioChatPgpKeychain.load() else {
			NSLog("[BeamioNativeVoice] dialer — missing Chat PGP secrets")
			return
		}
		let localEoa = secrets.eoa.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard localEoa.hasPrefix("0x"), localEoa.count == 42 else {
			NSLog("[BeamioNativeVoice] dialer — missing local eoa")
			return
		}
		var resolvedWake = wake
		if var w = resolvedWake {
			w.callId = w.callId.trimmingCharacters(in: .whitespacesAndNewlines)
			w.calleeEoa = w.calleeEoa.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			w.offerArmor = w.offerArmor.trimmingCharacters(in: .whitespacesAndNewlines)
			if w.callId.isEmpty { w.callId = trimmedCall.isEmpty ? trimmedSession : trimmedCall }
			if w.calleeEoa.isEmpty { w.calleeEoa = peer }
			if !w.offerArmor.contains("BEGIN PGP MESSAGE") {
				NSLog("[BeamioNativeVoice] dialer — wake offerArmor missing; listen without push")
				resolvedWake = nil
			} else {
				resolvedWake = w
			}
		}
		let offer = BeamioVoiceOfferIdentity.Resolved(
			callerEoa: localEoa,
			beamioTag: "",
			shortAddress: "",
			callId: trimmedCall.isEmpty ? trimmedSession : trimmedCall,
			sessionId: trimmedSession,
			sessionKey: trimmedKey,
			to: peer
		)
		rememberOffer(offer)
		let active = ActiveCall(
			role: .dialer,
			offer: offer,
			listenSessionId: trimmedSession,
			peerMediaSessionId: "",
			peerEoa: peer,
			localEoa: localEoa,
			mediaEnabled: false,
			dialerWake: resolvedWake
		)
		lock.lock()
		activeCall = active
		lock.unlock()
		NSLog(
			"[BeamioNativeVoice] dialer attach callId=%@ session=%@ peer=%@ wake=%@",
			offer.callId,
			trimmedSession,
			String(peer.suffix(8)),
			resolvedWake == nil ? "no" : "yes"
		)
		BeamioNativeVoiceChannel.shared.start(active: active)
	}

	/// Remote accept on dialer listen — enable media + notify CallKit / PWA UI.
	static func dialerDidReceiveAccept(peerAcceptSessionId: String) {
		let peerSession = peerAcceptSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !peerSession.isEmpty else { return }
		lock.lock()
		guard var cur = activeCall, cur.role == .dialer else {
			lock.unlock()
			return
		}
		// The accept is delivered once per fan-out entry. Act on the first copy only,
		// otherwise the audio engine is torn down and rebuilt for every duplicate.
		if cur.mediaEnabled, cur.peerMediaSessionId == peerSession {
			lock.unlock()
			return
		}
		cur.peerMediaSessionId = peerSession
		cur.mediaEnabled = true
		activeCall = cur
		let snapshot = cur
		lock.unlock()
		NSLog(
			"[BeamioNativeVoice] dialer accept peerSession=%@ callId=%@",
			peerSession,
			snapshot.offer.callId
		)
		BeamioNativeVoiceChannel.shared.enableMedia(active: snapshot)
		DispatchQueue.main.async {
			BeamioVoipIncomingBootstrap.shared.callKit.markOutgoingConnected(
				callId: snapshot.offer.callId,
				sessionId: snapshot.listenSessionId
			)
			BeamioInCallScreenModel.shared.markConnected(callId: snapshot.offer.callId)
			BeamioVoipIncomingBootstrap.shared.emitToWeb(
				"callAnswered",
				callId: snapshot.offer.callId,
				sessionId: snapshot.listenSessionId
			)
		}
	}

	/// Remote reject / timeout on dialer listen.
	static func dialerDidReceiveReject(action: String) {
		lock.lock()
		guard let cur = activeCall, cur.role == .dialer else {
			lock.unlock()
			return
		}
		let callId = cur.offer.callId
		let sessionId = cur.listenSessionId
		activeCall = nil
		lock.unlock()
		let webAction = action == "callTimedOut" ? "callTimedOut" : "callRejected"
		NSLog("[BeamioNativeVoice] dialer %@ callId=%@", webAction, callId)
		BeamioNativeVoiceChannel.shared.stop()
		DispatchQueue.main.async {
			BeamioVoipIncomingBootstrap.shared.emitToWeb(webAction, callId: callId, sessionId: sessionId)
			BeamioVoipIncomingBootstrap.shared.callKit.end(callId: callId, sessionId: sessionId)
		}
	}

	// MARK: - Callee Decline / Accept

	/// CallKit Decline / Telecom reject — fire-and-forget on a background queue.
	/// Uses a UIBackgroundTask so VoIP process suspension cannot cancel the
	/// resolve+AES+voice_uplink before the dialer receives `voice_call_reject_v1`.
	/// - Parameter reason: `"declined"` (user Decline) or `"busy"` (single-call
	///   gate while another call is ringing / connected). Dialer ends on either.
	static func sendDecline(
		callId: String,
		sessionId: String,
		reason: String = "declined",
		protectStickyChrome: Bool = false
	) {
		let rejectReason: String = {
			let t = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			if t == "busy" { return "busy" }
			return "declined"
		}()
		let key = "\(callId)|\(sessionId)|\(rejectReason)"
		lock.lock()
		if inFlightDecline.contains(key) {
			lock.unlock()
			return
		}
		inFlightDecline.insert(key)
		lock.unlock()

		// v69: protectStickyChrome used to call resolveOfferSync, which boots
		// a hidden WKWebView (OpenPGP). v68 showed that alone drops the live
		// Incoming banner while CXCall stays connected. Queue a cached offer
		// and send it only after the sticky call has ended.
		if protectStickyChrome {
			if let offer = cachedOffer(callId: callId, sessionId: sessionId),
			   !offer.sessionKey.isEmpty {
				lock.lock()
				if !deferredStickyDeclines.contains(where: { $0.offer.callId == offer.callId && $0.reason == rejectReason }) {
					deferredStickyDeclines.append((offer, rejectReason))
				}
				lock.unlock()
			}
			lock.lock()
			inFlightDecline.remove(key)
			lock.unlock()
			DispatchQueue.main.async {
				BeamioVoipIncomingBootstrap.shared.callKit.noteBusyDeclineDeferredNoWebView(callId: callId)
			}
			return
		}

		// v66: a missing offer used to begin+end `beamio.voice.decline` while
		// CallKit Incoming was up in Background (v65 self-probe). That end
		// drops the banner. Skip the task unless the app is active and the
		// caller did not ask to protect sticky chrome.
		let useBackgroundTask = !protectStickyChrome
			&& UIApplication.shared.applicationState == .active

		DispatchQueue.global(qos: .userInitiated).async {
			defer {
				lock.lock()
				inFlightDecline.remove(key)
				lock.unlock()
			}
			guard let offer = resolveOfferSync(callId: callId, sessionId: sessionId) else {
				NSLog(
					"[BeamioNativeVoice] decline skip — no offer/sessionKey callId=%@ sessionId=%@ reason=%@ (no bg task)",
					callId,
					sessionId,
					rejectReason
				)
				return
			}
			if useBackgroundTask {
				var bgTask = UIBackgroundTaskIdentifier.invalid
				bgTask = UIApplication.shared.beginBackgroundTask(withName: "beamio.voice.decline") {
					if bgTask != .invalid {
						UIApplication.shared.endBackgroundTask(bgTask)
						bgTask = .invalid
					}
				}
				defer {
					DispatchQueue.main.async {
						if bgTask != .invalid {
							UIApplication.shared.endBackgroundTask(bgTask)
							bgTask = .invalid
						}
					}
				}
				sendDeclineUplink(offer: offer, rejectReason: rejectReason)
				return
			}
			sendDeclineUplink(offer: offer, rejectReason: rejectReason)
		}
	}

	/// Send queued busy rejects. Call only after the sticky Incoming call is gone.
	static func flushDeferredStickyDeclines() {
		lock.lock()
		let pending = deferredStickyDeclines
		deferredStickyDeclines.removeAll()
		lock.unlock()
		guard !pending.isEmpty else { return }
		DispatchQueue.global(qos: .userInitiated).async {
			for item in pending {
				sendDeclineUplink(offer: item.offer, rejectReason: item.reason)
			}
		}
	}

	private static func sendDeclineUplink(
		offer: BeamioVoiceOfferIdentity.Resolved,
		rejectReason: String
	) {
		guard let secrets = BeamioChatPgpKeychain.load() else {
			NSLog("[BeamioNativeVoice] decline — missing Chat PGP secrets in Keychain")
			return
		}
		let localEoa = secrets.eoa.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard localEoa.hasPrefix("0x"), localEoa.count == 42 else {
			NSLog("[BeamioNativeVoice] decline — missing local eoa in Keychain")
			return
		}
		let nowMs = Int(Date().timeIntervalSince1970 * 1000)
		let body: [String: Any] = [
			"type": "voice_call_reject_v1",
			"callId": offer.callId,
			"sessionId": offer.sessionId,
			"from": localEoa,
			"to": offer.callerEoa.lowercased(),
			"reason": rejectReason,
			"createdAt": nowMs,
			"timestamp": nowMs,
		]
		let ok = postControlUplink(
			offer: offer,
			localEoa: localEoa,
			aesBody: body,
			frameSessionId: offer.sessionId
		)
		NSLog(
			"[BeamioNativeVoice] decline uplink callId=%@ reason=%@ ok=%@",
			offer.callId,
			rejectReason,
			ok ? "yes" : "no"
		)
		forgetOffer(callId: offer.callId, sessionId: offer.sessionId)
	}

	// MARK: - Hang Up

	/// Hang Up of a connected call (either role): tell the peer on the temporary
	/// relay so its call screen ends. Without this the shell only closed its own
	/// channel and a web peer kept showing "Voice call" for a call that was over.
	///
	/// Call before `BeamioNativeVoiceChannel.stop()` / `clearActiveCall()`: the
	/// call is read here, synchronously, and the uplink then runs from that copy.
	/// A call that was never connected (dialer still ringing, no peer session)
	/// sends nothing; Decline already covers a callee that never answered.
	static func sendHangup(callId: String) {
		lock.lock()
		let snapshot = activeCall
		lock.unlock()
		guard let call = snapshot,
		      call.offer.callId == callId,
		      call.mediaEnabled,
		      !call.peerMediaSessionId.isEmpty,
		      !call.offer.sessionKey.isEmpty
		else { return }

		// Same stream as the media frames, so it must follow the last media seq.
		let seq = BeamioNativeVoiceChannel.shared.takeUplinkSeq()

		// The app can be suspended right after CallKit ends the call.
		var bgTask = UIBackgroundTaskIdentifier.invalid
		bgTask = UIApplication.shared.beginBackgroundTask(withName: "beamio.voice.hangup") {
			if bgTask != .invalid {
				UIApplication.shared.endBackgroundTask(bgTask)
				bgTask = .invalid
			}
		}
		DispatchQueue.global(qos: .userInitiated).async {
			defer {
				DispatchQueue.main.async {
					if bgTask != .invalid {
						UIApplication.shared.endBackgroundTask(bgTask)
						bgTask = .invalid
					}
				}
			}
			let nowMs = Int(Date().timeIntervalSince1970 * 1000)
			let body: [String: Any] = [
				"type": "voice_end_v1",
				"callId": call.offer.callId,
				"sessionId": call.offer.sessionId,
				"from": call.localEoa,
				"to": call.peerEoa,
				"reason": "hangup",
				"createdAt": nowMs,
				"timestamp": nowMs,
			]
			let ok = postControlUplink(
				offer: call.offer,
				localEoa: call.localEoa,
				aesBody: body,
				frameSessionId: call.peerMediaSessionId,
				toEoa: call.peerEoa,
				ownSessionId: call.listenSessionId,
				seq: seq
			)
			NSLog(
				"[BeamioNativeVoice] hangup uplink callId=%@ role=%@ ok=%@",
				call.offer.callId,
				call.role.rawValue,
				ok ? "yes" : "no"
			)
		}
	}

	/// CallKit Answer / Telecom answer — AES accept on temporary relay; starts native channel.
	static func sendAccept(callId: String, sessionId: String, completion: ((String) -> Void)? = nil) {
		let key = "\(callId)|\(sessionId)"
		lock.lock()
		if inFlightAccept.contains(key) {
			lock.unlock()
			completion?("")
			return
		}
		inFlightAccept.insert(key)
		lock.unlock()
		BeamioQALog.write("accept start callId=\(callId.prefix(8)) session=\(sessionId.prefix(8))")

		DispatchQueue.global(qos: .userInitiated).async {
			defer {
				lock.lock()
				inFlightAccept.remove(key)
				lock.unlock()
			}
			// The offer can still be on its way: right after a push the native chat
			// listen may be reconnecting, and it delivers the offer once it is back.
			var resolvedOffer = resolveOfferSync(callId: callId, sessionId: sessionId)
			if resolvedOffer == nil {
				BeamioQALog.write("accept waiting for offer callId=\(callId.prefix(8))")
				for _ in 0..<20 {
					Thread.sleep(forTimeInterval: 0.5)
					if let hit = cachedOffer(callId: callId, sessionId: sessionId), !hit.sessionKey.isEmpty {
						resolvedOffer = hit
						break
					}
				}
			}
			guard let offer = resolvedOffer else {
				BeamioQALog.write("accept skip: no offer/sessionKey callId=\(callId.prefix(8)); ending local call")
				NSLog(
					"[BeamioNativeVoice] accept skip — no offer/sessionKey callId=%@ sessionId=%@",
					callId,
					sessionId
				)
				// Without the offer no accept can be sent, so the caller keeps
				// ringing. Do not leave a connected CallKit call and a running call
				// timer here with nothing behind them (same as a failed uplink).
				DispatchQueue.main.async {
					BeamioInCallScreenModel.shared.end(callId: callId)
					BeamioVoipIncomingBootstrap.shared.callKit.end(callId: callId, sessionId: sessionId)
					completion?("")
				}
				return
			}
			guard let secrets = BeamioChatPgpKeychain.load() else {
				NSLog("[BeamioNativeVoice] accept — missing Chat PGP secrets in Keychain")
				DispatchQueue.main.async { completion?("") }
				return
			}
			let localEoa = secrets.eoa.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			guard localEoa.hasPrefix("0x"), localEoa.count == 42 else {
				NSLog("[BeamioNativeVoice] accept — missing local eoa in Keychain")
				DispatchQueue.main.async { completion?("") }
				return
			}
			let acceptSessionId = randomMailboxVoiceSessionId()
			BeamioQALog.write(
				"accept resolved callId=\(offer.callId.prefix(8)) relay=\(offer.relayRouteArmored.isEmpty ? "no" : "yes") relayIp=\(offer.relayIp.isEmpty ? "-" : offer.relayIp)"
			)
			let nowMs = Int(Date().timeIntervalSince1970 * 1000)
			let body: [String: Any] = [
				"type": "voice_call_accept_v1",
				"callId": offer.callId,
				"sessionId": acceptSessionId,
				"peerSessionId": offer.sessionId,
				"from": localEoa,
				"to": offer.callerEoa.lowercased(),
				"createdAt": nowMs,
				"timestamp": nowMs,
				"codec": "audio/pcm;rate=16000",
			]
			// The answer can land while the app is suspended or the network is not
			// up yet, so a failed uplink is retried for a few seconds.
			var ok = false
			for attempt in 0..<4 {
				ok = postControlUplink(
					offer: offer,
					localEoa: localEoa,
					aesBody: body,
					frameSessionId: offer.sessionId
				)
				BeamioQALog.write("accept uplink attempt=\(attempt + 1) ok=\(ok ? "yes" : "no")")
				if ok { break }
				NSLog("[BeamioNativeVoice] accept uplink attempt %d failed callId=%@", attempt + 1, offer.callId)
				if attempt < 3 { Thread.sleep(forTimeInterval: 0.8 * Double(attempt + 1)) }
			}
			NSLog(
				"[BeamioNativeVoice] accept uplink callId=%@ acceptSession=%@ ok=%@",
				offer.callId,
				acceptSessionId,
				ok ? "yes" : "no"
			)
			if !ok {
				// Nothing was sent, so the caller keeps ringing and there is no audio.
				// Do not leave a connected CallKit call (the green bar) or the shell
				// in-call screen (already shown on Answer) with no call behind it.
				let failed = offer
				DispatchQueue.main.async {
					NSLog("[BeamioNativeVoice] accept failed — ending CallKit + in-call callId=%@", failed.callId)
					BeamioInCallScreenModel.shared.end(callId: failed.callId)
					BeamioVoipIncomingBootstrap.shared.callKit.end(callId: failed.callId, sessionId: failed.sessionId)
				}
			}
			if ok {
				let active = ActiveCall(
					role: .callee,
					offer: offer,
					listenSessionId: acceptSessionId,
					peerMediaSessionId: offer.sessionId,
					peerEoa: offer.callerEoa.lowercased(),
					localEoa: localEoa,
					mediaEnabled: true
				)
				lock.lock()
				activeCall = active
				lock.unlock()
				BeamioNativeVoiceChannel.shared.start(active: active)
				// In-call UI already began on CXAnswer; refresh tag/address from the
				// resolved offer (may be richer than CallKit chrome at Answer time).
				let answered = offer
				DispatchQueue.main.async {
					BeamioInCallScreenModel.shared.begin(
						callId: answered.callId,
						sessionId: answered.sessionId,
						tag: answered.beamioTag,
						address: answered.callerEoa
					)
				}
			}
			DispatchQueue.main.async { completion?(ok ? acceptSessionId : "") }
		}
	}

	// MARK: - Resolve + uplink

	private static func resolveOfferSync(
		callId: String,
		sessionId: String
	) -> BeamioVoiceOfferIdentity.Resolved? {
		if let hit = cachedOffer(callId: callId, sessionId: sessionId), !hit.sessionKey.isEmpty {
			return hit
		}
		let sem = DispatchSemaphore(value: 0)
		var fetched: BeamioVoiceOfferIdentity.Resolved?
		BeamioVoiceOfferIdentity.resolve(callId: callId, sessionId: sessionId) { resolved in
			fetched = resolved
			sem.signal()
		}
		_ = sem.wait(timeout: .now() + 20)
		guard let hit = fetched, !hit.sessionKey.isEmpty else { return nil }
		rememberOffer(hit)
		return hit
	}

	/// Shared path: AES body → voice_uplink → encrypt to caller route PGP → entry POST.
	///
	/// Decline / Accept go to the caller's ring session and name no session of
	/// their own. Hang Up goes either way, so it passes `toEoa` (the peer) and
	/// `ownSessionId` (the sender's `voice_listen` session, as media frames do).
	private static func postControlUplink(
		offer: BeamioVoiceOfferIdentity.Resolved,
		localEoa: String,
		aesBody: [String: Any],
		frameSessionId: String,
		toEoa: String? = nil,
		ownSessionId: String? = nil,
		seq: Int = 0
	) -> Bool {
		let caller = (toEoa ?? offer.callerEoa).lowercased()
		guard caller.hasPrefix("0x"), caller.count == 42 else { return false }
		guard !offer.sessionKey.isEmpty, !frameSessionId.isEmpty else {
			NSLog("[BeamioNativeVoice] uplink — missing sessionKey/sessionId")
			return false
		}

		let aesPayload: String
		do {
			aesPayload = try BeamioVoiceAesGcm.encryptUtf8Json(
				keyBase64: offer.sessionKey,
				jsonObject: aesBody
			)
		} catch {
			NSLog("[BeamioNativeVoice] AES encrypt failed %@", error.localizedDescription)
			return false
		}

		// The caller's session lives on its per-call relay node when the signed
		// offer names one (callee side); otherwise the peer's mailbox.
		let relayRoute: String? = (caller == offer.callerEoa.lowercased()
			&& offer.relayRouteArmored.contains("BEGIN PGP PUBLIC KEY")) ? offer.relayRouteArmored : nil
		var routeArmor = relayRoute ?? ""  // set below for the mailbox path
		let secrets = BeamioChatPgpKeychain.load()
		let nodes = BeamioChatPgpKeychain.loadSiNodes()
		var exclude = Set<String>()
		if relayRoute != nil {
			if let relayIp = BeamioSiCipherPost.normalizeIp(offer.relayIp) { exclude.insert(relayIp) }
		} else {
			guard let keys = BeamioAddressPgp.searchKey(address: caller),
			      keys.routePublicKeyArmored.contains("BEGIN PGP PUBLIC KEY")
			else {
				NSLog("[BeamioNativeVoice] searchKey(caller) failed")
				return false
			}
			routeArmor = keys.routePublicKeyArmored
			if let b = BeamioAddressPgp.mailboxIp(forRoutePgpKeyID: keys.routePgpKeyID, nodes: nodes) {
				exclude.insert(b)
			}
		}
		if let mailbox = BeamioSiCipherPost.normalizeIp(secrets?.mailboxIp ?? "") {
			exclude.insert(mailbox)
		}

		let nowMs = Int(Date().timeIntervalSince1970 * 1000)
		let uplink: [String: Any] = [
			// Route command read by the peer's mailbox: no wallet fields.
			"command": "voice_uplink",
			"type": "voice_frame_v1",
			"callId": offer.callId,
			"sessionId": ownSessionId ?? frameSessionId,
			"targetSessionId": frameSessionId,
			"direction": "uplink",
			"seq": seq,
			"frameTimestamp": nowMs,
			"payload": aesPayload,
			"timestamp": Int(Date().timeIntervalSince1970),
		]
		guard let jsonData = try? JSONSerialization.data(withJSONObject: uplink, options: []),
		      let jsonUtf8 = String(data: jsonData, encoding: .utf8)
		else { return false }
		let opaque = Data(jsonUtf8.utf8).base64EncodedString()

		let sem = DispatchSemaphore(value: 0)
		var armorOut: String?
		BeamioOpenPgpHost.shared.encrypt(plaintext: opaque, publicKeyArmor: routeArmor) { result in
			armorOut = try? result.get()
			sem.signal()
		}
		_ = sem.wait(timeout: .now() + 12)
		guard let armor = armorOut, armor.contains("BEGIN PGP MESSAGE") else {
			NSLog("[BeamioNativeVoice] PGP encrypt to caller route failed")
			return false
		}

		let posted = BeamioSiCipherPost.post(armor: armor, nodes: nodes, excludeIps: exclude)
		BeamioQALog.write(
			"control uplink route=\(relayRoute != nil ? "relay" : "mailbox") seq=\(seq) ok=\(posted.ok ? "yes" : "no")"
		)
		return posted.ok
	}
}
