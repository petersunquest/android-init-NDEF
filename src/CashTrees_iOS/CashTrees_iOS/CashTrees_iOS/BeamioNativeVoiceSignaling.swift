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
		/// Voice protocol v3: the call's four paid channels (nil for older calls).
		var v3: BeamioVoiceV3.Call? = nil

		/// Callee accept listen id (compat alias).
		var acceptSessionId: String { listenSessionId }
	}

	private static let lock = NSLock()
	private static var cacheByCallId: [String: BeamioVoiceOfferIdentity.Resolved] = [:]
	private static var inFlightDecline: Set<String> = []
	private static var inFlightAccept: Set<String> = []
	/// Callee calls whose accept already started (Answer, or the didActivate fallback).
	private static var acceptStarted: Set<String> = []
	/// Callee calls whose CallKit audio session is active (media may start).
	private static var calleeAudioReady: Set<String> = []
	/// Callee: the four paid channels built while the call rang (memory only, nothing sent).
	private static var preparedChannels: [String: (made: [BeamioVoiceV3.Own], at: Date)] = [:]
	/// Callee: the accept for those channels, signed, encrypted and wrapped while the
	/// call rang (memory only, nothing sent). Answer only posts it: with the app in
	/// the background the SDK's crypto WebView did not answer until the app came to
	/// the front, which held the accept back 3–7 s in RC3b.
	private static var preparedAccepts: [String: (armor: String, at: Date)] = [:]
	private static var preparing: Set<String> = []
	private static var activeCall: ActiveCall?
	/// Busy rejects: sent at once when the second call's offer is resolved (its
	/// decrypt already loaded `BeamioOpenPgpHost`, which the dialer cancel also
	/// uses during a live call). Only an unresolved offer waits, because
	/// resolving it here would boot the host's WKWebView and SpringBoard used to
	/// drop the live banner (v68 decline stage).
	private static var busyRejects = BeamioBusyRejectQueue<BeamioVoiceOfferIdentity.Resolved>()

	// MARK: - Caller cancel / hang-up seen by the shell

	/// Calls the caller has already ended, keyed by callId and by sessionId. A VoIP
	/// push makes iOS report the call at once, so the caller's cancel can arrive
	/// before the report exists (the app is still waking up). Remembering it lets
	/// the report be ended as soon as it is made.
	/// Persisted: a push can wake a new process for the next call, and the chat
	/// backlog then replays the earlier, already-cancelled offer; without the mark
	/// that offer would ring CallKit again.
	private static let remoteEndedKey = "beamio.voice.remoteEnded"
	private static let remoteEndedTTL: TimeInterval = 600

	/// Caller holds `lock`.
	private static func loadRemoteEnded(now: Date) -> [String: TimeInterval] {
		let raw = UserDefaults.standard.dictionary(forKey: remoteEndedKey) as? [String: TimeInterval] ?? [:]
		let cutoff = now.timeIntervalSince1970 - remoteEndedTTL
		return raw.filter { $0.value >= cutoff }
	}

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
		let map = loadRemoteEnded(now: now)
		var stamped: TimeInterval?
		if !callId.isEmpty, let d = map[callId] {
			stamped = d
		}
		if !sessionId.isEmpty, let d = map[sessionId] {
			if stamped == nil || d > stamped! { stamped = d }
		}
		guard let stamped else { return nil }
		return max(0, now.timeIntervalSince1970 - stamped)
	}

	/// Documents/voice-qa.log (pull with `devicectl device copy from`). A killed app
	/// woken by a call push has no console to read, so the cancel path leaves a
	/// short trail here too. QA and Debug builds only (like `BeamioQALog`):
	/// Release writes no file, just the system log line.
	static func qaTrail(_ line: String) {
		NSLog("[BeamioVoiceQA] %@", line)
		#if DEBUG || BEAMIO_QA
		writeQaTrailFile(line)
		#endif
	}

	#if DEBUG || BEAMIO_QA
	private static func writeQaTrailFile(_ line: String) {
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
	#endif

	private static func markRemoteEnded(callId: String, sessionId: String) {
		lock.lock()
		let now = Date()
		var map = loadRemoteEnded(now: now)
		if !callId.isEmpty { map[callId] = now.timeIntervalSince1970 }
		if !sessionId.isEmpty { map[sessionId] = now.timeIntervalSince1970 }
		UserDefaults.standard.set(map, forKey: remoteEndedKey)
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

	// MARK: - Incoming ring time (tells a system timeout from a Decline)

	/// iOS ends an unanswered incoming CallKit call after about 60 s; a Decline
	/// arrives as the same End. A ring at least this long counts as a timeout.
	/// (The ring window is 60 s on every platform; the caller's own timeout
	/// normally arrives first, this covers a lost one.)
	static let systemRingTimeoutSeconds: TimeInterval = 55
	private static var incomingRingStarted: [String: Date] = [:]

	/// First CallKit report of this incoming call (a re-report keeps the first time).
	static func noteIncomingRingStarted(callId: String) {
		guard !callId.isEmpty else { return }
		lock.lock()
		let now = Date()
		incomingRingStarted = incomingRingStarted.filter { now.timeIntervalSince($0.value) < 600 }
		if incomingRingStarted[callId] == nil { incomingRingStarted[callId] = now }
		lock.unlock()
	}

	/// Seconds this incoming call has rung, then forgets it; nil if unknown.
	static func takeIncomingRingSeconds(callId: String) -> TimeInterval? {
		lock.lock()
		defer { lock.unlock() }
		guard let started = incomingRingStarted.removeValue(forKey: callId) else { return nil }
		return Date().timeIntervalSince(started)
	}

	// MARK: - Busy rejects (on disk, like locallyEnded)

	private static let busyRejectedKey = "beamio.voice.busyRejected"

	/// A second incoming call rejected as busy while in a call: closed on this
	/// device (no later ring) and remembered so the page can record it as
	/// "Missed call · While on another call" when it sees the offer later.
	static func markBusyRejected(callId: String, sessionId: String) {
		markLocallyEnded(callId: callId, sessionId: sessionId)
		lock.lock()
		let now = Date()
		var map = (UserDefaults.standard.dictionary(forKey: busyRejectedKey) as? [String: TimeInterval] ?? [:])
			.filter { now.timeIntervalSince1970 - $0.value < locallyEndedTTL }
		if !callId.isEmpty { map[callId] = now.timeIntervalSince1970 }
		if !sessionId.isEmpty { map[sessionId] = now.timeIntervalSince1970 }
		UserDefaults.standard.set(map, forKey: busyRejectedKey)
		lock.unlock()
	}

	static func wasBusyRejected(callId: String, sessionId: String) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		let now = Date().timeIntervalSince1970
		let map = (UserDefaults.standard.dictionary(forKey: busyRejectedKey) as? [String: TimeInterval] ?? [:])
			.filter { now - $0.value < locallyEndedTTL }
		return (!callId.isEmpty && map[callId] != nil) || (!sessionId.isEmpty && map[sessionId] != nil)
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
	/// A verified peer `voice_end_v1` / `voice_call_timeout_v1` that arrived as a
	/// Chat message (recognised by the chat module, page or not): end the matching call.
	static func applyPeerCallControl(type: String, callId: String, sessionId: String, from rawFrom: String) {
		let from = rawFrom.lowercased()
		let signal = (type: type, callId: callId, sessionId: sessionId)

		qaTrail("caller end signal type=\(signal.type) callId=\(signal.callId.prefix(8))")
		// The recovered signer must be the other party of this call: the caller on
		// a call we got, the callee on a call we dialed (our dial's cached offer has
		// callerEoa = us). Without a cached offer the secret callId is the only check.
		if let offer = cachedOffer(callId: signal.callId, sessionId: signal.sessionId),
		   !BeamioCallControlSigner.allowed(
		   	from: from,
		   	callerEoa: offer.callerEoa,
		   	calleeEoa: offer.to,
		   	localEoa: BeamioChatPgpKeychain.load()?.eoa ?? ""
		   )
		{
			NSLog("[BeamioNativeVoice] end ignored — signer is not the peer callId=%@", signal.callId)
			qaTrail("peer end ignored: signer is not the peer callId=\(signal.callId.prefix(8))")
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
		// Our own live dial is never stale (the PushKit alias belongs to incoming calls).
		let endsOurDial: Bool = {
			lock.lock()
			defer { lock.unlock() }
			guard let cur = activeCall, cur.role == .dialer else { return false }
			return cur.offer.callId == signal.callId
				|| (!signal.sessionId.isEmpty && cur.offer.sessionId == signal.sessionId)
		}()
		if !endsOurDial,
		   callKit.hasLiveCallKitCall(),
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
			// Still remember that call as over: its offer can arrive after
			// this end (mailbox backlog on a cold listen) and must not ring.
			markRemoteEnded(callId: signal.callId, sessionId: signal.sessionId)
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

		// Call control (caller cancel / hang-up) is recognised by the chat module
		// and arrives through `applyPeerCallControl`.
		if endSignal(in: line) != nil { return }

		// v3 dialer: the callee's device is ringing (wake receipt).
		if line.contains("voice_call_ringing_v1"),
		   let signal = voiceSignal(in: line, types: ["voice_call_ringing_v1"])
		{
			dialerDidReceiveRinging(callId: (signal["callId"] as? String) ?? "", from: from)
			return
		}

		// v3 dialer: the callee answers (or declines) with a chat message.
		if line.contains("voice_call_accept_v1") || line.contains("voice_call_reject_v1") || line.contains("voice_call_timeout_v1"),
		   let signal = voiceSignal(in: line, types: ["voice_call_accept_v1", "voice_call_reject_v1", "voice_call_timeout_v1"]),
		   BeamioVoiceOfferIdentity.protoOf(signal) == 3 || (signal["type"] as? String) != "voice_call_accept_v1"
		{
			let type = (signal["type"] as? String) ?? ""
			if type == "voice_call_accept_v1" {
				dialerDidReceiveAcceptV3(accept: signal, from: from)
			} else {
				dialerDidReceiveRejectV3(
					type: type,
					callId: (signal["callId"] as? String) ?? "",
					from: from,
					reason: (signal["reason"] as? String) ?? ""
				)
			}
			return
		}

		// Offer path: verify + BeamioTag, then replace opaque CallKit "Beamio".
		guard line.contains("voice_call_offer_v1") || line.contains("callerSignature") else {
			return
		}
		let ringOver = offerRingWindowOver(line: line)
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
				// The caller already ended this call (its end can be replayed before
				// the offer from a cold listen's backlog): never ring it again.
				if wasRemoteEnded(callId: resolved.callId, sessionId: resolved.sessionId) {
					qaTrail("chat offer for an ended call; not reported callId=\(resolved.callId.prefix(8))")
					return
				}
				// A replayed offer whose ring window has passed is over even if its
				// end never reached this device (lost while a push woke the app).
				if ringOver, !liveSame {
					qaTrail("chat offer past its ring window; not reported callId=\(resolved.callId.prefix(8))")
					return
				}
				sendRingingIfNeeded(resolved)
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
		// A later copy without the caller keys must not erase them from the
		// shell's own decrypt of the same offer.
		var resolved = incoming
		if !resolved.answerable,
		   let prior = cacheByCallId[resolved.callId],
		   prior.answerable,
		   prior.sessionId == resolved.sessionId
		{
			resolved.proto = prior.proto
			resolved.callerPgpArmored = prior.callerPgpArmored
			resolved.callerRouteArmored = prior.callerRouteArmored
		}
		cacheByCallId[resolved.callId] = resolved
		if !resolved.sessionId.isEmpty {
			cacheByCallId[resolved.sessionId] = resolved
		}
		// A busy reject that waited for this offer goes out now, during our call.
		let waitingBusy = resolved.answerable
			? busyRejects.offerResolved(callId: resolved.callId, sessionId: resolved.sessionId)
			: nil
		lock.unlock()
		if let waitingBusy {
			BeamioQALog.write("busy reject offer resolved; sending callId=\(resolved.callId.prefix(8))")
			DispatchQueue.global(qos: .userInitiated).async {
				sendDeclineUplink(offer: resolved, rejectReason: waitingBusy.reason)
			}
			return
		}
		if resolved.answerable { prepareAcceptChannels(resolved) }
	}

	/// Callee, while it rings: create the four paid channels, pick our relays and
	/// sign + encrypt our first listens, all on this device. Nothing is sent before
	/// Answer (the relays learn nothing, nothing is paid); declined or timed-out
	/// calls just drop it from memory. Saves the crypto WebView work on Answer.
	static func prepareAcceptChannels(_ offer: BeamioVoiceOfferIdentity.Resolved) {
		let callId = offer.callId
		// Frames and Hang Up go through this host: rebuild it now if iOS ended it.
		BeamioVoiceRoutePgp.shared.ensureAlive(reason: "incoming ring")
		lock.lock()
		let now = Date()
		for (id, entry) in preparedChannels where now.timeIntervalSince(entry.at) > 300 {
			preparedChannels.removeValue(forKey: id)
			BeamioVoiceV3.PreparedListens.drop(sids: entry.made.map(\.channel.sid))
		}
		for (id, entry) in preparedAccepts where now.timeIntervalSince(entry.at) > PreparedAcceptRule.maxAgeSeconds {
			preparedAccepts.removeValue(forKey: id)
		}
		let skip = preparing.contains(callId) || preparedChannels[callId] != nil || acceptStarted.contains(callId)
		if !skip { preparing.insert(callId) }
		lock.unlock()
		if skip { return }
		DispatchQueue.global(qos: .userInitiated).async {
			defer { lock.lock(); preparing.remove(callId); lock.unlock() }
			guard let secrets = BeamioChatPgpKeychain.load() else { return }
			let localEoa = secrets.eoa.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			guard let wallet = BeamioChatWalletKeychain.load(), wallet.eoa.lowercased() == localEoa else { return }
			let started = Date()
			var made: [BeamioVoiceV3.Own] = []
			for _ in 0 ..< 4 {
				guard let own = BeamioVoiceV3.newPaidChannel(payerKeyHex: wallet.privateKeyHex, payerEoa: localEoa) else { return }
				made.append(own)
			}
			var exclude: Set<String> = []
			if let mailbox = BeamioSiCipherPost.normalizeIp(BeamioChatPgpKeychain.loadMailboxIp()) { exclude.insert(mailbox) }
			let avoid = [BeamioChatPgpKeychain.loadRoutePublicArmor(), offer.callerRouteArmored]
			guard let voiceRelay = BeamioVoiceV3.RelayNodes.pick(excludeIps: exclude, excludeArmors: avoid),
			      let videoRelay = BeamioVoiceV3.RelayNodes.pick(excludeIps: exclude, excludeArmors: avoid)
			else { return }
			made[2].relay = voiceRelay
			made[3].relay = videoRelay
			lock.lock()
			let answered = acceptStarted.contains(callId)
			lock.unlock()
			if answered { return }  // Answer came first: sendAcceptV3 builds its own.
			BeamioVoiceV3.PreparedListens.prepare(made[2])
			BeamioVoiceV3.PreparedListens.prepare(made[3])
			lock.lock()
			preparedChannels[callId] = (made, Date())
			lock.unlock()
			qaTrail("v3 accept channels prepared while ringing callId=\(callId.prefix(8)) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
			// The accept itself, sealed now while the crypto WebView still answers.
			let sealStarted = Date()
			guard let text = acceptText(offer: offer, localEoa: localEoa, made: made),
			      let armor = BeamioVoiceV3.sealChatMessage(
			      	text: text, localEoa: localEoa,
			      	peerUserPgp: offer.callerPgpArmored, peerRoute: offer.callerRouteArmored, noPush: true
			      )
			else {
				qaTrail("v3 accept seal while ringing failed callId=\(callId.prefix(8))")
				return
			}
			lock.lock()
			// Answer came first and took the channels: it sealed its own accept.
			let stillPrepared = preparedChannels[callId] != nil && !acceptStarted.contains(callId)
			if stillPrepared { preparedAccepts[callId] = (armor, Date()) }
			lock.unlock()
			if stillPrepared {
				qaTrail("v3 accept sealed while ringing callId=\(callId.prefix(8)) ms=\(Int(Date().timeIntervalSince(sealStarted) * 1000))")
			}
		}
	}

	/// The channels prepared for `callId` while it rang (once), with the accept
	/// sealed for them if it is still fresh, or nil.
	private static func takePreparedChannels(_ callId: String) -> (made: [BeamioVoiceV3.Own], acceptArmor: String?)? {
		lock.lock()
		defer { lock.unlock() }
		let accept = preparedAccepts.removeValue(forKey: callId)
		guard let entry = preparedChannels.removeValue(forKey: callId), Date().timeIntervalSince(entry.at) < 300 else { return nil }
		let fresh = accept.flatMap { PreparedAcceptRule.usable(sealedAt: $0.at, now: Date()) ? $0.armor : nil }
		return (entry.made, fresh)
	}

	/// The v3 accept for the callee's four channels (cv, cV, ev, eV), as JSON text.
	private static func acceptText(
		offer: BeamioVoiceOfferIdentity.Resolved,
		localEoa: String,
		made: [BeamioVoiceV3.Own]
	) -> String? {
		guard made.count == 4,
		      let ch = BeamioVoiceV3.acceptChannels(cv: made[0], cV: made[1], ev: made[2], eV: made[3])
		else { return nil }
		let nowMs = Int(Date().timeIntervalSince1970 * 1000)
		let accept: [String: Any] = [
			"type": "voice_call_accept_v1",
			"proto": 3,
			"callId": offer.callId,
			"sessionId": offer.sessionId,
			"from": localEoa,
			"to": offer.callerEoa.lowercased(),
			"createdAt": nowMs,
			"timestamp": nowMs,
			"codec": "audio/pcm;rate=16000",
			"ch": ch,
		]
		return (try? JSONSerialization.data(withJSONObject: accept)).flatMap { String(data: $0, encoding: .utf8) }
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
			dialerCancel = nil
			dialerTimeout = nil
		}
		lock.unlock()
		if !callId.isEmpty { clearPendingDial(callId: callId) }
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
		dialerCancel = nil
		dialerTimeout = nil
		preparedHangup = nil
		lock.unlock()
		clearPendingDial()
		flushBusyRejectsWhenIdle()
	}

	// MARK: - Dialer cancel (built natively while the call rings)

	/// The caller-cancel Chat message for our ringing outgoing call: `voice_end_v1`,
	/// signed with the wallet key the chat SDK keeps and encrypted to the callee's
	/// user PGP key, the same envelope the page's Chat send produces. Built when the
	/// dial starts, rebuilt every couple of seconds while it rings (so its signed
	/// time stays close to the hang-up) and held in memory only; dropped when the call connects, is
	/// rejected, times out or ends. A hang-up before the callee answers posts it
	/// from the CallKit End, so the cancel never waits for the page.
	private struct DialerCancel {
		var callId: String
		var sessionId: String
		var armor: String
		/// Callee mailbox (entry A must not be mailbox B) and our own mailbox.
		var excludeIps: Set<String>
		/// `timestamp` inside the signed signal (ms): the end time the callee records.
		var signedAtMs: Int
		/// How many copies have been built for this call (1 = the dial-time copy).
		var copies: Int
	}

	/// What every copy of one call's cancel needs; looked up once at dial.
	private struct DialerCancelTarget {
		var callId: String
		var sessionId: String
		var localEoa: String
		var peerEoa: String
		var userKeyArmor: String
		var routeKeyArmor: String
		var excludeIps: Set<String>
		/// End of the ring window (offer `createdAt` + 60 s), ms.
		var timeoutAtMs: Int
	}

	private static var dialerCancel: DialerCancel?
	/// Our `voice_call_timeout_v1`, signed once at dial with the end of the ring
	/// window as its time (known in advance). Posted when the window ends unanswered.
	private static var dialerTimeout: DialerCancel?
	/// The call whose cancel was posted; a copy finishing later is not stored.
	private static var dialerCancelSpentCallId = ""

	/// Same lifetime the page puts on a voice signal (`VOICE_CALL_MAX_DURATION_MS`).
	private static let voiceSignalLifetimeMs = 15 * 60 * 1000

	/// The signed `timestamp` is the callee's record end time, and signing plus
	/// encrypting at End takes 0.1–2 s. So the held copy is rebuilt while the call
	/// rings and End posts the newest one at once: its time is at most about this
	/// interval (plus one build) before the hang-up.
	private static let dialerCancelRefreshSeconds: TimeInterval = 2

	private static func dialerCancelStillRinging(_ callId: String) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard let cur = activeCall, dialerCancelSpentCallId != callId else { return false }
		return cur.role == .dialer && cur.offer.callId == callId && !cur.mediaEnabled
	}

	private static func prepareDialerCancel(callId: String, sessionId: String, localEoa: String, peerEoa: String, timeoutAtMs: Int) {
		DispatchQueue.global(qos: .userInitiated).async {
			let started = Date()
			guard let target = makeDialerCancelTarget(
				callId: callId, sessionId: sessionId, localEoa: localEoa, peerEoa: peerEoa, timeoutAtMs: timeoutAtMs
			) else { return }
			BeamioQALog.write("dialer cancel sealing callId=\(callId.prefix(8)) appState=\(appStateLabel())")
			buildDialerCancel(target, copy: 1, started: started)
		}
	}

	/// Callee keys and send exclusions for a dialer signal. Blocking (key lookup); off the main queue.
	private static func makeDialerCancelTarget(
		callId: String, sessionId: String, localEoa: String, peerEoa: String, timeoutAtMs: Int
	) -> DialerCancelTarget? {
		// The cancel is wrapped to the callee's mailbox route key (entry sees
		// only that mailbox's key ID), so both keys are needed.
		guard let keys = BeamioAddressPgp.searchKey(address: peerEoa),
		      keys.userPublicKeyArmored.contains("BEGIN PGP PUBLIC KEY"),
		      keys.routePublicKeyArmored.contains("BEGIN PGP PUBLIC KEY")
		else {
			BeamioQALog.write("dialer cancel not prepared: callee key")
			return nil
		}
		guard let mailbox = BeamioAddressPgp.mailboxIp(
			forRoutePgpKeyID: keys.routePgpKeyID,
			nodes: BeamioChatPgpKeychain.loadSiNodes()
		), let mailboxIp = BeamioSiCipherPost.normalizeIp(mailbox) else {
			// Without the callee mailbox an entry could be mailbox B: the page sends instead.
			BeamioQALog.write("dialer cancel not prepared: callee mailbox")
			return nil
		}
		// Same exclusions as the page send: callee mailbox and our own mailbox.
		var exclude: Set<String> = [mailboxIp]
		if let own = BeamioSiCipherPost.normalizeIp(BeamioChatPgpKeychain.loadMailboxIp()) {
			exclude.insert(own)
		}
		return DialerCancelTarget(
			callId: callId,
			sessionId: sessionId,
			localEoa: localEoa,
			peerEoa: peerEoa,
			userKeyArmor: keys.userPublicKeyArmored,
			routeKeyArmor: keys.routePublicKeyArmored,
			excludeIps: exclude,
			timeoutAtMs: timeoutAtMs
		)
	}

	/// One Chat message to the callee: the signal signed with the SDK wallet key,
	/// encrypted to the callee's user key and wrapped to its mailbox. `nil` on any
	/// failure or once the call stopped ringing.
	private static func sealDialerSignal(
		_ target: DialerCancelTarget,
		type: String,
		stampMs: Int,
		/// False only for the cancel after a relaunch (no live call in memory).
		requireRinging: Bool = true,
		completion: @escaping (String?) -> Void
	) {
		let signal: [String: Any] = [
			"type": type,
			"callId": target.callId,
			"sessionId": target.sessionId,
			"from": target.localEoa,
			"to": target.peerEoa,
			"createdAt": stampMs,
			"expiresAt": stampMs + voiceSignalLifetimeMs,
			"timestamp": stampMs,
		]
		guard let signalData = try? JSONSerialization.data(withJSONObject: signal),
		      let text = String(data: signalData, encoding: .utf8)
		else { return completion(nil) }
		BeamioConetChatSignBroker.requestEip191(message: text, timeout: 10) { signed in
			guard !requireRinging || dialerCancelStillRinging(target.callId), case .success(let signature) = signed else {
				return completion(nil)
			}
			let envelope: [String: Any] = [
				"timestamp": stampMs,
				"text": text,
				"from": target.localEoa,
				"signMessage": signature,
			]
			guard let envData = try? JSONSerialization.data(withJSONObject: envelope) else { return completion(nil) }
			BeamioOpenPgpHost.shared.encrypt(
				plaintext: envData.base64EncodedString(),
				publicKeyArmor: target.userKeyArmor
			) { encrypted in
				guard case .success(let userArmor) = encrypted, userArmor.contains("BEGIN PGP MESSAGE") else {
					return completion(nil)
				}
				BeamioOpenPgpHost.shared.wrapArmorToMailboxWork(
					innerArmor: userArmor,
					mailboxRoutePublicArmor: target.routeKeyArmor,
					noPush: false
				) { wrapped in
					guard case .success(let armor) = wrapped, armor.contains("BEGIN PGP MESSAGE") else {
						return completion(nil)
					}
					completion(armor)
				}
			}
		}
	}

	/// Build one copy of the cancel, hold it if the call still rings, then schedule
	/// the next copy. Stops once the call connects, ends or the cancel is posted.
	/// A failed rebuild keeps the older copy. After the first copy, the timeout
	/// message is built once.
	private static func buildDialerCancel(_ target: DialerCancelTarget, copy: Int, started: Date) {
		guard dialerCancelStillRinging(target.callId) else { return }
		let callId = target.callId
		func next() {
			DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + dialerCancelRefreshSeconds) {
				buildDialerCancel(target, copy: copy + 1, started: started)
			}
		}
		let now = Int(Date().timeIntervalSince1970 * 1000)
		sealDialerSignal(target, type: "voice_end_v1", stampMs: now) { armor in
			guard let armor else {
				if copy == 1 {
					BeamioQALog.write("dialer cancel not prepared callId=\(callId.prefix(8))")
				} else if dialerCancelStillRinging(callId) {
					next()
				}
				return
			}
			lock.lock()
			var stored = false
			if let cur = activeCall, cur.role == .dialer, cur.offer.callId == callId, !cur.mediaEnabled,
			   dialerCancelSpentCallId != callId
			{
				dialerCancel = DialerCancel(
					callId: callId,
					sessionId: target.sessionId,
					armor: armor,
					excludeIps: target.excludeIps,
					signedAtMs: now,
					copies: copy
				)
				stored = true
			}
			lock.unlock()
			if copy == 1 {
				BeamioQALog.write(
					"dialer cancel prepared=\(stored ? "yes" : "no") callId=\(callId.prefix(8)) ms=\(Int(Date().timeIntervalSince(started) * 1000))"
				)
				if stored { prepareDialerTimeout(target) }
			}
			if stored { next() }
		}
	}

	private static func prepareDialerTimeout(_ target: DialerCancelTarget) {
		sealDialerSignal(target, type: "voice_call_timeout_v1", stampMs: target.timeoutAtMs) { armor in
			lock.lock()
			var stored = false
			if let armor, let cur = activeCall, cur.role == .dialer, cur.offer.callId == target.callId,
			   !cur.mediaEnabled, dialerCancelSpentCallId != target.callId
			{
				dialerTimeout = DialerCancel(
					callId: target.callId,
					sessionId: target.sessionId,
					armor: armor,
					excludeIps: target.excludeIps,
					signedAtMs: target.timeoutAtMs,
					copies: 1
				)
				stored = true
			}
			lock.unlock()
			BeamioQALog.write("dialer timeout prepared=\(stored ? "yes" : "no") callId=\(target.callId.prefix(8))")
		}
	}

	/// The ring window of our outgoing call ended unanswered: tell the callee
	/// (`voice_call_timeout_v1`, signed at dial), then close the call as timed out
	/// (`dialerDidReceiveReject` tells the page `callTimedOut`, which records
	/// `timed_out` without sending its own). Answer, reject or hang-up already
	/// changed the call, so a late timer does nothing.
	private static func dialerRingWindowEnded(callId: String) {
		guard dialerCancelStillRinging(callId) else { return }
		lock.lock()
		let timeout = dialerTimeout?.callId == callId ? dialerTimeout : nil
		dialerTimeout = nil
		dialerCancel = nil
		dialerCancelSpentCallId = callId
		lock.unlock()
		clearPendingDial(callId: callId)
		BeamioQALog.write("dialer ring window ended callId=\(callId.prefix(8)) prepared=\(timeout != nil ? "yes" : "no")")
		if let timeout {
			var bgTask = UIBackgroundTaskIdentifier.invalid
			bgTask = UIApplication.shared.beginBackgroundTask(withName: "beamio.voice.dialer-timeout") {
				if bgTask != .invalid {
					UIApplication.shared.endBackgroundTask(bgTask)
					bgTask = .invalid
				}
			}
			DispatchQueue.global(qos: .userInitiated).async {
				let started = Date()
				var result = BeamioSiCipherPost.post(
					armor: timeout.armor,
					nodes: BeamioChatPgpKeychain.loadSiNodes(),
					excludeIps: timeout.excludeIps,
					maxAttempts: 4,
					timeout: 6,
					hedgeAfter: 0.6
				)
				if !result.ok {
					result = BeamioSiCipherPost.post(
						armor: timeout.armor,
						nodes: BeamioChatPgpKeychain.loadSiNodes(),
						excludeIps: timeout.excludeIps
					)
				}
				BeamioQALog.write(
					"dialer timeout posted callId=\(callId.prefix(8)) ok=\(result.ok ? "yes" : "no") ms=\(Int(Date().timeIntervalSince(started) * 1000))"
				)
				DispatchQueue.main.async {
					if bgTask != .invalid {
						UIApplication.shared.endBackgroundTask(bgTask)
						bgTask = .invalid
					}
				}
			}
		}
		dialerDidReceiveReject(action: "callTimedOut")
	}

	/// CallKit End of our outgoing call. When the callee has not answered and the
	/// cancel is ready, post it now and return true. The page is told
	/// (`dialerCancelPosting`, then `dialerCancelSent` / `dialerCancelFailed`) and
	/// does not send its own. Call before `clearActiveCall()`.
	@discardableResult
	static func postDialerCancelIfRinging(callId: String) -> Bool {
		lock.lock()
		guard let cancel = dialerCancel,
		      cancel.callId == callId,
		      let cur = activeCall,
		      cur.role == .dialer,
		      cur.offer.callId == cancel.callId,
		      !cur.mediaEnabled
		else {
			lock.unlock()
			return false
		}
		dialerCancel = nil
		dialerTimeout = nil
		dialerCancelSpentCallId = cancel.callId
		lock.unlock()
		clearPendingDial(callId: cancel.callId)
		let ageMs = Int(Date().timeIntervalSince1970 * 1000) - cancel.signedAtMs

		let bridge = BeamioVoipIncomingBootstrap.shared
		bridge.emitToWeb("dialerCancelPosting", callId: cancel.callId, sessionId: cancel.sessionId)
		var bgTask = UIBackgroundTaskIdentifier.invalid
		bgTask = UIApplication.shared.beginBackgroundTask(withName: "beamio.voice.dialer-cancel") {
			if bgTask != .invalid {
				UIApplication.shared.endBackgroundTask(bgTask)
				bgTask = .invalid
			}
		}
		DispatchQueue.global(qos: .userInitiated).async {
			let started = Date()
			// Warm entry, straight POST; a second entry joins if the first is slow.
			var result = BeamioSiCipherPost.post(
				armor: cancel.armor,
				nodes: BeamioChatPgpKeychain.loadSiNodes(),
				excludeIps: cancel.excludeIps,
				maxAttempts: 4,
				timeout: 6,
				hedgeAfter: 0.6
			)
			if !result.ok {
				result = BeamioSiCipherPost.post(
					armor: cancel.armor,
					nodes: BeamioChatPgpKeychain.loadSiNodes(),
					excludeIps: cancel.excludeIps
				)
			}
			let ms = Int(Date().timeIntervalSince(started) * 1000)
			BeamioQALog.write(
				"dialer cancel posted callId=\(cancel.callId.prefix(8)) ok=\(result.ok ? "yes" : "no") ms=\(ms) signedAgoMs=\(ageMs) copies=\(cancel.copies)"
			)
			NSLog("[BeamioNativeVoice] dialer cancel posted ok=%@ ms=%d", result.ok ? "yes" : "no", ms)
			DispatchQueue.main.async {
				bridge.emitToWeb(
					result.ok ? "dialerCancelSent" : "dialerCancelFailed",
					callId: cancel.callId,
					sessionId: cancel.sessionId
				)
				if bgTask != .invalid {
					UIApplication.shared.endBackgroundTask(bgTask)
					bgTask = .invalid
				}
			}
		}
		return true
	}

	/// Mailbox `voice_listen` accepts `[0-9a-fA-F-]{16,64}` — 32 hex chars.
	static func randomMailboxVoiceSessionId() -> String {
		var bytes = [UInt8](repeating: 0, count: 16)
		_ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
		return bytes.map { String(format: "%02x", $0) }.joined()
	}

	// MARK: - Dialer (outgoing)

	/// Our outgoing call (voice v3): the page already sent the offer to the
	/// callee's mailbox. Nothing opens while ringing; the callee's accept (a
	/// chat message to our mailbox) brings our channels (`dialerDidReceiveAcceptV3`).
	/// Returns false when the dialer could not attach (the page must cancel the offer).
	@discardableResult
	static func attachOutgoingDialer(
		callId: String,
		sessionId: String,
		peerEoa: String,
		/// The offer's `createdAt` (ms) from the page; 0 = now. The ring window starts there.
		offerCreatedAtMs: Int = 0
	) -> Bool {
		let trimmedCall = callId.trimmingCharacters(in: .whitespacesAndNewlines)
		let trimmedSession = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
		let peer = peerEoa.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		// While it rings: keep the SDK's warm entries fresh for the listens after the accept,
		// and make sure the frame-encryption host is alive.
		BeamioEntryPool.shared.warmNow()
		BeamioVoiceRoutePgp.shared.ensureAlive(reason: "dial start")
		func failed(_ reason: String) -> Bool {
			BeamioQALog.write("dialer attach failed callId=\(trimmedCall.prefix(8)) reason=\(reason) appState=\(appStateLabel())")
			return false
		}
		guard !trimmedSession.isEmpty else { return failed("no-session") }
		guard peer.hasPrefix("0x"), peer.count == 42 else { return failed("bad-peer") }
		guard let secrets = BeamioChatPgpKeychain.load() else { return failed("no-chat-keys") }
		let localEoa = secrets.eoa.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard localEoa.hasPrefix("0x"), localEoa.count == 42 else { return failed("no-local-eoa") }
		let offer = BeamioVoiceOfferIdentity.Resolved(
			callerEoa: localEoa,
			beamioTag: "",
			shortAddress: "",
			callId: trimmedCall.isEmpty ? trimmedSession : trimmedCall,
			sessionId: trimmedSession,
			to: peer,
			proto: 3
		)
		rememberOffer(offer)
		let active = ActiveCall(
			role: .dialer,
			offer: offer,
			listenSessionId: trimmedSession,
			peerMediaSessionId: "",
			peerEoa: peer,
			localEoa: localEoa,
			mediaEnabled: false
		)
		lock.lock()
		activeCall = active
		lock.unlock()
		NSLog(
			"[BeamioNativeVoice] dialer attach callId=%@ session=%@ peer=%@",
			offer.callId,
			trimmedSession,
			String(peer.suffix(8))
		)
		// A receipt can beat this attach (the page posts the offer first): keep it.
		lock.lock()
		peerRinging.remove(offer.callId)
		let early = earlyRinging.removeValue(forKey: offer.callId)
		earlyRinging = earlyRinging.filter { Date().timeIntervalSince1970 - $0.value.at < 600 }
		let rangEarly = early.map { $0.from == peer } ?? false
		if rangEarly { peerRinging.insert(offer.callId) }
		lock.unlock()
		if rangEarly {
			qaTrail("ringing receipt received (before attach) callId=\(offer.callId.prefix(8))")
			// After this main-queue block, which also runs beginOutgoing (it resets the screen).
			DispatchQueue.main.async {
				BeamioInCallScreenModel.shared.notePeerWake(callId: offer.callId, .ringing)
			}
		}
		schedulePeerWakeCheck(callId: offer.callId)
		let attachedAt = Int(Date().timeIntervalSince1970 * 1000)
		let createdAt = (1 ... attachedAt).contains(offerCreatedAtMs) ? offerCreatedAtMs : attachedAt
		let timeoutAtMs = createdAt + Int(ringWindowMs)
		prepareDialerCancel(
			callId: offer.callId, sessionId: trimmedSession, localEoa: localEoa, peerEoa: peer, timeoutAtMs: timeoutAtMs
		)
		let dialCallId = offer.callId
		// Off the main queue: a busy main thread (UI work) must not push the
		// timeout past the callee's own 60 s backup. The UI part hops to main itself.
		// A strict timer: `asyncAfter` let GCD coalesce this ~60 s wait by about 1 s
		// (RC3: +0.94 / +1.1 s), which ate the margin before the callee's backup.
		let ringTimer = DispatchSource.makeTimerSource(flags: .strict, queue: .global(qos: .userInitiated))
		ringTimer.schedule(deadline: .now() + Double(max(0, timeoutAtMs - attachedAt)) / 1000, leeway: .milliseconds(20))
		ringTimer.setEventHandler {
			ringTimer.cancel()  // One shot; cancelling also releases this handler and the timer.
			dialerRingWindowEnded(callId: dialCallId)
		}
		ringTimer.resume()
		// Five rings without a receipt: Unreachable (main queue: it talks to the page and the screen).
		let unreachableDelay = BeamioDialerReceiptRule.delay(createdAtMs: createdAt, nowMs: attachedAt, afterMs: peerUnreachableMs)
		DispatchQueue.main.asyncAfter(deadline: .now() + unreachableDelay) {
			dialerPeerUnreachable(callId: dialCallId)
		}
		savePendingDial(callId: dialCallId, sessionId: trimmedSession, peerEoa: peer, timeoutAtMs: timeoutAtMs)
		observeAppStateForDialsOnce()
		BeamioQALog.write(
			"dialer attach ok callId=\(dialCallId.prefix(8)) ringLeftMs=\(max(0, timeoutAtMs - attachedAt)) appState=\(appStateLabel())"
		)
		return true
	}

	// MARK: - Dial start failure, lifecycle trail, recovery after a kill

	/// Last app state seen on the main thread (read off-main without blocking).
	private static var cachedAppState = "unknown"

	/// active / inactive / background, for QA lines. Off the main thread it
	/// returns the last state seen there (never waits on a busy main thread).
	static func appStateLabel() -> String {
		guard Thread.isMainThread else {
			lock.lock(); defer { lock.unlock() }
			return cachedAppState
		}
		let label: String
		switch UIApplication.shared.applicationState {
		case .active: label = "active"
		case .inactive: label = "inactive"
		case .background: label = "background"
		@unknown default: label = "unknown"
		}
		lock.lock()
		cachedAppState = label
		lock.unlock()
		return label
	}

	/// CallKit refused our outgoing call (`CXStartCallAction` failed). The offer is
	/// already out, so the callee must hear the cancel now: post the ready native
	/// cancel when there is one, then tell the page (`callDialerFailed`), which
	/// sends its own cancel unless the shell took it, records the call and closes
	/// the screen. Main queue.
	static func dialerStartFailed(callId: String, reason: String) {
		lock.lock()
		let ringing = activeCall.map { $0.role == .dialer && $0.offer.callId == callId && !$0.mediaEnabled } ?? false
		let sessionId = activeCall?.listenSessionId ?? ""
		lock.unlock()
		guard ringing else {
			BeamioQALog.write("dialer start failed callId=\(callId.prefix(8)) reason=\(reason) (no ringing dial)")
			return
		}
		let posted = postDialerCancelIfRinging(callId: callId)
		lock.lock()
		if activeCall?.offer.callId == callId {
			activeCall = nil
			dialerCancel = nil
			dialerTimeout = nil
		}
		dialerCancelSpentCallId = callId
		lock.unlock()
		clearPendingDial(callId: callId)
		BeamioQALog.write(
			"dialer start failed callId=\(callId.prefix(8)) reason=\(reason) cancel=\(posted ? "native" : "page") appState=\(appStateLabel())"
		)
		BeamioNativeVoiceChannel.shared.stop()
		BeamioCallTonePlayer.shared.stopRingback(reason: "dial-failed")
		BeamioVoipIncomingBootstrap.shared.emitToWeb("callDialerFailed", callId: callId, sessionId: sessionId)
		BeamioInCallScreenModel.shared.end(callId: callId)
	}

	private static var appStateObserversInstalled = false

	/// QA trail: app state changes while our dial rings (a lock or a kill in the
	/// middle of a dial shows up as the last line before silence).
	private static func observeAppStateForDialsOnce() {
		DispatchQueue.main.async {
			guard !appStateObserversInstalled else { return }
			appStateObserversInstalled = true
			let events: [(Notification.Name, String)] = [
				(UIApplication.willResignActiveNotification, "will-resign-active"),
				(UIApplication.didEnterBackgroundNotification, "did-enter-background"),
				(UIApplication.willEnterForegroundNotification, "will-enter-foreground"),
				(UIApplication.didBecomeActiveNotification, "did-become-active"),
				(UIApplication.protectedDataWillBecomeUnavailableNotification, "device-locking"),
				(UIApplication.protectedDataDidBecomeAvailableNotification, "device-unlocked"),
			]
			for (name, label) in events {
				NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
					_ = appStateLabel()
					lock.lock()
					let ringing = activeCall.flatMap { $0.role == .dialer && !$0.mediaEnabled ? $0.offer.callId : nil }
					let cancelReady = dialerCancel != nil
					let timeoutReady = dialerTimeout != nil
					lock.unlock()
					guard let ringing else { return }
					BeamioQALog.write(
						"dialer app \(label) callId=\(ringing.prefix(8)) cancelReady=\(cancelReady ? "yes" : "no") timeoutReady=\(timeoutReady ? "yes" : "no")"
					)
				}
			}
		}
	}

	/// Our dial while it rings, kept on disk: if the app is killed mid-ring
	/// (watchdog, memory), the next launch still tells the callee. Ids and the
	/// ring-window end only (no keys).
	private static let pendingDialKey = "beamio.voice.pendingDial"

	private static func savePendingDial(callId: String, sessionId: String, peerEoa: String, timeoutAtMs: Int) {
		UserDefaults.standard.set([
			"callId": callId,
			"sessionId": sessionId,
			"peer": peerEoa,
			"timeoutAtMs": timeoutAtMs,
		], forKey: pendingDialKey)
	}

	/// The dial stopped ringing (answered, cancelled, rejected, timed out).
	static func clearPendingDial(callId: String = "") {
		let defaults = UserDefaults.standard
		guard let saved = defaults.dictionary(forKey: pendingDialKey) else { return }
		if !callId.isEmpty, let savedId = saved["callId"] as? String, savedId != callId { return }
		defaults.removeObject(forKey: pendingDialKey)
	}

	/// At launch: a dial was still ringing when the app last died. Inside its
	/// ring window, send the callee our cancel (`voice_end_v1`); after it, the
	/// callee's own 60 s backup already ended the call. Waits for the chat
	/// module's local signer (set once it starts) until the window ends.
	static func recoverDialAfterRelaunch() {
		let defaults = UserDefaults.standard
		guard let saved = defaults.dictionary(forKey: pendingDialKey) else { return }
		defaults.removeObject(forKey: pendingDialKey)
		let callId = saved["callId"] as? String ?? ""
		let sessionId = saved["sessionId"] as? String ?? ""
		let peer = saved["peer"] as? String ?? ""
		let timeoutAtMs = (saved["timeoutAtMs"] as? Int) ?? Int((saved["timeoutAtMs"] as? Double) ?? 0)
		let nowMs = Int(Date().timeIntervalSince1970 * 1000)
		guard !callId.isEmpty, !sessionId.isEmpty, peer.hasPrefix("0x"), peer.count == 42 else { return }
		guard nowMs < timeoutAtMs - 1_000 else {
			BeamioQALog.write("dialer relaunch: dial callId=\(callId.prefix(8)) died while ringing; window over, callee ends it")
			return
		}
		BeamioQALog.write("dialer relaunch: dial callId=\(callId.prefix(8)) died while ringing; cancel (windowLeftMs=\(timeoutAtMs - nowMs))")
		func attempt() {
			let now = Int(Date().timeIntervalSince1970 * 1000)
			guard now < timeoutAtMs - 1_000 else {
				BeamioQALog.write("dialer relaunch cancel not sent callId=\(callId.prefix(8)): window over before signer ready")
				return
			}
			guard BeamioConetChatSignBroker.hasLocalSigner(),
			      let secrets = BeamioChatPgpKeychain.load()
			else {
				DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { attempt() }
				return
			}
			let localEoa = secrets.eoa.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			guard localEoa.hasPrefix("0x"), localEoa.count == 42,
			      let target = makeDialerCancelTarget(
			      	callId: callId, sessionId: sessionId, localEoa: localEoa, peerEoa: peer, timeoutAtMs: timeoutAtMs
			      )
			else {
				BeamioQALog.write("dialer relaunch cancel not sent callId=\(callId.prefix(8)): callee keys")
				return
			}
			sealDialerSignal(target, type: "voice_end_v1", stampMs: now, requireRinging: false) { armor in
				guard let armor else {
					BeamioQALog.write("dialer relaunch cancel not sent callId=\(callId.prefix(8)): seal failed")
					return
				}
				let started = Date()
				let result = BeamioSiCipherPost.post(
					armor: armor,
					nodes: BeamioChatPgpKeychain.loadSiNodes(),
					excludeIps: target.excludeIps,
					maxAttempts: 4,
					timeout: 6,
					hedgeAfter: 0.6
				)
				BeamioQALog.write(
					"dialer relaunch cancel posted callId=\(callId.prefix(8)) ok=\(result.ok ? "yes" : "no") ms=\(Int(Date().timeIntervalSince(started) * 1000))"
				)
			}
		}
		DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { attempt() }
	}

	// MARK: - Wake receipt (`voice_call_ringing_v1`)

	/// Calls this device already told the caller about (callId → time sent).
	private static var ringingSent: [String: TimeInterval] = [:]
	/// Dials whose callee sent the receipt.
	private static var peerRinging: Set<String> = []
	/// Receipts that arrived before `attachOutgoingDialer` (callId → sender, time).
	private static var earlyRinging: [String: (from: String, at: TimeInterval)] = [:]

	/// Callee: tell the caller this device is ringing, once per call. Same path
	/// as Decline / Accept: caller user-PGP, caller mailbox route layer, random
	/// entry; NoPush (the caller is dialing in the foreground). Never for our own
	/// dial or a call that already ended.
	static func sendRingingIfNeeded(_ offer: BeamioVoiceOfferIdentity.Resolved) {
		guard offer.answerable, !offer.callId.isEmpty else { return }
		if wasRemoteEnded(callId: offer.callId, sessionId: offer.sessionId)
			|| wasLocallyEnded(callId: offer.callId, sessionId: offer.sessionId)
		{
			return
		}
		guard let secrets = BeamioChatPgpKeychain.load() else { return }
		let localEoa = secrets.eoa.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		let caller = offer.callerEoa.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard localEoa.hasPrefix("0x"), localEoa.count == 42, caller.hasPrefix("0x"), caller != localEoa else { return }
		let now = Date().timeIntervalSince1970
		lock.lock()
		ringingSent = ringingSent.filter { now - $0.value < 600 }
		if ringingSent[offer.callId] != nil {
			lock.unlock()
			return
		}
		ringingSent[offer.callId] = now
		lock.unlock()
		DispatchQueue.global(qos: .userInitiated).async {
			let nowMs = Int(now * 1000)
			let body: [String: Any] = [
				"type": "voice_call_ringing_v1",
				"callId": offer.callId,
				"sessionId": offer.sessionId,
				"from": localEoa,
				"to": caller,
				"createdAt": nowMs,
				"timestamp": nowMs,
			]
			let text = (try? JSONSerialization.data(withJSONObject: body)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
			var ok = false
			var attempt = 0
			while !text.isEmpty, !ok, attempt < 2 {
				if attempt > 0 { Thread.sleep(forTimeInterval: 0.7) }
				ok = BeamioVoiceV3.postChatMessage(
					text: text, localEoa: localEoa,
					peerUserPgp: offer.callerPgpArmored, peerRoute: offer.callerRouteArmored, noPush: true
				)
				attempt += 1
			}
			qaTrail("ringing receipt callId=\(offer.callId.prefix(8)) ok=\(ok ? "yes" : "no")")
			if !ok {
				lock.lock()
				ringingSent.removeValue(forKey: offer.callId)
				lock.unlock()
			}
		}
	}

	/// Caller: no receipt within this time → "Their phone may be restricting Beamio".
	static let peerWakeTimeout: TimeInterval = 8

	private static func schedulePeerWakeCheck(callId: String) {
		DispatchQueue.main.asyncAfter(deadline: .now() + peerWakeTimeout) {
			lock.lock()
			let stillRinging = activeCall.map { $0.role == .dialer && $0.offer.callId == callId && !$0.mediaEnabled } ?? false
			let rang = peerRinging.contains(callId)
			lock.unlock()
			guard stillRinging, !rang else { return }
			qaTrail("no ringing receipt in 8 s callId=\(callId.prefix(8))")
			BeamioInCallScreenModel.shared.notePeerWake(callId: callId, .restricted)
		}
	}

	/// Caller: no receipt after five ringback rings = 25 s from the offer's
	/// `createdAt` (`BeamioDialerReceiptRule`).
	static let peerUnreachableMs: Double = BeamioDialerReceiptRule.unreachableAfterMs

	/// No ringing receipt after five rings: the callee's phone never got the call
	/// (force stopped, switched off, push blocked). Main thread.
	/// - posts the cancel signed at dial, so a late push cannot ring the callee
	///   for a call that is over (the page gets `dialerCancelPosting` first and
	///   sends no cancel of its own; with no cancel ready the page sends one);
	/// - tells the page `callUnreachable` (it records `unreachable`);
	/// - stops the ringback, shows "Unreachable", ends the CallKit call 2 s later.
	/// The 60 s ring-window timer then finds no call and does nothing, and a
	/// receipt that comes later matches no call.
	static func dialerPeerUnreachable(callId: String) {
		lock.lock()
		let still = activeCall.map { $0.role == .dialer && $0.offer.callId == callId && !$0.mediaEnabled } ?? false
		let rang = peerRinging.contains(callId)
		lock.unlock()
		guard BeamioDialerReceiptRule.endsUnreachable(stillRinging: still, rang: rang) else { return }
		let posted = postDialerCancelIfRinging(callId: callId)
		lock.lock()
		guard let cur = activeCall, cur.role == .dialer, cur.offer.callId == callId, !cur.mediaEnabled else {
			lock.unlock()
			return
		}
		let sessionId = cur.listenSessionId
		activeCall = nil
		dialerCancel = nil
		dialerTimeout = nil
		dialerCancelSpentCallId = callId
		lock.unlock()
		clearPendingDial(callId: callId)
		qaTrail("dialer unreachable (no ringing receipt in \(Int(peerUnreachableMs / 1000)) s) callId=\(callId.prefix(8)) cancel=\(posted ? "native" : "page")")
		NSLog("[BeamioNativeVoice] dialer callUnreachable callId=%@", callId)
		BeamioNativeVoiceChannel.shared.stop()
		BeamioVoipIncomingBootstrap.shared.emitToWeb("callUnreachable", callId: callId, sessionId: sessionId)
		BeamioCallTonePlayer.shared.stopRingback(reason: "unreachable")
		BeamioInCallScreenModel.shared.showUnreachable(callId: callId)
		DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
			BeamioVoipIncomingBootstrap.shared.callKit.end(callId: callId, sessionId: sessionId)
		}
	}

	/// Caller: the callee's device sent `voice_call_ringing_v1` for our dial.
	static func dialerDidReceiveRinging(callId: String, from: String) {
		lock.lock()
		let match = activeCall.map {
			$0.role == .dialer && $0.offer.callId == callId && $0.peerEoa == from.lowercased()
		} ?? false
		if match {
			peerRinging.insert(callId)
		} else if !callId.isEmpty {
			// Not attached yet (or an older call is still active): attachOutgoingDialer checks this.
			earlyRinging[callId] = (from: from.lowercased(), at: Date().timeIntervalSince1970)
		}
		lock.unlock()
		guard match else { return }
		qaTrail("ringing receipt received callId=\(callId.prefix(8))")
		DispatchQueue.main.async {
			BeamioInCallScreenModel.shared.notePeerWake(callId: callId, .ringing)
		}
	}

	/// The channel learned the peer's relays (or moved ours): keep the call copy in step.
	static func updateV3Call(callId: String, v3: BeamioVoiceV3.Call) {
		lock.lock()
		if var cur = activeCall, cur.offer.callId == callId {
			cur.v3 = v3
			activeCall = cur
		}
		lock.unlock()
		prepareHangup(callId: callId)
	}

	// MARK: - Hang Up built ahead

	/// Our Hang Up for the connected call, sealed and encrypted to the peer's
	/// voice relay as soon as that relay is known. At Hang Up the shared route-PGP
	/// WebView is still busy with queued media frames (measured 2.6 s before the
	/// hang-up frame got its turn), so End posts this copy instead of encrypting.
	/// Memory only; rebuilt when the peer's relay changes, dropped with the call.
	private struct PreparedHangup {
		var callId: String
		var relayArmor: String
		var armor: String
	}
	private static var preparedHangup: PreparedHangup?
	private static var preparingHangupFor = ""

	private static func hangupBody(_ call: ActiveCall) -> [String: Any] {
		let nowMs = Int(Date().timeIntervalSince1970 * 1000)
		return [
			"type": "voice_end_v1",
			"callId": call.offer.callId,
			"sessionId": call.offer.sessionId,
			"from": call.localEoa,
			"to": call.peerEoa,
			"reason": "hangup",
			"createdAt": nowMs,
			"timestamp": nowMs,
		]
	}

	private static func prepareHangup(callId: String) {
		lock.lock()
		guard let call = activeCall, call.offer.callId == callId,
		      let v3 = call.v3, let relayArmor = v3.peerVoice.relay?.armor, !relayArmor.isEmpty,
		      v3.peerVoice.channel.locator != nil,
		      preparedHangup?.callId != callId || preparedHangup?.relayArmor != relayArmor,
		      preparingHangupFor != "\(callId)|\(relayArmor.hashValue)"
		else {
			lock.unlock()
			return
		}
		let tag = "\(callId)|\(relayArmor.hashValue)"
		preparingHangupFor = tag
		lock.unlock()
		DispatchQueue.global(qos: .utility).async {
			let armor = BeamioNativeVoiceChannel.sealV3ControlArmor(hangupBody(call), call: v3, seq: 0)
			lock.lock()
			if preparingHangupFor == tag { preparingHangupFor = "" }
			if let armor, activeCall?.offer.callId == callId,
			   activeCall?.v3?.peerVoice.relay?.armor == relayArmor
			{
				preparedHangup = PreparedHangup(callId: callId, relayArmor: relayArmor, armor: armor)
			}
			lock.unlock()
			BeamioQALog.write("hangup prepared callId=\(callId.prefix(8)) ok=\(armor != nil ? "yes" : "no")")
		}
	}

	/// The ready Hang Up for this call, if it still matches the peer's relay.
	private static func takePreparedHangup(callId: String, relayArmor: String) -> String? {
		lock.lock()
		defer { lock.unlock() }
		guard let p = preparedHangup, p.callId == callId, p.relayArmor == relayArmor else { return nil }
		preparedHangup = nil
		return p.armor
	}

	/// v3 dialer: the callee's accept arrived on our mailbox (chat message, signer
	/// recovered as `from`). Pick our relays, open our two channels, start media.
	static func dialerDidReceiveAcceptV3(accept: [String: Any], from: String) {
		let callId = (accept["callId"] as? String) ?? ""
		let ringId = (accept["sessionId"] as? String) ?? ""
		lock.lock()
		guard let cur = activeCall, cur.role == .dialer, cur.offer.proto == 3,
		      cur.offer.callId == callId, cur.offer.sessionId == ringId,
		      cur.peerEoa == from.lowercased(), !cur.mediaEnabled, cur.v3 == nil,
		      !inFlightAccept.contains("v3:\(callId)")
		else {
			lock.unlock()
			return
		}
		inFlightAccept.insert("v3:\(callId)")
		lock.unlock()
		clearPendingDial(callId: callId)
		BeamioCallTiming.mark("accept-rx")
		qaTrail("v3 accept rx callId=\(callId.prefix(8))")
		DispatchQueue.global(qos: .userInitiated).async {
			defer {
				lock.lock()
				inFlightAccept.remove("v3:\(callId)")
				lock.unlock()
			}
			guard let ch = accept["ch"] as? [String: Any],
			      var call = BeamioVoiceV3.callFromAccept(callId: callId, ch: ch)
			else {
				qaTrail("v3 accept unusable callId=\(callId.prefix(8))")
				return
			}
			var exclude: Set<String> = []
			if let mailbox = BeamioSiCipherPost.normalizeIp(BeamioChatPgpKeychain.loadMailboxIp()) { exclude.insert(mailbox) }
			let calleeRoute = BeamioAddressPgp.searchKey(address: cur.peerEoa)?.routePublicKeyArmored ?? ""
			let avoid = [BeamioChatPgpKeychain.loadRoutePublicArmor(), calleeRoute]
			guard let voiceRelay = BeamioVoiceV3.RelayNodes.pick(excludeIps: exclude, excludeArmors: avoid),
			      let videoRelay = BeamioVoiceV3.RelayNodes.pick(excludeIps: exclude, excludeArmors: avoid)
			else {
				qaTrail("v3 accept: no relay nodes cached")
				return
			}
			call.ownVoice.relay = voiceRelay
			call.ownVideo.relay = videoRelay
			lock.lock()
			guard var live = activeCall, live.role == .dialer, live.offer.callId == callId, !live.mediaEnabled else {
				lock.unlock()
				return
			}
			live.v3 = call
			live.peerMediaSessionId = call.peerVoice.channel.sid
			live.mediaEnabled = true
			activeCall = live
			dialerCancel = nil
			dialerTimeout = nil
			let snapshot = live
			lock.unlock()
			// The callee's relays came with its accept: build our Hang Up now.
			prepareHangup(callId: callId)
			NSLog("[BeamioNativeVoice] v3 dialer accept callId=%@", callId)
			BeamioNativeVoiceChannel.shared.start(active: snapshot)
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
	}

	/// v3 dialer: the callee declined or timed out (chat message to our mailbox).
	static func dialerDidReceiveRejectV3(type: String, callId: String, from: String, reason: String = "") {
		lock.lock()
		let match = activeCall.map {
			$0.role == .dialer && $0.offer.proto == 3 && $0.offer.callId == callId && $0.peerEoa == from.lowercased() && !$0.mediaEnabled
		} ?? false
		lock.unlock()
		guard match else { return }
		// Only the verified callee (signer == the peer we dialed) can say "busy".
		if type == "voice_call_reject_v1" && reason == "busy" {
			dialerDidReceiveBusy()
			return
		}
		dialerDidReceiveReject(action: type == "voice_call_timeout_v1" ? "callTimedOut" : "callRejected")
	}

	/// The callee is in another call: the page records "busy", the screen says
	/// so, the busy tone plays on the call's audio session (about 3 s), then
	/// CallKit ends the call.
	static func dialerDidReceiveBusy() {
		lock.lock()
		guard let cur = activeCall, cur.role == .dialer else {
			lock.unlock()
			return
		}
		let callId = cur.offer.callId
		let sessionId = cur.listenSessionId
		activeCall = nil
		dialerCancel = nil
		dialerTimeout = nil
		lock.unlock()
		clearPendingDial(callId: callId)
		qaTrail("dialer busy callId=\(callId.prefix(8))")
		NSLog("[BeamioNativeVoice] dialer callBusy callId=%@", callId)
		BeamioNativeVoiceChannel.shared.stop()
		DispatchQueue.main.async {
			BeamioVoipIncomingBootstrap.shared.emitToWeb("callBusy", callId: callId, sessionId: sessionId)
			BeamioInCallScreenModel.shared.showBusy(callId: callId)
			BeamioCallTonePlayer.shared.playBusy {
				BeamioVoipIncomingBootstrap.shared.callKit.end(callId: callId, sessionId: sessionId)
			}
		}
	}

	/// Ring window for every call (PWA `INCOMING_CALL_RING_TIMEOUT_MS`, Android
	/// `INCOMING_RING_TIMEOUT_MS`): 60 s from the offer's `createdAt`.
	static let ringWindowMs: Double = 60_000

	/// The offer can no longer be ringing — the page's `isVoiceCallOfferRinging`
	/// rule: its `expiresAt` has passed, or it was created (`createdAt`, else
	/// `timestamp`) more than the ring window plus 15 s ago. Seconds or ms.
	/// Missing fields → false.
	private static func offerRingWindowOver(line: String) -> Bool {
		guard let offer = BeamioVoiceOfferIdentity.extractVoiceOffer(from: line) else { return false }
		func ms(_ raw: Any?) -> Double {
			let v: Double = (raw as? Double) ?? (raw as? NSNumber)?.doubleValue
				?? Double((raw as? String) ?? "") ?? 0
			guard v > 0, v.isFinite else { return 0 }
			return v < 100_000_000_000 ? v * 1000 : v
		}
		let now = Date().timeIntervalSince1970 * 1000
		let expires = ms(offer["expiresAt"])
		if expires > 0, expires <= now { return true }
		let created = ms(offer["createdAt"]) > 0 ? ms(offer["createdAt"]) : ms(offer["timestamp"])
		guard created > 0 else { return false }
		return now - created > ringWindowMs + 15_000
	}

	/// A voice signal object inside a chat line (nested `text`, base64 envelopes).
	private static func voiceSignal(in line: String, types: Set<String>) -> [String: Any]? {
		func walk(_ value: Any, depth: Int) -> [String: Any]? {
			guard depth < 8 else { return nil }
			if let text = value as? String {
				let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
				if let data = trimmed.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) {
					return walk(parsed, depth: depth + 1)
				}
				if let data = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]) ?? BeamioLenientBase64.decode(trimmed),
				   let decoded = String(data: data, encoding: .utf8),
				   let parsed = try? JSONSerialization.jsonObject(with: Data(decoded.utf8))
				{
					return walk(parsed, depth: depth + 1)
				}
				return nil
			}
			guard let obj = value as? [String: Any] else { return nil }
			if let type = obj["type"] as? String, types.contains(type) { return obj }
			if let inner = obj["text"] { return walk(inner, depth: depth + 1) }
			return nil
		}
		return walk(line, depth: 0)
	}

	/// The callee declined or timed out (chat message to our mailbox).
	static func dialerDidReceiveReject(action: String) {
		lock.lock()
		guard let cur = activeCall, cur.role == .dialer else {
			lock.unlock()
			return
		}
		let callId = cur.offer.callId
		let sessionId = cur.listenSessionId
		activeCall = nil
		dialerCancel = nil
		dialerTimeout = nil
		lock.unlock()
		clearPendingDial(callId: callId)
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
			if t == "timeout" { return "timeout" }
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

		// Busy (we are in a call, or another call rings here): tell the new
		// caller now, so it hears the busy tone while it dials. A resolved offer
		// is sealed with the OpenPGP host its decrypt already loaded. v69: never
		// resolveOfferSync here — booting the hidden WKWebView during a live
		// call dropped the Incoming banner (v68) — so an unresolved offer waits
		// for its resolve (`rememberOffer`) or for our call to end.
		if protectStickyChrome {
			let resolved = cachedOffer(callId: callId, sessionId: sessionId).flatMap { $0.answerable ? $0 : nil }
			lock.lock()
			let decision = busyRejects.busyCallArrived(
				callId: callId, sessionId: sessionId, reason: rejectReason, resolved: resolved
			)
			inFlightDecline.remove(key)
			lock.unlock()
			switch decision {
			case .sendNow(let now):
				BeamioQALog.write("busy reject now callId=\(now.callId.prefix(8))")
				DispatchQueue.global(qos: .userInitiated).async {
					sendDeclineUplink(offer: now, rejectReason: rejectReason)
				}
				return
			case .alreadySent:
				// Same call seen again (chat offer, then its VoIP push): one reject is enough.
				BeamioQALog.write("busy reject already sent callId=\(callId.prefix(8))")
				return
			case .wait:
				break
			}
			BeamioQALog.write("busy reject waits for the offer callId=\(callId.prefix(8))")
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
					"[BeamioNativeVoice] decline skip — no v3 offer callId=%@ sessionId=%@ reason=%@ (no bg task)",
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

	/// Busy rejects whose offer never resolved during our call. Call only after
	/// the sticky Incoming call is gone: resolving may boot the OpenPGP WebView.
	static func flushDeferredStickyDeclines() {
		lock.lock()
		let pending = busyRejects.ownCallEnded()
		lock.unlock()
		guard !pending.isEmpty else { return }
		BeamioQALog.write("busy reject after our call ended count=\(pending.count)")
		DispatchQueue.global(qos: .userInitiated).async {
			for item in pending {
				guard let offer = resolveOfferSync(callId: item.callId, sessionId: item.sessionId) else {
					BeamioQALog.write("busy reject skipped: no offer callId=\(item.callId.prefix(8))")
					continue
				}
				sendDeclineUplink(offer: offer, rejectReason: item.reason)
			}
		}
	}

	/// Our call ended by either side (a remote end runs no CXEndCallAction):
	/// send busy rejects still waiting for their offer once no CallKit call is live.
	private static func flushBusyRejectsWhenIdle() {
		lock.lock()
		let any = !busyRejects.waiting.isEmpty
		lock.unlock()
		guard any else { return }
		for delay in [0.0, 1.5] {
			DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
				guard !BeamioVoipIncomingBootstrap.shared.callKit.hasLiveCallKitCall() else { return }
				flushDeferredStickyDeclines()
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
			// An unanswered ring is a timeout for the caller, not a Decline.
			"type": rejectReason == "timeout" ? "voice_call_timeout_v1" : "voice_call_reject_v1",
			"callId": offer.callId,
			"sessionId": offer.sessionId,
			"from": localEoa,
			"to": offer.callerEoa.lowercased(),
			"reason": rejectReason,
			"createdAt": nowMs,
			"timestamp": nowMs,
		]
		// To the caller's mailbox: the caller has no channel while ringing.
		let text = (try? JSONSerialization.data(withJSONObject: body)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
		let started = Date()
		let ok = !text.isEmpty && BeamioVoiceV3.postChatMessage(
			text: text, localEoa: localEoa,
			peerUserPgp: offer.callerPgpArmored, peerRoute: offer.callerRouteArmored, noPush: false
		)
		BeamioQALog.write(
			"decline posted callId=\(offer.callId.prefix(8)) reason=\(rejectReason) ok=\(ok ? "yes" : "no") ms=\(Int(Date().timeIntervalSince(started) * 1000))"
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

	/// Hang Up of a connected call (either role): an AES `voice_end_v1` on the
	/// peer's voice channel so its call screen ends. Without this the shell only closed its own
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
		      let v3 = call.v3
		else { return }

		// Take the call's warm uplink entries now: `stop()` clears the route next.
		let warmEntries = BeamioNativeVoiceChannel.shared.warmEntriesForControl()
		let prepared = v3.peerVoice.relay.flatMap { takePreparedHangup(callId: callId, relayArmor: $0.armor) }
		let started = Date()

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
			let ok: Bool
			if let armor = prepared {
				ok = BeamioNativeVoiceChannel.postV3ControlArmor(armor, call: v3, preferredEntries: warmEntries)
			} else {
				ok = BeamioNativeVoiceChannel.postV3Control(hangupBody(call), call: v3, preferredEntries: warmEntries)
			}
			BeamioQALog.write(
				"hangup uplink callId=\(call.offer.callId.prefix(8)) ok=\(ok ? "yes" : "no") ms=\(Int(Date().timeIntervalSince(started) * 1000)) warm=\(warmEntries.count) prepared=\(prepared != nil ? "yes" : "no")"
			)
			NSLog(
				"[BeamioNativeVoice] hangup uplink callId=%@ role=%@ ok=%@",
				call.offer.callId,
				call.role.rawValue,
				ok ? "yes" : "no"
			)
			if !ok {
				// The channel frame did not go (the peer's relay unknown, its channel
				// gone, or our frame encryption failed): tell its mailbox instead.
				let sent = postHangupToMailbox(call)
				BeamioQALog.write("hangup mailbox fallback callId=\(call.offer.callId.prefix(8)) ok=\(sent ? "yes" : "no")")
			}
		}
	}

	/// `voice_end_v1` to the peer's mailbox (signed chat message, as Decline).
	/// Callee: the caller's keys came in the offer; caller: the callee's keys
	/// from the chain (the offer holds our own). Two tries. Blocking.
	private static func postHangupToMailbox(_ call: ActiveCall) -> Bool {
		let keys: (user: String, route: String)?
		if call.role == .callee {
			keys = (call.offer.callerPgpArmored, call.offer.callerRouteArmored)
		} else {
			keys = BeamioAddressPgp.searchKey(address: call.peerEoa).map { ($0.userPublicKeyArmored, $0.routePublicKeyArmored) }
		}
		guard let keys, keys.user.contains("BEGIN PGP PUBLIC KEY"), keys.route.contains("BEGIN PGP PUBLIC KEY"),
		      let data = try? JSONSerialization.data(withJSONObject: hangupBody(call)),
		      let text = String(data: data, encoding: .utf8)
		else { return false }
		for attempt in 0 ..< 2 {
			if attempt > 0 { Thread.sleep(forTimeInterval: 0.6) }
			if BeamioVoiceV3.postChatMessage(
				text: text, localEoa: call.localEoa, peerUserPgp: keys.user, peerRoute: keys.route, noPush: true
			) { return true }
		}
		return false
	}

	/// CallKit Answer: voice v3 accept to the caller's mailbox; starts our channels.
	/// `mediaDeferred`: sent at Answer, before CallKit activates the audio session;
	/// capture starts in [calleeAudioActivated]. Network work does not wait for audio.
	static func sendAccept(
		callId: String,
		sessionId: String,
		mediaDeferred: Bool = false,
		completion: ((String) -> Void)? = nil
	) {
		let key = "\(callId)|\(sessionId)"
		lock.lock()
		if inFlightAccept.contains(key) || acceptStarted.contains(callId) {
			lock.unlock()
			completion?("")
			return
		}
		inFlightAccept.insert(key)
		if acceptStarted.count > 32 { acceptStarted.removeAll() }
		acceptStarted.insert(callId)
		if !mediaDeferred { calleeAudioReady.insert(callId) }
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
				for tick in 0..<20 {
					// The first fetch came back empty (offer not stored yet, or the
					// entry or mailbox was briefly down): fetch again every second
					// instead of only waiting for the chat listen to deliver it.
					if tick % 2 == 0 {
						BeamioVoiceOfferIdentity.resolve(callId: callId, sessionId: sessionId) { resolved in
							if let resolved, resolved.answerable { rememberOffer(resolved) }
						}
					}
					Thread.sleep(forTimeInterval: 0.5)
					if let hit = cachedOffer(callId: callId, sessionId: sessionId), hit.answerable {
						resolvedOffer = hit
						break
					}
				}
			}
			guard let offer = resolvedOffer else {
				BeamioQALog.write("accept skip: no v3 offer callId=\(callId.prefix(8)); ending local call")
				NSLog(
					"[BeamioNativeVoice] accept skip — no v3 offer callId=%@ sessionId=%@",
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
			sendAcceptV3(offer: offer, localEoa: localEoa, completion: completion)
		}
	}

	/// CallKit activated the call's audio session: start capture and playout on
	/// the callee call. If the accept never started (no Answer seen), start it now.
	static func calleeAudioActivated(callId: String, sessionId: String, completion: ((String) -> Void)? = nil) {
		lock.lock()
		calleeAudioReady.insert(callId)
		if calleeAudioReady.count > 32 { calleeAudioReady = [callId] }
		let started = acceptStarted.contains(callId)
		var enable: ActiveCall?
		if var cur = activeCall, cur.role == .callee, cur.offer.callId == callId, !cur.mediaEnabled {
			cur.mediaEnabled = true
			activeCall = cur
			enable = cur
		}
		lock.unlock()
		if let enable {
			qaTrail("callee media on audio activate callId=\(callId.prefix(8))")
			BeamioNativeVoiceChannel.shared.enableMedia(active: enable)
			return
		}
		if !started {
			sendAccept(callId: callId, sessionId: sessionId, completion: completion)
		}
		// Started and still building: sendAcceptV3 reads calleeAudioReady when it creates the call.
	}

	/// v3 Answer: create the four paid channels (our wallet pays), open our two
	/// on relays we pick, and send the accept to the caller's mailbox as a chat
	/// message (recipient PGP + mailbox route layer, random entry). Runs off main.
	private static func sendAcceptV3(
		offer: BeamioVoiceOfferIdentity.Resolved,
		localEoa: String,
		completion: ((String) -> Void)?
	) {
		func fail(_ why: String) {
			qaTrail("v3 accept failed: \(why) callId=\(offer.callId.prefix(8))")
			lock.lock()
			acceptStarted.remove(offer.callId)
			lock.unlock()
			DispatchQueue.main.async {
				BeamioInCallScreenModel.shared.end(callId: offer.callId)
				BeamioVoipIncomingBootstrap.shared.callKit.end(callId: offer.callId, sessionId: offer.sessionId)
				completion?("")
			}
		}
		guard let wallet = BeamioChatWalletKeychain.load(), wallet.eoa.lowercased() == localEoa else {
			return fail("no stored wallet key")
		}
		BeamioCallTiming.mark("accept-v3-start")
		var made: [BeamioVoiceV3.Own] = []
		var sealedAccept: String?
		if let prepared = takePreparedChannels(offer.callId) {
			made = prepared.made
			sealedAccept = prepared.acceptArmor
			qaTrail("v3 accept uses channels prepared while ringing callId=\(offer.callId.prefix(8)) sealed=\(sealedAccept == nil ? "no" : "yes")")
		} else {
			for _ in 0 ..< 4 {
				guard let own = BeamioVoiceV3.newPaidChannel(payerKeyHex: wallet.privateKeyHex, payerEoa: localEoa) else {
					return fail("sign")
				}
				made.append(own)
			}
			var exclude: Set<String> = []
			if let mailbox = BeamioSiCipherPost.normalizeIp(BeamioChatPgpKeychain.loadMailboxIp()) { exclude.insert(mailbox) }
			let avoid = [BeamioChatPgpKeychain.loadRoutePublicArmor(), offer.callerRouteArmored]
			guard let voiceRelay = BeamioVoiceV3.RelayNodes.pick(excludeIps: exclude, excludeArmors: avoid),
			      let videoRelay = BeamioVoiceV3.RelayNodes.pick(excludeIps: exclude, excludeArmors: avoid)
			else { return fail("no relay nodes cached") }
			made[2].relay = voiceRelay
			made[3].relay = videoRelay
		}
		let cv = made[0], cV = made[1]
		let ev = made[2], eV = made[3]
		// Sealed while ringing: Answer only posts it (native HTTP, no crypto WebView).
		let text: String
		if sealedAccept != nil {
			text = ""
		} else {
			guard let built = acceptText(offer: offer, localEoa: localEoa, made: made) else { return fail("encode") }
			text = built
		}
		let call = BeamioVoiceV3.Call(
			callId: offer.callId,
			ownVoice: ev,
			ownVideo: eV,
			peerVoice: .init(channel: cv.channel, relay: nil),
			peerVideo: .init(channel: cV.channel, relay: nil)
		)
		lock.lock()
		// Media only once CallKit's audio session is up; the listens and the accept go now.
		let active = ActiveCall(
			role: .callee,
			offer: offer,
			listenSessionId: ev.channel.sid,
			peerMediaSessionId: cv.channel.sid,
			peerEoa: offer.callerEoa.lowercased(),
			localEoa: localEoa,
			mediaEnabled: calleeAudioReady.contains(offer.callId),
			v3: call
		)
		activeCall = active
		lock.unlock()
		// Our listens open beside the accept post; the caller's media waits for them anyway.
		BeamioNativeVoiceChannel.shared.start(active: active)
		var ok = false
		for attempt in 0 ..< 3 {
			if let sealed = sealedAccept {
				ok = BeamioVoiceV3.postSealedChatMessage(armor: sealed, peerRoute: offer.callerRouteArmored)
			} else {
				ok = BeamioVoiceV3.postChatMessage(
					text: text, localEoa: localEoa,
					peerUserPgp: offer.callerPgpArmored, peerRoute: offer.callerRouteArmored, noPush: true
				)
			}
			BeamioQALog.write("v3 accept post attempt=\(attempt + 1) ok=\(ok ? "yes" : "no") sealed=\(sealedAccept == nil ? "no" : "yes")")
			if ok { break }
			Thread.sleep(forTimeInterval: 0.6 * Double(attempt + 1))
		}
		BeamioCallTiming.mark("accept-v3-sent")
		guard ok else {
			BeamioNativeVoiceChannel.shared.stop()
			lock.lock()
			if activeCall?.offer.callId == offer.callId { activeCall = nil }
			lock.unlock()
			return fail("post")
		}
		let answered = offer
		DispatchQueue.main.async {
			BeamioInCallScreenModel.shared.begin(
				callId: answered.callId,
				sessionId: answered.sessionId,
				tag: answered.beamioTag,
				address: answered.callerEoa
			)
			completion?(ev.channel.sid)
		}
	}

	// MARK: - Resolve + uplink

	private static func resolveOfferSync(
		callId: String,
		sessionId: String
	) -> BeamioVoiceOfferIdentity.Resolved? {
		if let hit = cachedOffer(callId: callId, sessionId: sessionId), hit.answerable {
			return hit
		}
		let sem = DispatchSemaphore(value: 0)
		var fetched: BeamioVoiceOfferIdentity.Resolved?
		BeamioVoiceOfferIdentity.resolve(callId: callId, sessionId: sessionId) { resolved in
			fetched = resolved
			sem.signal()
		}
		_ = sem.wait(timeout: .now() + 20)
		guard let hit = fetched, hit.answerable else { return nil }
		rememberOffer(hit)
		return hit
	}

}
