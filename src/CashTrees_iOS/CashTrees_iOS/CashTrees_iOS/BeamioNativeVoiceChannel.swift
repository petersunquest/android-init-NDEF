import AVFoundation
import AudioToolbox
import ConetChatSDK
import Foundation
import UIKit

/// Native temporary voice relay: `voice_listen` SSE + AES PCM uplink/downlink.
/// No PWA — uses Keychain route PGP + `BeamioSiCipherPost` entry path.
final class BeamioNativeVoiceChannel: NSObject {
	static let shared = BeamioNativeVoiceChannel()

	private let queue = DispatchQueue(label: "com.beamio.nativeVoiceChannel", qos: .userInitiated)
	private var active: BeamioNativeVoiceSignaling.ActiveCall?
	/// `voice_listen` SSE over plain HTTP/TCP (`BeamioSiCipherPost.postSse`).
	/// URLSession cannot reach `http://IP` entries: ATS answers `-1022`.
	private var listenHandle: BeamioSiCipherPost.SseHandle?
	/// Next uplink sequence number. Media frames and the Hang Up control frame share
	/// one stream: the receiver (`VoiceFrameReorderBuffer`) drops any frame whose
	/// seq is below what it already delivered, so a control frame sent as seq 0
	/// after the media started was silently discarded. The lock lets the CallKit
	/// End callback (main thread) take a number without waiting on `queue`.
	private let seqLock = NSLock()
	private var uplinkSeq: Int = 1

	func takeUplinkSeq() -> Int {
		seqLock.lock()
		defer { seqLock.unlock() }
		let seq = uplinkSeq
		uplinkSeq += 1
		return seq
	}

	private func resetUplinkSeq() {
		seqLock.lock()
		uplinkSeq = 1
		seqLock.unlock()
	}

	/// Mute drops microphone frames before they are framed and sent; playback is
	/// untouched. It is set from the CallKit Mute control (system UI and the in-call
	/// screen both go through `CXSetMutedCallAction`) and cleared when a call starts.
	private let muteLock = NSLock()
	private var micMuted = false

	var isMuted: Bool {
		muteLock.lock()
		defer { muteLock.unlock() }
		return micMuted
	}

	func setMuted(_ muted: Bool) {
		muteLock.lock()
		micMuted = muted
		muteLock.unlock()
		NSLog("[BeamioNativeVoiceChannel] mute=%@", muted ? "on" : "off")
	}

	// MARK: PWA wire format
	// A frame is `BPCM` + uint32-LE sample rate + int16-LE mono PCM, then AES-GCM.
	// The PWA (`voiceCallMedia.ts`) decodes any frame length; it sends 80 ms, the shells 160 ms.
	private static let pcmMagic: [UInt8] = [0x42, 0x50, 0x43, 0x4D]
	/// FaceTime JPEG: `BJPG` + u16-LE width + u16-LE height + u32-LE frameId + JPEG bytes.
	private static let jpgMagic: [UInt8] = [0x42, 0x4A, 0x50, 0x47]
	private static let wireRate = 16_000
	/// 160 ms per packet. Each packet costs a route-PGP encrypt plus a relay POST;
	/// 80 ms packets could not be sent in real time and were dropped.
	private static let frameSamples = 2_560
	/// Frames POSTed concurrently. Beyond this the oldest realtime audio is dropped
	/// instead of queueing: late audio is worse than lost audio.
	private static let maxUplinkInFlight = 10
	/// Largest audio packet when the sender is behind (~250 ms). The SI relay
	/// rejects a frame whose base64 payload exceeds 12 000 chars (≈ 8.9 KB raw).
	private static let maxPacketBytes = 8_000
	private static let maxVideoUplinkInFlight = 2
	/// Playback queued beyond this is dropped so latency cannot grow without bound.
	private static let maxPlayBacklogSamples = 9_600
	private var videoUplinkInFlight = 0
	private var videoFrameId: UInt32 = 0
	private var onRemoteVideoFrame: ((UIImage) -> Void)?
	private var onPeerVideoEnabled: ((Bool) -> Void)?

	private struct UplinkRoute {
		var routePublicKeyArmor: String
		var nodes: [BeamioChatPgpKeychain.SiNode]
		var exclude: Set<String>
		/// Each frame goes to a different random entry (CoNET Chat: random entry per delivery).
		var entries: BeamioEntryRotation
	}

	/// Downlink jitter / reorder (~120ms). Wait for late nextSeq instead of hard-dropping OOO.
	private var rxNextSeq: Int?
	private var rxPendingPcm: [Int: Data] = [:]
	private var rxPendingJpeg: [Int: (image: UIImage, senderTs: Int64)] = [:]
	private var rxJitterWorkItem: DispatchWorkItem?
	/// Wait this long for a late / out-of-order frame (matches the playout depth).
	private static let rxJitterSeconds: TimeInterval = 0.320
	/// Playout depth before audio starts, and again after an underrun (320 ms).
	private static let playoutTargetSamples = 5_120
	/// Fade-in after a gap or underrun so the restart does not click (5 ms).
	private static let fadeSamples = 80
	/// Missing frames filled with silence at most.
	private static let maxConcealFrames = 2
	/// Video is shown this long after its earliest possible arrival (≈ audio delay).
	private static let videoPlayoutDelayMs: Int64 = 300
	private var playPrebuffering = true
	private var playPending: [Data] = []
	private var playPendingSamples = 0
	private var playFadeNext = true
	private var videoMinDeltaMs: Int64?
	private var videoLastSenderTs: Int64 = 0
	private static let rxMaxPendingFrames = 48
	private var rxBacklogSamples = 0
	private var uplinkAccum = Data()
	/// Peer route key + one reachable entry, resolved once per call (never per frame).
	private var uplinkRoute: UplinkRoute?
	private var uplinkRouteResolving = false
	private var uplinkInFlight = 0
	private var uplinkFailStreak = 0
	private var uplinkLogged = 0
	private let uplinkPostQueue = DispatchQueue(
		label: "com.beamio.nativeVoiceChannel.uplinkPost",
		qos: .userInitiated,
		attributes: .concurrent
	)
	private var engine: AVAudioEngine?
	/// Route changes (speaker / receiver / headset) stop AVAudioEngine; this
	/// observer rebuilds it so audio continues on the new route.
	private var engineConfigObserver: NSObjectProtocol?
	/// Diagnostics: RMS of what the mixer sends to the output, and a 2 s status log.
	private var mixerRms: Float = 0
	private var diagTimer: DispatchSourceTimer?
	private var videoFramesIn = 0
	private var videoFramesSent = 0
	private var videoDropNoRoute = 0
	private var videoDropBusy = 0
	private var videoDropAudioFirst = 0
	private var playerNode: AVAudioPlayerNode?
	private var converter: AVAudioConverter?
	private var running = false
	/// Current `voice_listen` entry IP — scored on HTTP/connect outcomes.
	private var listenEntryIp: String?
	private var listenStartedAt: Date?

	private override init() {
		super.init()
	}

	func start(active: BeamioNativeVoiceSignaling.ActiveCall) {
		queue.async { [weak self] in
			guard let self else { return }
			self.stopLocked()
			self.active = active
			self.running = true
			self.resetUplinkSeq()
			self.setMuted(false)
			self.resetMediaStateLocked()
			NSLog(
				"[BeamioNativeVoiceChannel] start role=%@ callId=%@ listen=%@ media=%@",
				active.role.rawValue,
				active.offer.callId,
				active.listenSessionId,
				active.mediaEnabled ? "yes" : "no"
			)
			self.startVoiceListenLocked(active: active)
			if active.mediaEnabled {
				DispatchQueue.main.async {
					self.startAudioEngine(active: active)
				}
			}
		}
	}

	/// Dialer: enable PCM after remote accept (listen already running).
	func enableMedia(active: BeamioNativeVoiceSignaling.ActiveCall) {
		queue.async { [weak self] in
			guard let self, self.running else { return }
			self.active = active
			DispatchQueue.main.async {
				self.startAudioEngine(active: active)
			}
		}
	}

	func stop() {
		queue.async { [weak self] in
			self?.stopLocked()
		}
		DispatchQueue.main.async { [weak self] in
			self?.stopAudioEngine()
		}
	}

	private func resetMediaStateLocked() {
		rxJitterWorkItem?.cancel()
		rxJitterWorkItem = nil
		rxNextSeq = nil
		rxPendingPcm.removeAll()
		rxPendingJpeg.removeAll()
		rxBacklogSamples = 0
		playPrebuffering = true
		playPending.removeAll()
		playPendingSamples = 0
		playFadeNext = true
		videoMinDeltaMs = nil
		videoLastSenderTs = 0
		uplinkAccum = Data()
		uplinkRoute = nil
		uplinkRouteResolving = false
		uplinkInFlight = 0
		uplinkFailStreak = 0
		uplinkLogged = 0
		videoUplinkInFlight = 0
		videoFrameId = 0
		videoFramesIn = 0
		videoFramesSent = 0
		videoDropNoRoute = 0
		videoDropBusy = 0
		videoDropAudioFirst = 0
	}

	/// InCall UI registers remote FaceTime handlers (main thread may call).
	func setRemoteVideoHandlers(
		onFrame: ((UIImage) -> Void)?,
		onPeerEnabled: ((Bool) -> Void)?
	) {
		queue.async { [weak self] in
			self?.onRemoteVideoFrame = onFrame
			self?.onPeerVideoEnabled = onPeerEnabled
		}
	}

	/// Announce this party's FaceTime on/off (AES JSON control; does not hang up).
	func sendVideoEnableControl(enabled: Bool) {
		queue.async { [weak self] in
			guard let self, let active = self.active, self.running else { return }
			guard active.mediaEnabled, !active.peerMediaSessionId.isEmpty else { return }
			let type = enabled ? "voice_video_enable_v1" : "voice_video_disable_v1"
			let body: [String: Any] = [
				"type": type,
				"callId": active.offer.callId,
				"sessionId": active.listenSessionId,
				"from": active.localEoa,
				"timestamp": Int(Date().timeIntervalSince1970 * 1000),
			]
			self.sendControlJsonUplink(body, active: active)
			NSLog(
				"[BeamioNativeVoiceChannel] video control %@ callId=%@",
				type,
				active.offer.callId
			)
		}
	}

	/// JPEG uplink for FaceTime (BJPG wire). Dropped when peer media session missing.
	func sendVideoJpegFrame(_ jpeg: Data, width: Int, height: Int) {
		queue.async { [weak self] in
			guard let self, let active = self.active, self.running else { return }
			guard active.mediaEnabled, !jpeg.isEmpty else { return }
			guard !active.peerMediaSessionId.isEmpty else { return }
			let peer = active.peerEoa.lowercased()
			guard peer.hasPrefix("0x"), peer.count == 42 else { return }
			self.videoFramesIn += 1
			if self.videoFramesIn <= 3 || self.videoFramesIn % 25 == 0 {
				NSLog(
					"[BeamioNativeVoiceChannel] video in=%d sent=%d noRoute=%d busy=%d audioFirst=%d bytes=%d",
					self.videoFramesIn, self.videoFramesSent, self.videoDropNoRoute,
					self.videoDropBusy, self.videoDropAudioFirst, jpeg.count
				)
			}
			guard let route = self.uplinkRoute else {
				self.videoDropNoRoute += 1
				self.resolveUplinkRouteIfNeeded(peer: peer, callId: active.offer.callId)
				return
			}
			// Audio first: skip video while audio has half its send slots in use.
			if self.uplinkInFlight >= Self.maxUplinkInFlight / 2 {
				self.videoDropAudioFirst += 1
				return
			}
			if self.videoUplinkInFlight >= Self.maxVideoUplinkInFlight {
				self.videoDropBusy += 1
				return
			}
			self.videoFramesSent += 1
			self.videoFrameId &+= 1
			let frameId = self.videoFrameId
			var framed = Data(Self.jpgMagic)
			var w = UInt16(clamping: width).littleEndian
			var h = UInt16(clamping: height).littleEndian
			var fid = frameId.littleEndian
			withUnsafeBytes(of: &w) { framed.append(contentsOf: $0) }
			withUnsafeBytes(of: &h) { framed.append(contentsOf: $0) }
			withUnsafeBytes(of: &fid) { framed.append(contentsOf: $0) }
			framed.append(jpeg)
			let payload: String
			do {
				let key = try BeamioVoiceAesGcm.keyFromBase64(active.offer.sessionKey)
				payload = try BeamioVoiceAesGcm.encrypt(key: key, plain: framed)
			} catch {
				return
			}
			let seq = self.takeUplinkSeq()
			let nowMs = Int(Date().timeIntervalSince1970 * 1000)
			let uplink: [String: Any] = [
				// Route command read by the peer's mailbox: no wallet fields.
				"command": "voice_uplink",
				"type": "voice_frame_v1",
				"callId": active.offer.callId,
				"sessionId": active.listenSessionId,
				"targetSessionId": active.peerMediaSessionId,
				"direction": "uplink",
				"seq": seq,
				"frameTimestamp": nowMs,
				"mediaKind": "video",
				"payload": payload,
				"timestamp": Int(Date().timeIntervalSince1970),
			]
			guard let jsonData = try? JSONSerialization.data(withJSONObject: uplink, options: []),
			      let jsonUtf8 = String(data: jsonData, encoding: .utf8)
			else { return }
			let opaque = Data(jsonUtf8.utf8).base64EncodedString()
			guard let entryIp = route.entries.next() else { return }
			self.videoUplinkInFlight += 1
			BeamioOpenPgpHost.shared.encrypt(
				plaintext: opaque,
				publicKeyArmor: route.routePublicKeyArmor
			) { [weak self] result in
				guard let self else { return }
				guard let armor = try? result.get(), armor.contains("BEGIN PGP MESSAGE") else {
					self.queue.async { self.videoUplinkInFlight = max(0, self.videoUplinkInFlight - 1) }
					return
				}
				self.uplinkPostQueue.async {
					let outcome = Self.postDirect(armor: armor, ip: entryIp)
					self.noteEntryOutcome(outcome, ip: entryIp, route: route)
					self.queue.async {
						self.videoUplinkInFlight = max(0, self.videoUplinkInFlight - 1)
						self.finishUplink(outcome, ip: entryIp)
					}
				}
			}
		}
	}

	private func sendControlJsonUplink(_ body: [String: Any], active: BeamioNativeVoiceSignaling.ActiveCall) {
		let peer = active.peerEoa.lowercased()
		guard peer.hasPrefix("0x"), peer.count == 42 else { return }
		guard let route = uplinkRoute else {
			resolveUplinkRouteIfNeeded(peer: peer, callId: active.offer.callId)
			return
		}
		let payload: String
		do {
			let key = try BeamioVoiceAesGcm.keyFromBase64(active.offer.sessionKey)
			let jsonData = try JSONSerialization.data(withJSONObject: body, options: [])
			payload = try BeamioVoiceAesGcm.encrypt(key: key, plain: jsonData)
		} catch {
			return
		}
		let seq = takeUplinkSeq()
		let nowMs = Int(Date().timeIntervalSince1970 * 1000)
		let uplink: [String: Any] = [
			// Route command read by the peer's mailbox: no wallet fields.
			"command": "voice_uplink",
			"type": "voice_frame_v1",
			"callId": active.offer.callId,
			"sessionId": active.listenSessionId,
			"targetSessionId": active.peerMediaSessionId,
			"direction": "uplink",
			"seq": seq,
			"frameTimestamp": nowMs,
			"payload": payload,
			"timestamp": Int(Date().timeIntervalSince1970),
		]
		guard let jsonData = try? JSONSerialization.data(withJSONObject: uplink, options: []),
		      let jsonUtf8 = String(data: jsonData, encoding: .utf8)
		else { return }
		let opaque = Data(jsonUtf8.utf8).base64EncodedString()
		guard let entryIp = route.entries.next() else { return }
		BeamioOpenPgpHost.shared.encrypt(
			plaintext: opaque,
			publicKeyArmor: route.routePublicKeyArmor
		) { [weak self] result in
			guard let self else { return }
			guard let armor = try? result.get(), armor.contains("BEGIN PGP MESSAGE") else { return }
			self.uplinkPostQueue.async {
				let outcome = Self.postDirect(armor: armor, ip: entryIp)
				self.noteEntryOutcome(outcome, ip: entryIp, route: route)
			}
		}
	}

	private func stopLocked() {
		// Capture before tear-down: dialer Stop must free mailbox voice_listen
		// so the next redial can re-occupy the same sessionId (or a new one).
		let listenSessionId = active?.listenSessionId ?? ""
		running = false
		listenHandle?.cancel()
		listenHandle = nil
		listenEntryIp = nil
		listenStartedAt = nil
		active = nil
		resetMediaStateLocked()
		if listenSessionId.count >= 16 {
			postVoiceUnlistenLocked(sessionId: listenSessionId)
		}
		NSLog("[BeamioNativeVoiceChannel] stopped")
	}

	/// Best-effort `voice_unlisten` to own mailbox route (entry ≠ B). SI drops
	/// the session without EIP-191 when sessionId length ≥ 16.
	private func postVoiceUnlistenLocked(sessionId: String) {
		guard let secrets = BeamioChatPgpKeychain.load(),
		      secrets.routePublicKeyArmor.contains("BEGIN PGP PUBLIC KEY")
		else {
			NSLog("[BeamioNativeVoiceChannel] unlisten — missing own route PGP")
			return
		}
		let command: [String: Any] = [
			"command": "voice_unlisten",
			"sessionId": sessionId,
			"timestamp": Int(Date().timeIntervalSince1970),
		]
		guard let jsonData = try? JSONSerialization.data(withJSONObject: command, options: []),
		      let jsonUtf8 = String(data: jsonData, encoding: .utf8)
		else { return }
		let opaque = Data(jsonUtf8.utf8).base64EncodedString()
		let sem = DispatchSemaphore(value: 0)
		var armorOut: String?
		BeamioOpenPgpHost.shared.encrypt(
			plaintext: opaque,
			publicKeyArmor: secrets.routePublicKeyArmor
		) { result in
			armorOut = try? result.get()
			sem.signal()
		}
		_ = sem.wait(timeout: .now() + 8)
		guard let armor = armorOut, armor.contains("BEGIN PGP MESSAGE") else {
			NSLog("[BeamioNativeVoiceChannel] unlisten encrypt failed")
			return
		}
		let nodes = BeamioChatPgpKeychain.loadSiNodes()
		var exclude = Set<String>()
		if let mailbox = BeamioSiCipherPost.normalizeIp(secrets.mailboxIp) {
			exclude.insert(mailbox)
		}
		let posted = BeamioSiCipherPost.post(armor: armor, nodes: nodes, excludeIps: exclude, maxAttempts: 3, timeout: 8)
		NSLog(
			"[BeamioNativeVoiceChannel] voice_unlisten session=%@ ok=%@",
			sessionId,
			posted.ok ? "yes" : "no"
		)
	}

	// MARK: - voice_listen SSE

	private func startVoiceListenLocked(active: BeamioNativeVoiceSignaling.ActiveCall) {
		guard let secrets = BeamioChatPgpKeychain.load(),
		      secrets.routePublicKeyArmor.contains("BEGIN PGP PUBLIC KEY")
		else {
			NSLog("[BeamioNativeVoiceChannel] listen — missing own route PGP")
			return
		}
		var command: [String: Any] = [
			"command": "voice_listen",
			"sessionId": active.listenSessionId,
			"timestamp": Int(Date().timeIntervalSince1970),
		]
		// Dialer owns VoIP wake: mailbox notifies callee when offerArmor is present.
		if let wake = active.dialerWake,
		   wake.offerArmor.contains("BEGIN PGP MESSAGE"),
		   !wake.calleeEoa.isEmpty,
		   !wake.callId.isEmpty {
			command["callId"] = wake.callId
			command["targetWallet"] = wake.calleeEoa
			command["expiresAt"] = wake.expiresAt
			command["pushTimestamp"] = wake.pushTimestamp
			command["offerArmor"] = wake.offerArmor
		}
		guard let jsonData = try? JSONSerialization.data(withJSONObject: command, options: []),
		      let jsonUtf8 = String(data: jsonData, encoding: .utf8)
		else { return }
		let opaque = Data(jsonUtf8.utf8).base64EncodedString()

		// Index the offer on the callee mailbox ourselves, beside the listen
		// encrypt. The caller mailbox forwards the same armor too, but that leg
		// is best effort and missing on mailboxes that predate it. A killed app
		// reads the caller identity from this index, so without it the incoming
		// call has no name. The listen POST rings the callee, so it waits (capped)
		// for the index below.
		let offerIndexed = DispatchSemaphore(value: 0)
		if let wake = active.dialerWake,
		   wake.offerArmor.contains("BEGIN PGP MESSAGE"),
		   !wake.calleeEoa.isEmpty,
		   !wake.callId.isEmpty {
			let listenSession = active.listenSessionId
			DispatchQueue.global(qos: .userInitiated).async {
				Self.storeOfferOnCalleeMailbox(wake: wake, sessionId: listenSession)
				offerIndexed.signal()
			}
		} else {
			offerIndexed.signal()
		}

		let sem = DispatchSemaphore(value: 0)
		var armorOut: String?
		BeamioOpenPgpHost.shared.encrypt(
			plaintext: opaque,
			publicKeyArmor: secrets.routePublicKeyArmor
		) { result in
			armorOut = try? result.get()
			sem.signal()
		}
		_ = sem.wait(timeout: .now() + 12)
		guard let armor = armorOut, armor.contains("BEGIN PGP MESSAGE") else {
			NSLog("[BeamioNativeVoiceChannel] listen encrypt failed")
			return
		}

		let nodes = BeamioChatPgpKeychain.loadSiNodes()
		var exclude = Set<String>()
		if let mailbox = BeamioSiCipherPost.normalizeIp(secrets.mailboxIp) {
			exclude.insert(mailbox)
		}
		guard let entryIp = pickEntryIp(nodes: nodes, exclude: exclude) else {
			NSLog("[BeamioNativeVoiceChannel] listen — no reachable entry IP")
			return
		}
		guard let url = BeamioSiCipherPost.postUrl(for: entryIp) else { return }

		_ = offerIndexed.wait(timeout: .now() + 3)
		listenEntryIp = entryIp
		listenStartedAt = Date()
		NSLog(
			"[BeamioNativeVoiceChannel] voice_listen entry=%@ session=%@",
			entryIp,
			active.listenSessionId
		)
		// `postSse` scores the entry itself: open → reachable, HTTP error → reachable
		// but slow, connect failure → unreachable (kept out of `getRandomNode`).
		listenHandle = BeamioSiCipherPost.postSse(
			url: url,
			armor: armor,
			connectTimeout: 12,
			idleTimeout: 3600,
			onOpen: {
				NSLog("[BeamioNativeVoiceChannel] listen open entry=%@", entryIp)
			},
			onEvent: { [weak self] payload in
				self?.queue.async { self?.handleSsePayload(payload) }
			},
			onClosed: { reason in
				NSLog("[BeamioNativeVoiceChannel] listen closed entry=%@ reason=%@", entryIp, reason ?? "eof")
			}
		)
	}

	/// `voice_offer_store` to the callee mailbox: opaque command (the session id is
	/// the capability), encrypted to that mailbox's route key and posted through an
	/// entry that is not that mailbox. The mailbox never decrypts `offerArmor`; it
	/// is callee user-PGP ciphertext. Best effort, and storing twice is harmless.
	private static func storeOfferOnCalleeMailbox(
		wake: BeamioNativeVoiceSignaling.DialerWake,
		sessionId: String
	) {
		let callee = wake.calleeEoa.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard let keys = BeamioAddressPgp.searchKey(address: callee),
		      keys.routePublicKeyArmored.contains("BEGIN PGP PUBLIC KEY")
		else {
			NSLog("[BeamioNativeVoiceChannel] offer index — no callee route key")
			return
		}
		let command: [String: Any] = [
			"command": "voice_offer_store",
			"callId": wake.callId,
			"sessionId": sessionId,
			"offerArmor": wake.offerArmor,
			"expiresAt": wake.expiresAt,
			"timestamp": Int(Date().timeIntervalSince1970),
		]
		guard let json = try? JSONSerialization.data(withJSONObject: command, options: []) else { return }
		let sem = DispatchSemaphore(value: 0)
		var armorOut: String?
		BeamioOpenPgpHost.shared.encrypt(
			plaintext: json.base64EncodedString(),
			publicKeyArmor: keys.routePublicKeyArmored
		) { result in
			armorOut = try? result.get()
			sem.signal()
		}
		_ = sem.wait(timeout: .now() + 8)
		guard let armor = armorOut, armor.contains("BEGIN PGP MESSAGE") else {
			NSLog("[BeamioNativeVoiceChannel] offer index — encrypt failed")
			return
		}
		let nodes = BeamioChatPgpKeychain.loadSiNodes()
		var exclude = Set<String>()
		if let b = BeamioAddressPgp.mailboxIp(forRoutePgpKeyID: keys.routePgpKeyID, nodes: nodes) {
			exclude.insert(b)
		}
		if let own = BeamioSiCipherPost.normalizeIp(BeamioChatPgpKeychain.load()?.mailboxIp ?? "") {
			exclude.insert(own)
		}
		let posted = BeamioSiCipherPost.post(armor: armor, nodes: nodes, excludeIps: exclude, maxAttempts: 2, timeout: 6)
		NSLog(
			"[BeamioNativeVoiceChannel] offer index callId=%@ ok=%@",
			wake.callId,
			posted.ok ? "yes" : "no"
		)
	}

	private func pickEntryIp(nodes: [BeamioChatPgpKeychain.SiNode], exclude: Set<String>) -> String? {
		BeamioSiCipherPost.getRandomNode(nodes: nodes, excludeIps: exclude)?.ip
	}

	/// One SSE event. `postSse` already split the stream and joined the `data:` lines.
	private func handleSsePayload(_ payload: String) {
		guard !payload.isEmpty,
		      let jsonData = payload.data(using: .utf8),
		      let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
		else { return }
		if let kind = obj["kind"] as? String, kind == "udp" || obj["ok"] as? Bool == true {
			NSLog("[BeamioNativeVoiceChannel] listen handshake ok")
			return
		}
		if (obj["type"] as? String) == "voice_frame_v1" || obj["command"] as? String == "voice_uplink" {
			handleInboundFrame(obj)
		}
	}

	private func handleInboundFrame(_ frame: [String: Any]) {
		guard let active, running else { return }
		guard let payloadB64 = frame["payload"] as? String, !payloadB64.isEmpty else { return }
		do {
			let key = try BeamioVoiceAesGcm.keyFromBase64(active.offer.sessionKey)
			let plain = try BeamioVoiceAesGcm.decrypt(key: key, payloadBase64: payloadB64)
			if let json = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
			   let type = json["type"] as? String
			{
				NSLog("[BeamioNativeVoiceChannel] control frame type=%@ role=%@", type, active.role.rawValue)
				// Control frames share the media seq counter; mark the slot so the
				// jitter buffer does not wait on it.
				if active.mediaEnabled, let seq = Self.intValue(frame["seq"]) {
					enqueueRxMedia(seq: seq, plain: Data(), senderTs: 0, controlSlot: true)
				}
				if active.role == .dialer {
					if type == "voice_call_accept_v1" {
						let peerSession = (json["sessionId"] as? String)?
							.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
						BeamioNativeVoiceSignaling.dialerDidReceiveAccept(peerAcceptSessionId: peerSession)
						return
					}
					if type == "voice_call_reject_v1" || type == "voice_call_timeout_v1" {
						let action = type == "voice_call_timeout_v1" ? "callTimedOut" : "callRejected"
						BeamioNativeVoiceSignaling.dialerDidReceiveReject(action: action)
						return
					}
				}
				if type == "voice_video_enable_v1" {
					let cb = onPeerVideoEnabled
					DispatchQueue.main.async { cb?(true) }
					return
				}
				if type == "voice_video_disable_v1" {
					let cb = onPeerVideoEnabled
					DispatchQueue.main.async { cb?(false) }
					return
				}
				if type == "voice_end_v1" || type == "voice_call_reject_v1" {
					// Browser Hang Up often arrives on the AES relay first. Closing
					// media alone left CallKit/InCall up (v71). Route through the
					// same end() path as chat voice_end so the shell call screen
					// dismisses.
					let endCallId = active.offer.callId
					let endSessionId = active.offer.sessionId
					DispatchQueue.main.async {
						BeamioNativeVoiceSignaling.applyRemoteMediaEnd(
							callId: endCallId,
							sessionId: endSessionId
						)
						self.stop()
					}
				}
				return
			}
			guard active.mediaEnabled else { return }
			let senderTs: Int64 = {
				if let n = frame["frameTimestamp"] as? Int64 { return n }
				if let n = frame["frameTimestamp"] as? Int { return Int64(n) }
				if let n = frame["frameTimestamp"] as? Double { return Int64(n) }
				return 0
			}()
			enqueueRxMedia(seq: Self.intValue(frame["seq"]), plain: plain, senderTs: senderTs)
		} catch {
			NSLog("[BeamioNativeVoiceChannel] decrypt fail %@", error.localizedDescription)
		}
	}

	/// Playout jitter: buffer late/OOO seq for ~120ms, then contiguous play; timeout → skip gap.
	private func enqueueRxMedia(seq: Int?, plain: Data, senderTs: Int64, controlSlot: Bool = false) {
		guard let seq, seq >= 0 else {
			if !controlSlot { deliverRxPlainImmediate(plain, senderTs: senderTs) }
			return
		}
		if let next = rxNextSeq, seq < next { return }
		if rxPendingPcm[seq] != nil || rxPendingJpeg[seq] != nil { return }

		if controlSlot {
			// Empty PCM placeholder: drained as a no-op.
			rxPendingPcm[seq] = Data()
		} else if let jpegImage = Self.decodeWireJpeg(plain) {
			rxPendingJpeg[seq] = (jpegImage, senderTs)
		} else if let pcm = Self.decodeWirePcm(plain) {
			rxPendingPcm[seq] = pcm
		} else {
			NSLog("[BeamioNativeVoiceChannel] media frame invalid bytes=%d", plain.count)
			return
		}

		if rxNextSeq == nil {
			rxNextSeq = seq
		}

		if rxPendingPcm.count + rxPendingJpeg.count > Self.rxMaxPendingFrames {
			skipRxGapLocked(reason: "overflow")
			return
		}

		drainRxLocked()
		scheduleRxJitterIfNeeded()
	}

	private func deliverRxPlainImmediate(_ plain: Data, senderTs: Int64) {
		if let jpegImage = Self.decodeWireJpeg(plain) {
			scheduleVideoFrame(jpegImage, senderTs: senderTs)
			return
		}
		guard let pcm = Self.decodeWirePcm(plain) else {
			NSLog("[BeamioNativeVoiceChannel] media frame invalid bytes=%d", plain.count)
			return
		}
		playPcm(pcm)
	}

	private func drainRxLocked() {
		guard var next = rxNextSeq else { return }
		while true {
			if let pcm = rxPendingPcm.removeValue(forKey: next) {
				playPcm(pcm)
				next += 1
				continue
			}
			if let jpeg = rxPendingJpeg.removeValue(forKey: next) {
				scheduleVideoFrame(jpeg.image, senderTs: jpeg.senderTs)
				next += 1
				continue
			}
			break
		}
		rxNextSeq = next
		if rxPendingPcm.isEmpty && rxPendingJpeg.isEmpty {
			rxJitterWorkItem?.cancel()
			rxJitterWorkItem = nil
		}
	}

	private func scheduleRxJitterIfNeeded() {
		guard let next = rxNextSeq else { return }
		let hasLater =
			rxPendingPcm.keys.contains(where: { $0 > next })
			|| rxPendingJpeg.keys.contains(where: { $0 > next })
		guard hasLater else { return }
		guard rxJitterWorkItem == nil else { return }
		let work = DispatchWorkItem { [weak self] in
			guard let self else { return }
			self.queue.async {
				self.rxJitterWorkItem = nil
				self.skipRxGapLocked(reason: "timeout")
			}
		}
		rxJitterWorkItem = work
		queue.asyncAfter(deadline: .now() + Self.rxJitterSeconds, execute: work)
	}

	private func skipRxGapLocked(reason: String) {
		guard let next = rxNextSeq else { return }
		let later = Set(rxPendingPcm.keys).union(rxPendingJpeg.keys).filter { $0 > next }
		guard let minKey = later.min() else { return }
		NSLog(
			"[BeamioNativeVoiceChannel] rx jitter skip %d..<%d reason=%@",
			next,
			minKey,
			reason
		)
		rxJitterWorkItem?.cancel()
		rxJitterWorkItem = nil
		// Fill lost audio with short silence so the timeline is not compressed;
		// the next real frame fades in.
		for _ in 0 ..< min(minKey - next, Self.maxConcealFrames) {
			playPcm(Data(count: Self.frameSamples * MemoryLayout<Int16>.size))
		}
		playFadeNext = true
		rxNextSeq = minKey
		drainRxLocked()
		scheduleRxJitterIfNeeded()
	}

	/// Frames arrive in bursts over the relay. Show each at its sender time plus
	/// a fixed delay over the best observed transit, keeping the sender's cadence.
	/// Out-of-order and duplicate frames are dropped. Runs on `queue`.
	private func scheduleVideoFrame(_ image: UIImage, senderTs: Int64) {
		let cb = onRemoteVideoFrame
		let enabledCb = onPeerVideoEnabled
		let show = {
			enabledCb?(true)
			cb?(image)
		}
		guard senderTs > 0 else {
			DispatchQueue.main.async(execute: show)
			return
		}
		guard senderTs > videoLastSenderTs else { return }
		videoLastSenderTs = senderTs
		let now = Int64(Date().timeIntervalSince1970 * 1000)
		let delta = now - senderTs
		// Track the fastest transit; relax slowly so a slower path is adopted.
		let minDelta = videoMinDeltaMs.map { min(delta, $0 + 2) } ?? delta
		videoMinDeltaMs = minDelta
		let waitMs = max(0, senderTs + minDelta + Self.videoPlayoutDelayMs - now)
		DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(waitMs)), execute: show)
	}

	/// `BJPG` + w + h + frameId + JPEG → UIImage.
	private static func decodeWireJpeg(_ plain: Data) -> UIImage? {
		let bytes = [UInt8](plain)
		guard bytes.count >= 12, Array(bytes[0 ..< 4]) == jpgMagic else { return nil }
		let jpeg = Data(bytes[12...])
		guard !jpeg.isEmpty else { return nil }
		return UIImage(data: jpeg)
	}

	private static func intValue(_ any: Any?) -> Int? {
		if let n = any as? Int { return n }
		if let n = any as? NSNumber { return n.intValue }
		if let s = any as? String { return Int(s) }
		return nil
	}

	/// `BPCM` + rate + int16 PCM -> 16 kHz mono int16 bytes. A frame without the
	/// header is treated as raw 16 kHz PCM (older native peer).
	private static func decodeWirePcm(_ plain: Data) -> Data? {
		let bytes = [UInt8](plain)
		if bytes.count >= 10, Array(bytes[0 ..< 4]) == pcmMagic {
			let rate = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
			guard (8_000 ... 48_000).contains(rate) else { return nil }
			let count = (bytes.count - 8) >> 1
			guard count > 0 else { return nil }
			if rate == wireRate {
				return Data(bytes[8 ..< 8 + count * 2])
			}
			var src = [Int16](repeating: 0, count: count)
			for i in 0 ..< count {
				src[i] = Int16(bitPattern: UInt16(bytes[8 + 2 * i]) | UInt16(bytes[9 + 2 * i]) << 8)
			}
			let outCount = max(1, count * wireRate / rate)
			var out = [Int16](repeating: 0, count: outCount)
			for i in 0 ..< outCount {
				let pos = Double(i) * Double(rate) / Double(wireRate)
				let i0 = min(Int(pos), count - 1)
				let i1 = min(i0 + 1, count - 1)
				let f = pos - Double(i0)
				out[i] = Int16(clamping: Int((Double(src[i0]) * (1 - f) + Double(src[i1]) * f).rounded()))
			}
			return out.withUnsafeBufferPointer { Data(buffer: $0) }
		}
		if bytes.count >= 2, bytes.count % 2 == 0 { return plain }
		return nil
	}

	// MARK: - Audio

	private func startAudioEngine(active: BeamioNativeVoiceSignaling.ActiveCall) {
		stopAudioEngine()
		guard active.mediaEnabled else { return }
		let engine = AVAudioEngine()
		let player = AVAudioPlayerNode()
		engine.attach(player)
		let input = engine.inputNode
		// Apple voice processing (VPIO): acoustic echo cancellation, noise
		// suppression and AGC. AVAudioEngine's input bypasses it unless enabled,
		// so the far end heard its own voice back from our speaker. Must be set
		// before the input format is read (it changes the format).
		do {
			try input.setVoiceProcessingEnabled(true)
			input.isVoiceProcessingAGCEnabled = true
			NSLog("[BeamioNativeVoiceChannel] voice processing (AEC) on")
		} catch {
			NSLog("[BeamioNativeVoiceChannel] voice processing unavailable %@", error.localizedDescription)
		}
		let inFormat = input.outputFormat(forBus: 0)
		guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
			NSLog("[BeamioNativeVoiceChannel] input format unavailable")
			return
		}
		let target = AVAudioFormat(
			commonFormat: .pcmFormatInt16,
			sampleRate: 16_000,
			channels: 1,
			interleaved: true
		)!
		// Standard Float32 for playback: with voice processing on, an Int16 player
		// connection played silently. Mixer → output uses the output's own format.
		engine.connect(player, to: engine.mainMixerNode, format: Self.playbackFormat)
		engine.connect(
			engine.mainMixerNode,
			to: engine.outputNode,
			format: engine.outputNode.inputFormat(forBus: 0)
		)
		installMicTap(on: engine, target: target, active: active)
		do {
			try engine.start()
			player.play()
		} catch {
			NSLog("[BeamioNativeVoiceChannel] engine start failed %@", error.localizedDescription)
			engine.inputNode.removeTap(onBus: 0)
			return
		}
		self.engine = engine
		self.playerNode = player
		engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2_048, format: nil) { [weak self] buffer, _ in
			guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
			var sum: Float = 0
			for i in 0 ..< Int(buffer.frameLength) { sum += data[i] * data[i] }
			self?.mixerRms = (sum / Float(buffer.frameLength)).squareRoot()
		}
		startDiagnostics()
		// Voice processing and route changes (speaker / receiver / headset) stop
		// the engine and post this notification. Recover the same engine in place:
		// rebuilding it would re-enable voice processing and stop it again.
		engineConfigObserver = NotificationCenter.default.addObserver(
			forName: .AVAudioEngineConfigurationChange,
			object: engine,
			queue: .main
		) { [weak self] _ in
			guard let self, self.engine === engine, let player = self.playerNode else { return }
			NSLog("[BeamioNativeVoiceChannel] engine configuration changed; restarting in place")
			self.queue.async {
				// Scheduled buffers are gone with the stopped player: rebuffer.
				self.rxBacklogSamples = 0
				self.playPrebuffering = true
				self.playPending.removeAll()
				self.playPendingSamples = 0
				self.playFadeNext = true
			}
			self.installMicTap(on: engine, target: target, active: active)
			self.restartEngine(engine, player: player, attempt: 1)
		}
		NSLog("[BeamioNativeVoiceChannel] audio engine started 16k mono")
	}

	/// (Re)install the mic tap with the input's current format (it changes when
	/// voice processing turns on or the route changes).
	private func installMicTap(on engine: AVAudioEngine, target: AVAudioFormat, active: BeamioNativeVoiceSignaling.ActiveCall) {
		let input = engine.inputNode
		input.removeTap(onBus: 0)
		let inFormat = input.outputFormat(forBus: 0)
		guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
			NSLog("[BeamioNativeVoiceChannel] input format unavailable")
			return
		}
		input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
			self?.queue.async {
				self?.uplinkPcmBuffer(buffer, inFormat: inFormat, target: target, active: active)
			}
		}
		NSLog(
			"[BeamioNativeVoiceChannel] mic tap %.0f Hz ch=%d",
			inFormat.sampleRate,
			Int(inFormat.channelCount)
		)
	}

	private func restartEngine(_ engine: AVAudioEngine, player: AVAudioPlayerNode, attempt: Int) {
		guard self.engine === engine else { return }
		do {
			// A configuration change can switch the output hardware format. The
			// old mixer → output connection then renders nothing: the player
			// reports playing while no scheduled buffer ever completes. Reconnect
			// with the current output format before starting again.
			if engine.isRunning { engine.stop() }
			player.stop()
			engine.connect(player, to: engine.mainMixerNode, format: Self.playbackFormat)
			engine.connect(
				engine.mainMixerNode,
				to: engine.outputNode,
				format: engine.outputNode.inputFormat(forBus: 0)
			)
			try engine.start()
			player.play()
			NSLog("[BeamioNativeVoiceChannel] engine restarted attempt=%d", attempt)
		} catch {
			NSLog("[BeamioNativeVoiceChannel] engine restart failed attempt=%d %@", attempt, error.localizedDescription)
			guard attempt < 3 else { return }
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
				self?.restartEngine(engine, player: player, attempt: attempt + 1)
			}
		}
	}

	/// Every 2 s: engine / player state, playout backlog, output route and the
	/// level actually reaching the mixer output.
	private var lastDiagBacklogMs = -1
	private var stalledDiagTicks = 0

	private func startDiagnostics() {
		diagTimer?.cancel()
		let timer = DispatchSource.makeTimerSource(queue: queue)
		timer.schedule(deadline: .now() + 2, repeating: 2)
		timer.setEventHandler { [weak self] in
			guard let self else { return }
			let backlogMs = self.rxBacklogSamples * 1000 / Self.wireRate
			let prebuffering = self.playPrebuffering
			// Playout stall: buffers are scheduled but none completes. Recover
			// by rebuilding the graph connections and restarting in place.
			if backlogMs > 0, !prebuffering, backlogMs == self.lastDiagBacklogMs {
				self.stalledDiagTicks += 1
			} else {
				self.stalledDiagTicks = 0
			}
			self.lastDiagBacklogMs = backlogMs
			if self.stalledDiagTicks >= 3 {
				self.stalledDiagTicks = 0
				self.rxBacklogSamples = 0
				self.playPrebuffering = true
				self.playPending.removeAll()
				self.playPendingSamples = 0
				self.playFadeNext = true
				DispatchQueue.main.async {
					guard let engine = self.engine, let player = self.playerNode else { return }
					NSLog("[BeamioNativeVoiceChannel] playout stalled at %dms; reconnecting engine", backlogMs)
					self.restartEngine(engine, player: player, attempt: 1)
				}
			}
			DispatchQueue.main.async {
				let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
					.map { $0.portType.rawValue }.joined(separator: ",")
				NSLog(
					"[BeamioNativeVoiceChannel] diag engine=%@ player=%@ backlogMs=%d prebuffer=%@ mixerRms=%.4f out=%@ vol=%.2f",
					self.engine?.isRunning == true ? "run" : "stop",
					self.playerNode?.isPlaying == true ? "play" : "idle",
					backlogMs,
					prebuffering ? "yes" : "no",
					self.mixerRms,
					outputs,
					self.engine?.mainMixerNode.outputVolume ?? -1
				)
			}
		}
		timer.resume()
		diagTimer = timer
	}

	private func stopAudioEngine() {
		diagTimer?.cancel()
		diagTimer = nil
		engine?.mainMixerNode.removeTap(onBus: 0)
		if let observer = engineConfigObserver {
			NotificationCenter.default.removeObserver(observer)
			engineConfigObserver = nil
		}
		engine?.inputNode.removeTap(onBus: 0)
		playerNode?.stop()
		engine?.stop()
		engine = nil
		playerNode = nil
		converter = nil
	}

	private func uplinkPcmBuffer(
		_ buffer: AVAudioPCMBuffer,
		inFormat: AVAudioFormat,
		target: AVAudioFormat,
		active: BeamioNativeVoiceSignaling.ActiveCall
	) {
		guard running else { return }
		guard let live = self.active, live.mediaEnabled else { return }
		guard let converted = convert(buffer: buffer, from: inFormat, to: target) else { return }
		let byteCount = Int(converted.frameLength) * MemoryLayout<Int16>.size
		guard byteCount > 0, let ptr = converted.int16ChannelData?[0] else { return }
		if isMuted {
			// Nothing leaves the device while muted, and no stale audio is kept.
			uplinkAccum = Data()
			return
		}
		let data = Data(bytes: ptr, count: byteCount)
		// Adaptive packetization (any length decodes on every peer): send 160 ms
		// packets while a send slot is free; when all slots are busy keep the audio
		// and send it with the next packet (up to ~250 ms) instead of dropping it.
		guard live.mediaEnabled, !live.peerMediaSessionId.isEmpty else {
			uplinkAccum = Data()
			return
		}
		uplinkAccum.append(data)
		let frameBytes = Self.frameSamples * MemoryLayout<Int16>.size
		if uplinkAccum.count >= frameBytes, uplinkSlotAvailable(active: live) {
			let whole = (uplinkAccum.count / frameBytes) * frameBytes
			let take = min(whole, Self.maxPacketBytes)
			let packet = Data(uplinkAccum.prefix(take))
			uplinkAccum = Data(uplinkAccum.dropFirst(take))
			sendUplinkFrame(packet, active: live)
		}
		// Never keep more than one second of unsent audio: drop the oldest.
		let cap = Self.wireRate * MemoryLayout<Int16>.size
		if uplinkAccum.count > cap {
			uplinkAccum = Data(uplinkAccum.suffix(cap))
		}
	}

	/// A packet can go out now: route resolved and fewer than the max in flight.
	private func uplinkSlotAvailable(active: BeamioNativeVoiceSignaling.ActiveCall) -> Bool {
		guard uplinkRoute != nil else {
			let peer = active.peerEoa.lowercased()
			if peer.hasPrefix("0x"), peer.count == 42 {
				resolveUplinkRouteIfNeeded(peer: peer, callId: active.offer.callId)
			}
			return false
		}
		return uplinkInFlight < Self.maxUplinkInFlight
	}

	private func convert(buffer: AVAudioPCMBuffer, from: AVAudioFormat, to: AVAudioFormat) -> AVAudioPCMBuffer? {
		if from.sampleRate == to.sampleRate, from.commonFormat == to.commonFormat, from.channelCount == to.channelCount {
			return buffer
		}
		if converter == nil || converter?.inputFormat != from {
			converter = AVAudioConverter(from: from, to: to)
		}
		guard let converter else { return nil }
		let ratio = to.sampleRate / from.sampleRate
		let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
		guard let out = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: outFrames) else { return nil }
		var error: NSError?
		var consumed = false
		let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
			// Hand the buffer over once; a second `.haveData` would convert it twice.
			if consumed {
				outStatus.pointee = .noDataNow
				return nil
			}
			consumed = true
			outStatus.pointee = .haveData
			return buffer
		}
		converter.convert(to: out, error: &error, withInputFrom: inputBlock)
		if error != nil { return nil }
		return out
	}

	/// Peer route key and one reachable entry. Resolved once per call: the key
	/// lookup is a chain read and the entry pick probes over the network, so
	/// neither may sit on the per-frame path.
	private func resolveUplinkRouteIfNeeded(peer: String, callId: String) {
		guard !uplinkRouteResolving else { return }
		uplinkRouteResolving = true
		uplinkPostQueue.async { [weak self] in
			var resolved: UplinkRoute?
			if let keys = BeamioAddressPgp.searchKey(address: peer),
			   keys.routePublicKeyArmored.contains("BEGIN PGP PUBLIC KEY")
			{
				let nodes = BeamioChatPgpKeychain.loadSiNodes()
				var exclude = Set<String>()
				if let b = BeamioAddressPgp.mailboxIp(forRoutePgpKeyID: keys.routePgpKeyID, nodes: nodes) {
					exclude.insert(b)
				}
				if let mailbox = BeamioSiCipherPost.normalizeIp(BeamioChatPgpKeychain.load()?.mailboxIp ?? "") {
					exclude.insert(mailbox)
				}
				if let node = BeamioSiCipherPost.getRandomNode(nodes: nodes, excludeIps: exclude) {
					resolved = UplinkRoute(
						routePublicKeyArmor: keys.routePublicKeyArmored,
						nodes: nodes,
						exclude: exclude,
						entries: BeamioEntryRotation(first: node.ip)
					)
				}
			}
			if let resolved { self?.refillEntries(resolved) }
			self?.queue.async {
				guard let self, self.running, self.active?.offer.callId == callId else { return }
				self.uplinkRoute = resolved
				self.uplinkRouteResolving = false
				NSLog(
					"[BeamioNativeVoiceChannel] uplink route ready=%@ pool=%d",
					resolved == nil ? "no" : "yes",
					resolved?.entries.size ?? 0
				)
			}
		}
	}

	/// Only an unreachable entry (status 0) leaves the pool; an application
	/// error such as a closed peer session says nothing about the entry.
	private func noteEntryOutcome(
		_ outcome: (ok: Bool, status: Int, ms: Int, note: String),
		ip: String,
		route: UplinkRoute
	) {
		if !outcome.ok, outcome.status == 0 {
			route.entries.markFailed(ip)
		} else if outcome.ok, route.entries.recordLatency(ip, ms: outcome.ms) {
			NSLog("[BeamioNativeVoiceChannel] uplink entry %@ slow — dropped from pool", ip)
		}
		if route.entries.size < BeamioEntryRotation.poolMin {
			refillEntries(route)
		}
	}

	/// Probe more entries on the post queue until the pool reaches its target.
	private func refillEntries(_ route: UplinkRoute) {
		guard route.entries.size < BeamioEntryRotation.poolTarget, route.entries.beginRefill() else { return }
		uplinkPostQueue.async {
			defer { route.entries.endRefill() }
			var attempts = 0
			while route.entries.size < BeamioEntryRotation.poolTarget,
			      attempts < BeamioEntryRotation.poolTarget * 2
			{
				attempts += 1
				guard let node = BeamioSiCipherPost.getRandomNode(
					nodes: route.nodes,
					excludeIps: route.exclude.union(route.entries.known())
				) else { break }
				route.entries.add(node.ip)
			}
			NSLog("[BeamioNativeVoiceChannel] uplink entry pool size=%d", route.entries.size)
		}
	}

	/// One direct `POST /post` to an already chosen entry. No probe, no retry:
	/// a late voice frame is useless, so a failure just drops the frame.
	private static func postDirect(armor: String, ip: String) -> (ok: Bool, status: Int, ms: Int, note: String) {
		guard let body = try? JSONSerialization.data(withJSONObject: ["data": armor]) else {
			return (false, 0, 0, "encode")
		}
		let r = BeamioSiCipherPost.httpRequest(
			ip: ip,
			method: "POST",
			path: "/post",
			body: body,
			timeout: 6,
			stopAfterStatusLine: false
		)
		var ok = (200 ..< 300).contains(r.status)
		var note = r.error
		if ok, let data = r.body.data(using: .utf8),
		   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		{
			if let flag = obj["ok"] as? Bool { ok = flag }
			if !ok { note = (obj["error"] as? String) ?? "ok_false" }
		}
		return (ok, r.status, r.ms, note)
	}

	private func finishUplink(_ outcome: (ok: Bool, status: Int, ms: Int, note: String), ip: String) {
		if outcome.ok {
			uplinkFailStreak = 0
			return
		}
		uplinkFailStreak += 1
		uplinkLogged += 1
		if uplinkLogged <= 3 || uplinkLogged % 50 == 0 {
			NSLog(
				"[BeamioNativeVoiceChannel] uplink frame failed ip=%@ status=%d ms=%d note=%@ streak=%d",
				ip,
				outcome.status,
				outcome.ms,
				outcome.note,
				uplinkFailStreak
			)
		}
		// A dead entry is scored out and replaced; an application error is not.
		if outcome.status == 0 {
			BeamioSiCipherPost.scoreEntry(ip: ip, reachable: false, latencyMs: outcome.ms)
		}
		if uplinkFailStreak >= 3 {
			uplinkFailStreak = 0
			uplinkRoute = nil
		}
	}

	private func sendUplinkFrame(_ pcm: Data, active: BeamioNativeVoiceSignaling.ActiveCall) {
		guard running, !pcm.isEmpty, active.mediaEnabled else { return }
		guard !active.peerMediaSessionId.isEmpty else { return }
		let peer = active.peerEoa.lowercased()
		guard peer.hasPrefix("0x"), peer.count == 42 else { return }
		guard let route = uplinkRoute else {
			resolveUplinkRouteIfNeeded(peer: peer, callId: active.offer.callId)
			return
		}
		if uplinkInFlight >= Self.maxUplinkInFlight { return }
		let seq = takeUplinkSeq()
		var framed = Data(Self.pcmMagic)
		var rate = UInt32(Self.wireRate).littleEndian
		withUnsafeBytes(of: &rate) { framed.append(contentsOf: $0) }
		framed.append(pcm)
		let payload: String
		do {
			let key = try BeamioVoiceAesGcm.keyFromBase64(active.offer.sessionKey)
			payload = try BeamioVoiceAesGcm.encrypt(key: key, plain: framed)
		} catch {
			return
		}
		let nowMs = Int(Date().timeIntervalSince1970 * 1000)
		let localEoa = active.localEoa
		let uplink: [String: Any] = [
			// Route command read by the peer's mailbox: no wallet fields.
			"command": "voice_uplink",
			"type": "voice_frame_v1",
			"callId": active.offer.callId,
			"sessionId": active.listenSessionId,
			"targetSessionId": active.peerMediaSessionId,
			"direction": "uplink",
			"seq": seq,
			"frameTimestamp": nowMs,
			"payload": payload,
			"timestamp": Int(Date().timeIntervalSince1970),
		]
		guard let jsonData = try? JSONSerialization.data(withJSONObject: uplink, options: []),
		      let jsonUtf8 = String(data: jsonData, encoding: .utf8)
		else { return }
		let opaque = Data(jsonUtf8.utf8).base64EncodedString()
		guard let entryIp = route.entries.next() else { return }
		uplinkInFlight += 1
		BeamioOpenPgpHost.shared.encrypt(
			plaintext: opaque,
			publicKeyArmor: route.routePublicKeyArmor
		) { [weak self] result in
			guard let self else { return }
			guard let armor = try? result.get(), armor.contains("BEGIN PGP MESSAGE") else {
				self.queue.async { self.uplinkInFlight = max(0, self.uplinkInFlight - 1) }
				return
			}
			// Network I/O is blocking; keep it off the OpenPGP callback thread.
			self.uplinkPostQueue.async {
				let outcome = Self.postDirect(armor: armor, ip: entryIp)
				self.noteEntryOutcome(outcome, ip: entryIp, route: route)
				self.queue.async {
					self.uplinkInFlight = max(0, self.uplinkInFlight - 1)
					self.finishUplink(outcome, ip: entryIp)
				}
			}
		}
	}

	/// Industry-style playout buffer: hold `playoutTargetSamples` before the first
	/// frame plays and again after every underrun; cap latency with
	/// `maxPlayBacklogSamples`. Runs on `queue`.
	private func playPcm(_ pcm: Data) {
		guard !pcm.isEmpty else { return }
		let frames = pcm.count / MemoryLayout<Int16>.size
		guard frames > 0 else { return }
		if playPrebuffering {
			playPending.append(pcm)
			playPendingSamples += frames
			guard playPendingSamples >= Self.playoutTargetSamples else { return }
			playPrebuffering = false
			NSLog("[BeamioNativeVoiceChannel] playout start depthMs=%d", playPendingSamples * 1000 / Self.wireRate)
			let pending = playPending
			playPending.removeAll()
			playPendingSamples = 0
			for chunk in pending { schedulePcm(chunk) }
			return
		}
		// Latency cap: the player is well behind, drop this frame.
		if rxBacklogSamples > Self.maxPlayBacklogSamples {
			playFadeNext = true
			return
		}
		schedulePcm(pcm)
	}

	/// 16 kHz mono Float32 (standard, non-interleaved) — the player's format.
	private static let playbackFormat = AVAudioFormat(
		commonFormat: .pcmFormatFloat32,
		sampleRate: 16_000,
		channels: 1,
		interleaved: false
	)!

	private func schedulePcm(_ pcm: Data) {
		guard let playerNode, let engine, engine.isRunning else { return }
		let frames = AVAudioFrameCount(pcm.count / MemoryLayout<Int16>.size)
		guard frames > 0,
		      let buffer = AVAudioPCMBuffer(pcmFormat: Self.playbackFormat, frameCapacity: frames)
		else { return }
		buffer.frameLength = frames
		let fade = playFadeNext
		playFadeNext = false
		pcm.withUnsafeBytes { raw in
			guard let src = raw.bindMemory(to: Int16.self).baseAddress,
			      let dst = buffer.floatChannelData?[0]
			else { return }
			let n = Int(frames)
			let fadeCount = fade ? min(Self.fadeSamples, n) : 0
			for i in 0 ..< n {
				var v = Float(src[i]) / 32_768
				if i < fadeCount { v *= Float(i) / Float(fadeCount) }
				dst[i] = v
			}
		}
		rxBacklogSamples += Int(frames)
		let queued = Int(frames)
		// scheduleBuffer is thread-safe: schedule from this queue so playback keeps
		// going when the main thread is busy (camera start, UI work).
		playerNode.scheduleBuffer(buffer) { [weak self] in
			self?.queue.async {
				guard let self else { return }
				self.rxBacklogSamples = max(0, self.rxBacklogSamples - queued)
				// Everything scheduled has played: underrun. Rebuffer before resuming.
				if self.rxBacklogSamples == 0, !self.playPrebuffering {
					self.playPrebuffering = true
					self.playFadeNext = true
				}
			}
		}
	}
}


/// Probed, reachable entries for one call. `next()` returns a random entry
/// that differs from the previous pick, without probing (a per-frame probe
/// made frames late). Unreachable entries cool down before they can return.
final class BeamioEntryRotation {
	static let poolTarget = 6
	static let poolMin = 3
	private static let failedCooldown: TimeInterval = 60

	private let lock = NSLock()
	private var healthy: [String]
	private var failedUntil: [String: Date] = [:]
	private var last: String?
	private var refilling = false

	init(first: String) {
		healthy = [first]
	}

	var size: Int {
		lock.lock(); defer { lock.unlock() }
		return healthy.count
	}

	func next() -> String? {
		lock.lock(); defer { lock.unlock() }
		guard !healthy.isEmpty else { return nil }
		let choices = healthy.count > 1 ? healthy.filter { $0 != last } : healthy
		let pick = choices.randomElement()
		last = pick
		return pick
	}

	func add(_ ip: String) {
		lock.lock(); defer { lock.unlock() }
		if let until = failedUntil[ip], until > Date() { return }
		if !healthy.contains(ip) { healthy.append(ip) }
	}

	func markFailed(_ ip: String) {
		lock.lock(); defer { lock.unlock() }
		dropLocked(ip)
	}

	/// An entry whose average post time exceeds this leaves the pool.
	private static let slowMs: Double = 600
	private static let slowMinSamples = 3
	private var latencyEwma: [String: Double] = [:]
	private var samples: [String: Int] = [:]

	/// Record one post time. A slow entry makes its frames late and drains the
	/// peer's playout buffer, so it leaves the pool. Returns true when dropped.
	func recordLatency(_ ip: String, ms: Int) -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard healthy.contains(ip) else { return false }
		let next = latencyEwma[ip].map { $0 * 0.7 + Double(ms) * 0.3 } ?? Double(ms)
		latencyEwma[ip] = next
		let n = (samples[ip] ?? 0) + 1
		samples[ip] = n
		if n >= Self.slowMinSamples, next > Self.slowMs, healthy.count > 1 {
			dropLocked(ip)
			return true
		}
		return false
	}

	private func dropLocked(_ ip: String) {
		healthy.removeAll { $0 == ip }
		latencyEwma[ip] = nil
		samples[ip] = nil
		failedUntil[ip] = Date().addingTimeInterval(Self.failedCooldown)
	}

	/// Entries to skip when probing for more: in the pool or cooling down.
	func known() -> Set<String> {
		lock.lock(); defer { lock.unlock() }
		let now = Date()
		return Set(healthy).union(failedUntil.filter { $0.value > now }.keys)
	}

	func beginRefill() -> Bool {
		lock.lock(); defer { lock.unlock() }
		if refilling { return false }
		refilling = true
		return true
	}

	func endRefill() {
		lock.lock(); defer { lock.unlock() }
		refilling = false
	}
}
