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
	/// FaceTime JPEG v2: `BJP2` + u16-LE width + u16-LE height + u32-LE frameId
	/// + u64-LE capture time (Unix ms) + JPEG bytes. The relay drops every
	/// outer field except seq/timestamp/payload, so the capture time rides
	/// inside the encrypted payload.
	private static let jp2Magic: [UInt8] = [0x42, 0x4A, 0x50, 0x32]
	/// Media capabilities this build announces in `voice_media_caps_v1`.
	/// video 2 = video uses its own seq range (`videoSeqBase`) and `BJP2`.
	private static let localVideoCaps = 2
	/// Split-seq video frames use seq ≥ this. Audio and controls count up from 1,
	/// so the ranges never meet; a lost or late video frame no longer stalls audio.
	static let videoSeqBase = 1_000_000_000
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
	private var videoUplinkInFlight = 0
	private var videoFrameId: UInt32 = 0
	/// Peer's announced video capability (0 until `voice_media_caps_v1` arrives).
	private var peerVideoCaps = 0
	private var capsSent = 0
	/// Next split-seq video number (offset from `videoSeqBase`).
	private var videoSeqOffset = 0
	/// Capture time of the newest remote frame shown (main thread).
	private var videoShownCaptureMs: Int64 = 0
	let stats = BeamioVideoStats()
	/// QA switch for before/after runs: launch with `-beamioVideoLegacy YES` to
	/// get the previous behaviour (no caps, shared-seq BJPG, shared OpenPGP host)
	/// while `[VideoStats]` still logs. Read once per call.
	private var legacyMode = false
	private var statsLastFlush = Date()
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
	/// Adaptive playout depth (industry-style adaptive jitter buffer). Starts at
	/// 320 ms; every underrun adds 160 ms up to 800 ms; 10 s without an underrun
	/// takes 80 ms back. Frames now reach us through a different random entry
	/// each time, so arrival spread can exceed a fixed 320 ms.
	private static let playoutMinSamples = 5_120
	private static let playoutMaxSamples = 12_800
	private static let playoutStepUpSamples = 2_560
	private static let playoutStepDownSamples = 1_280
	private static let playoutDecayInterval: TimeInterval = 10
	private var playoutTargetSamples = 5_120
	private var lastUnderrunAt = Date.distantPast
	private var lastDecayAt = Date()
	/// Reorder wait follows the playout depth.
	private var rxJitterWait: TimeInterval { Double(playoutTargetSamples) / Double(Self.wireRate) }
	/// Latency cap stays 400 ms above the current depth.
	private var maxPlayBacklog: Int { playoutTargetSamples + 6_400 }
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

	// MARK: Link health (in-call reconnect / connection lost)
	// The media SSE can drop mid-call (entry restart, network switch, suspend).
	// Once media runs, a 1 s watchdog reopens `voice_listen` on the same
	// sessionId through a new random entry (backoff 1/2/4/8 s; voice_unlisten
	// first when the node still holds the old socket). Nothing but the session
	// capability goes out: no wallet, no signature, no wake fields (no re-ring).
	// No peer frame AND no accepted uplink for `linkLostLimit` ends the call.
	static let rxStaleReconnect: TimeInterval = 8
	static let mediaStartGrace: TimeInterval = 12
	static let linkLostLimit: TimeInterval = 25
	private static let mutedKeepaliveInterval: TimeInterval = 1
	private let reconnectQueue = DispatchQueue(label: "com.beamio.nativeVoiceChannel.reconnect", qos: .userInitiated)
	private var linkTimer: DispatchSourceTimer?
	private var mediaStartedAt = Date()
	private var lastRxAt = Date()
	private var lastTxOkAt = Date()
	private var listenGen = 0
	private var listenAlive = false
	private var listenReady = false
	private var reconnecting = false
	private var reconnectAttempt = 0
	private var nextReconnectAt = Date.distantPast
	private var reconnectInFlight = false
	private var lastKeepaliveAt = Date.distantPast
	private var linkLostFired = false

	private override init() {
		super.init()
	}

	func start(active: BeamioNativeVoiceSignaling.ActiveCall) {
		queue.async { [weak self] in
			guard let self else { return }
			self.stopLocked()
			self.active = active
			self.running = true
			self.legacyMode = UserDefaults.standard.bool(forKey: "beamioVideoLegacy")
			if self.legacyMode { NSLog("[BeamioNativeVoiceChannel] QA legacy video mode") }
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
			BeamioCallTiming.mark("listen-start")
			self.startVoiceListenLocked(active: active)
			if active.mediaEnabled {
				self.beginLinkWatchLocked()
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
			self.beginLinkWatchLocked()
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
		playoutTargetSamples = Self.playoutMinSamples
		lastUnderrunAt = .distantPast
		lastDecayAt = Date()
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
		peerVideoCaps = 0
		capsSent = 0
		videoSeqOffset = 0
		DispatchQueue.main.async { self.videoShownCaptureMs = 0 }
		stats.reset()
		statsLastFlush = Date()
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
				// Inside the AES payload: the peer learns our capability even if
				// the caps frame was lost.
				"video": self.legacyMode ? 0 : Self.localVideoCaps,
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

	/// Announce what this build can receive (`voice_media_caps_v1`, AES control).
	/// Old peers log the unknown type and ignore it. Runs on `queue`.
	private func sendMediaCapsLocked(active: BeamioNativeVoiceSignaling.ActiveCall, reason: String) {
		guard !legacyMode, active.mediaEnabled, !active.peerMediaSessionId.isEmpty, uplinkRoute != nil else { return }
		capsSent += 1
		let body: [String: Any] = [
			"type": "voice_media_caps_v1",
			"callId": active.offer.callId,
			"sessionId": active.listenSessionId,
			"video": Self.localVideoCaps,
			"timestamp": Int(Date().timeIntervalSince1970 * 1000),
		]
		sendControlJsonUplink(body, active: active)
		NSLog("[BeamioNativeVoiceChannel] media caps sent video=%d reason=%@", Self.localVideoCaps, reason)
	}

	/// Peer capability from `voice_media_caps_v1` or a video enable control.
	private func notePeerCapsLocked(_ json: [String: Any], active: BeamioNativeVoiceSignaling.ActiveCall) {
		guard !legacyMode, let video = Self.intValue(json["video"]), video > 0 else { return }
		let first = peerVideoCaps == 0
		if video != peerVideoCaps {
			peerVideoCaps = video
			NSLog("[BeamioNativeVoiceChannel] peer media caps video=%d", video)
			BeamioNativeVoiceSignaling.qaTrail("video peer caps=\(video) callId=\(active.offer.callId)")
		}
		// Reply once so both sides know even if our first announcement was lost.
		if first, (json["type"] as? String) == "voice_media_caps_v1" {
			sendMediaCapsLocked(active: active, reason: "reply")
		}
	}

	/// Split-seq video with `BJP2` once the peer announced support; else the old
	/// shared-seq `BJPG` so older builds keep working.
	private var videoSplitSeq: Bool { peerVideoCaps >= 2 }

	/// JPEG uplink for FaceTime (BJPG / BJP2 wire). Dropped when peer media session missing.
	func sendVideoJpegFrame(_ jpeg: Data, width: Int, height: Int) {
		let captureMs = Int64(Date().timeIntervalSince1970 * 1000)
		queue.async { [weak self] in
			guard let self, let active = self.active, self.running else { return }
			guard active.mediaEnabled, !jpeg.isEmpty else { return }
			guard !active.peerMediaSessionId.isEmpty else { return }
			let peer = active.peerEoa.lowercased()
			guard peer.hasPrefix("0x"), peer.count == 42 else { return }
			self.stats.update { $0.txCap += 1 }
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
				self.stats.update { $0.txDropRoute += 1 }
				self.resolveUplinkRouteIfNeeded(peer: peer, callId: active.offer.callId)
				return
			}
			// Audio first: skip video while audio has half its send slots in use.
			if self.uplinkInFlight >= Self.maxUplinkInFlight / 2 {
				self.videoDropAudioFirst += 1
				self.stats.update { $0.txDropAudio += 1 }
				return
			}
			if self.videoUplinkInFlight >= Self.maxVideoUplinkInFlight {
				self.videoDropBusy += 1
				self.stats.update { $0.txDropBusy += 1 }
				return
			}
			self.videoFramesSent += 1
			self.videoFrameId &+= 1
			let frameId = self.videoFrameId
			let split = self.videoSplitSeq
			var framed = Data(split ? Self.jp2Magic : Self.jpgMagic)
			var w = UInt16(clamping: width).littleEndian
			var h = UInt16(clamping: height).littleEndian
			var fid = frameId.littleEndian
			withUnsafeBytes(of: &w) { framed.append(contentsOf: $0) }
			withUnsafeBytes(of: &h) { framed.append(contentsOf: $0) }
			withUnsafeBytes(of: &fid) { framed.append(contentsOf: $0) }
			if split {
				var ts = UInt64(max(0, captureMs)).littleEndian
				withUnsafeBytes(of: &ts) { framed.append(contentsOf: $0) }
			}
			framed.append(jpeg)
			let payload: String
			do {
				let key = try BeamioVoiceAesGcm.keyFromBase64(active.offer.sessionKey)
				payload = try BeamioVoiceAesGcm.encrypt(key: key, plain: framed)
			} catch {
				return
			}
			let seq: Int
			if split {
				self.videoSeqOffset += 1
				seq = Self.videoSeqBase + self.videoSeqOffset
			} else {
				seq = self.takeUplinkSeq()
			}
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
			let jpegBytes = jpeg.count
			let encStarted = Date()
			self.routeEncrypt(
				plaintext: opaque,
				routeArmor: route.routePublicKeyArmor
			) { [weak self] result in
				guard let self else { return }
				guard let armor = try? result.get(), armor.contains("BEGIN PGP MESSAGE") else {
					self.queue.async { self.videoUplinkInFlight = max(0, self.videoUplinkInFlight - 1) }
					return
				}
				let encMs = Int(Date().timeIntervalSince(encStarted) * 1000)
				self.stats.update {
					$0.txSent += 1
					$0.txJpegBytes += jpegBytes
					$0.txWireBytes += armor.utf8.count
					$0.txEncMsSum += encMs
				}
				self.uplinkPostQueue.async {
					let outcome = Self.postDirect(armor: armor, ip: entryIp)
					self.noteEntryOutcome(outcome, ip: entryIp, route: route)
					self.stats.update {
						if outcome.ok { $0.txOk += 1 } else { $0.txFail += 1 }
						$0.txPostMsSum += outcome.ms
						$0.txPostMsMax = max($0.txPostMsMax, outcome.ms)
					}
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
		self.routeEncrypt(
			plaintext: opaque,
			routeArmor: route.routePublicKeyArmor
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
		let relayWake = active?.dialerWake
		running = false
		endLinkWatchLocked()
		listenGen += 1
		listenHandle?.cancel()
		listenHandle = nil
		listenEntryIp = nil
		listenStartedAt = nil
		active = nil
		resetMediaStateLocked()
		if listenSessionId.count >= 16 {
			postVoiceUnlistenLocked(sessionId: listenSessionId, relay: relayWake)
		}
		NSLog("[BeamioNativeVoiceChannel] stopped")
	}

	/// Best-effort `voice_unlisten` to the node holding the session: the call's
	/// relay node when there is one, else own mailbox (entry ≠ that node). SI
	/// drops the session without EIP-191 when sessionId length ≥ 16.
	private func postVoiceUnlistenLocked(sessionId: String, relay: BeamioNativeVoiceSignaling.DialerWake? = nil) {
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
		let relayRoute = relay.flatMap {
			$0.relayRouteArmored.contains("BEGIN PGP PUBLIC KEY") ? $0.relayRouteArmored : nil
		}
		BeamioOpenPgpHost.shared.encrypt(
			plaintext: opaque,
			publicKeyArmor: relayRoute ?? secrets.routePublicKeyArmor
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
		if relayRoute != nil, let relayIp = BeamioSiCipherPost.normalizeIp(relay?.relayIp ?? "") {
			exclude.insert(relayIp)
		}
		let posted = BeamioSiCipherPost.post(armor: armor, nodes: nodes, excludeIps: exclude, maxAttempts: 3, timeout: 8)
		NSLog(
			"[BeamioNativeVoiceChannel] voice_unlisten session=%@ ok=%@",
			sessionId,
			posted.ok ? "yes" : "no"
		)
	}

	// MARK: - Link health

	/// Media just started (callee on Answer, dialer on Accept): arm the watchdog.
	private func beginLinkWatchLocked() {
		let now = Date()
		mediaStartedAt = now
		lastRxAt = now
		lastTxOkAt = now
		reconnecting = false
		reconnectAttempt = 0
		nextReconnectAt = .distantPast
		linkLostFired = false
		linkTimer?.cancel()
		let timer = DispatchSource.makeTimerSource(queue: queue)
		timer.schedule(deadline: .now() + 1, repeating: 1)
		timer.setEventHandler { [weak self] in self?.linkTickLocked() }
		timer.resume()
		linkTimer = timer
	}

	private func endLinkWatchLocked() {
		linkTimer?.cancel()
		linkTimer = nil
		if reconnecting {
			reconnecting = false
			DispatchQueue.main.async { BeamioInCallScreenModel.shared.setReconnecting(false) }
		}
		reconnectInFlight = false
		listenAlive = false
		listenReady = false
	}

	/// A peer frame (media, control or keepalive) arrived.
	private func noteRxLocked() {
		lastRxAt = Date()
		if reconnecting {
			reconnecting = false
			reconnectAttempt = 0
			BeamioQALog.write("voice link restored")
			NSLog("[BeamioNativeVoiceChannel] link restored")
			DispatchQueue.main.async { BeamioInCallScreenModel.shared.setReconnecting(false) }
		}
	}

	private func linkTickLocked() {
		guard running, let live = active, live.mediaEnabled, !linkLostFired else { return }
		let now = Date()
		let rxIdle = now.timeIntervalSince(lastRxAt)
		let txIdle = now.timeIntervalSince(lastTxOkAt)
		if rxIdle >= Self.linkLostLimit, txIdle >= Self.linkLostLimit {
			linkLostFired = true
			BeamioQALog.write("voice link lost rxIdle=\(Int(rxIdle)) txIdle=\(Int(txIdle)) attempts=\(reconnectAttempt)")
			NSLog("[BeamioNativeVoiceChannel] connection lost rxIdle=%.0f txIdle=%.0f", rxIdle, txIdle)
			let callId = live.offer.callId
			let sessionId = live.offer.sessionId
			DispatchQueue.main.async {
				BeamioInCallScreenModel.shared.connectionLost(callId: callId, sessionId: sessionId)
			}
			return
		}
		let silent = now.timeIntervalSince(mediaStartedAt) >= Self.mediaStartGrace
			&& rxIdle >= Self.rxStaleReconnect
		guard !listenAlive || silent else { return }
		if !reconnecting {
			reconnecting = true
			reconnectAttempt = 0
			nextReconnectAt = now
			BeamioQALog.write("voice link reconnecting listenAlive=\(listenAlive) rxIdle=\(Int(rxIdle))")
			DispatchQueue.main.async { BeamioInCallScreenModel.shared.setReconnecting(true) }
		}
		guard !reconnectInFlight, now >= nextReconnectAt else { return }
		reconnectAttempt += 1
		let backoff = min(8, pow(2, Double(reconnectAttempt - 1)))
		// A fresh listen needs a few seconds to show peer frames before it is
		// judged again.
		nextReconnectAt = now.addingTimeInterval(max(backoff, 4))
		startReconnectLocked(active: live, unlistenFirst: reconnectAttempt > 1)
	}

	/// Reopen `voice_listen` for the same session through a new random entry.
	/// The first attempt assumes the node already dropped the old socket; later
	/// ones send `voice_unlisten` first (the node answers `session_conflict`
	/// while it still holds the old one).
	private func startReconnectLocked(active live: BeamioNativeVoiceSignaling.ActiveCall, unlistenFirst: Bool) {
		reconnectInFlight = true
		listenGen += 1
		let gen = listenGen
		listenHandle?.cancel()
		listenHandle = nil
		listenAlive = false
		listenReady = false
		let previousEntry = listenEntryIp
		let attempt = reconnectAttempt
		BeamioQALog.write("voice listen reconnect attempt=\(attempt) unlisten=\(unlistenFirst)")
		reconnectQueue.async { [weak self] in
			guard let self else { return }
			if unlistenFirst {
				self.postVoiceUnlistenLocked(sessionId: live.listenSessionId, relay: live.dialerWake)
				Thread.sleep(forTimeInterval: 1.5)
			}
			let opened = self.openReconnectListen(active: live, gen: gen, avoidEntry: previousEntry)
			self.queue.async {
				self.reconnectInFlight = false
				guard self.running, gen == self.listenGen, let opened else {
					opened?.handle.cancel()
					return
				}
				self.listenHandle = opened.handle
				self.listenEntryIp = opened.entryIp
				self.listenStartedAt = Date()
			}
		}
	}

	/// Build and open the reconnect `voice_listen` (off `queue`: PGP encrypt and
	/// connect can take seconds while the network is down). Same node as the
	/// original listen: the call's relay for the dialer, own mailbox otherwise.
	private func openReconnectListen(
		active live: BeamioNativeVoiceSignaling.ActiveCall,
		gen: Int,
		avoidEntry: String?
	) -> (handle: BeamioSiCipherPost.SseHandle, entryIp: String)? {
		guard let secrets = BeamioChatPgpKeychain.load(),
		      secrets.routePublicKeyArmor.contains("BEGIN PGP PUBLIC KEY")
		else { return nil }
		let command: [String: Any] = [
			"command": "voice_listen",
			"sessionId": live.listenSessionId,
			"timestamp": Int(Date().timeIntervalSince1970),
		]
		guard let jsonData = try? JSONSerialization.data(withJSONObject: command, options: []),
		      let jsonUtf8 = String(data: jsonData, encoding: .utf8)
		else { return nil }
		let relayRoute: String? = live.dialerWake.flatMap {
			$0.relayRouteArmored.contains("BEGIN PGP PUBLIC KEY") ? $0.relayRouteArmored : nil
		}
		let sem = DispatchSemaphore(value: 0)
		var armorOut: String?
		BeamioOpenPgpHost.shared.encrypt(
			plaintext: Data(jsonUtf8.utf8).base64EncodedString(),
			publicKeyArmor: relayRoute ?? secrets.routePublicKeyArmor
		) { result in
			armorOut = try? result.get()
			sem.signal()
		}
		_ = sem.wait(timeout: .now() + 8)
		guard let armor = armorOut, armor.contains("BEGIN PGP MESSAGE") else { return nil }
		let nodes = BeamioChatPgpKeychain.loadSiNodes()
		var exclude = Set<String>()
		if let mailbox = BeamioSiCipherPost.normalizeIp(secrets.mailboxIp) { exclude.insert(mailbox) }
		if relayRoute != nil, let relayIp = BeamioSiCipherPost.normalizeIp(live.dialerWake?.relayIp ?? "") {
			exclude.insert(relayIp)
		}
		var avoid = exclude
		if let previous = avoidEntry { avoid.insert(previous) }
		guard let entryIp = pickEntryIp(nodes: nodes, exclude: avoid) ?? pickEntryIp(nodes: nodes, exclude: exclude),
		      let url = BeamioSiCipherPost.postUrl(for: entryIp)
		else { return nil }
		let handle = BeamioSiCipherPost.postSse(
			url: url,
			armor: armor,
			connectTimeout: 8,
			idleTimeout: 3600,
			onOpen: { [weak self] in
				BeamioQALog.write("voice listen reopen http-open session=\(live.listenSessionId.prefix(8))")
				self?.queue.async { if self?.listenGen == gen { self?.listenAlive = true } }
			},
			onEvent: { [weak self] payload in
				self?.queue.async {
					guard let self, self.listenGen == gen else { return }
					self.handleSsePayload(payload)
				}
			},
			onClosed: { [weak self] reason in
				BeamioQALog.write("voice listen reopen closed reason=\(reason ?? "eof")")
				self?.queue.async {
					guard let self, self.listenGen == gen else { return }
					self.listenAlive = false
					self.listenReady = false
				}
			}
		)
		guard let handle else { return nil }
		return (handle, entryIp)
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
		// Per-call relay node (not own mailbox). The PWA already delivered the
		// offer to the callee's mailbox through a random entry, so the listen
		// carries no offerArmor and no node is asked to forward it.
		let relayRoute: String? = active.dialerWake.flatMap {
			$0.relayRouteArmored.contains("BEGIN PGP PUBLIC KEY") ? $0.relayRouteArmored : nil
		}
		// Dialer owns VoIP wake: the node holding the session calls the push API.
		if let wake = active.dialerWake,
		   relayRoute != nil || wake.offerArmor.contains("BEGIN PGP MESSAGE"),
		   !wake.calleeEoa.isEmpty,
		   !wake.callId.isEmpty {
			command["callId"] = wake.callId
			command["targetWallet"] = wake.calleeEoa
			command["expiresAt"] = wake.expiresAt
			command["pushTimestamp"] = wake.pushTimestamp
			if relayRoute == nil { command["offerArmor"] = wake.offerArmor }
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
			publicKeyArmor: relayRoute ?? secrets.routePublicKeyArmor
		) { result in
			armorOut = try? result.get()
			sem.signal()
		}
		_ = sem.wait(timeout: .now() + 12)
		BeamioCallTiming.mark("listen-encrypted")
		guard let armor = armorOut, armor.contains("BEGIN PGP MESSAGE") else {
			NSLog("[BeamioNativeVoiceChannel] listen encrypt failed")
			return
		}

		let nodes = BeamioChatPgpKeychain.loadSiNodes()
		var exclude = Set<String>()
		if let mailbox = BeamioSiCipherPost.normalizeIp(secrets.mailboxIp) {
			exclude.insert(mailbox)
		}
		// Entry must not be the node that holds the session.
		if relayRoute != nil, let relayIp = BeamioSiCipherPost.normalizeIp(active.dialerWake?.relayIp ?? "") {
			exclude.insert(relayIp)
		}
		guard let entryIp = pickEntryIp(nodes: nodes, exclude: exclude) else {
			NSLog("[BeamioNativeVoiceChannel] listen — no reachable entry IP")
			return
		}
		NSLog("[BeamioNativeVoiceChannel] voice_listen node=%@", relayRoute != nil ? "relay" : "own-mailbox")
		guard let url = BeamioSiCipherPost.postUrl(for: entryIp) else { return }

		_ = offerIndexed.wait(timeout: .now() + 3)
		BeamioCallTiming.mark("listen-post")
		listenEntryIp = entryIp
		listenStartedAt = Date()
		listenGen += 1
		let gen = listenGen
		listenAlive = false
		listenReady = false
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
			onOpen: { [weak self] in
				BeamioCallTiming.mark("listen-open")
				BeamioQALog.write("voice listen open role=\(active.role.rawValue) session=\(active.listenSessionId.prefix(8))")
				NSLog("[BeamioNativeVoiceChannel] listen open entry=%@", entryIp)
				self?.queue.async { if self?.listenGen == gen { self?.listenAlive = true } }
			},
			onEvent: { [weak self] payload in
				self?.queue.async { self?.handleSsePayload(payload) }
			},
			onClosed: { [weak self] reason in
				BeamioQALog.write(
					"voice listen closed role=\(active.role.rawValue) session=\(active.listenSessionId.prefix(8)) reason=\(reason ?? "eof")"
				)
				NSLog("[BeamioNativeVoiceChannel] listen closed entry=%@ reason=%@", entryIp, reason ?? "eof")
				self?.queue.async {
					guard let self, self.listenGen == gen else { return }
					self.listenAlive = false
					self.listenReady = false
				}
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
		BeamioCallTiming.mark("native-offer-index", posted.ok ? "ok" : "fail")
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
			listenReady = true
			listenAlive = true
			return
		}
		if (obj["type"] as? String) == "voice_frame_v1" || obj["command"] as? String == "voice_uplink" {
			noteRxLocked()
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
				if type == "voice_media_caps_v1" {
					notePeerCapsLocked(json, active: active)
					return
				}
				if type == "voice_video_enable_v1" {
					notePeerCapsLocked(json, active: active)
					// The peer is about to send video: make sure it knows what we
					// can receive (our earlier caps may have been lost).
					sendMediaCapsLocked(active: active, reason: "peer-video-on")
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
			// Split-seq video (peer saw our caps): never enters the audio
			// reorder buffer, so its loss or delay cannot stall audio.
			if let seq = Self.intValue(frame["seq"]), seq >= Self.videoSeqBase {
				handleSplitVideoLocked(plain)
				return
			}
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
		} else if let video = Self.decodeWireVideo(plain) {
			stats.update {
				$0.rxIn += 1
				$0.rxBytes += plain.count
			}
			rxPendingJpeg[seq] = (video.image, video.captureMs > 0 ? video.captureMs : senderTs)
		} else if let pcm = Self.decodeWirePcm(plain) {
			stats.update { $0.audioRx += 1 }
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

	/// One split-seq video frame (`BJP2`, or `BJPG` from a peer mid-upgrade).
	/// Runs on `queue`.
	private func handleSplitVideoLocked(_ plain: Data) {
		guard let video = Self.decodeWireVideo(plain) else {
			NSLog("[BeamioNativeVoiceChannel] video frame invalid bytes=%d", plain.count)
			return
		}
		stats.update {
			$0.rxIn += 1
			$0.rxBytes += plain.count
		}
		if video.captureMs > 0 {
			stats.noteRxTiming(captureMs: video.captureMs, arrivalMs: Int64(Date().timeIntervalSince1970 * 1000))
		}
		scheduleVideoFrame(video.image, senderTs: video.captureMs)
	}

	private func deliverRxPlainImmediate(_ plain: Data, senderTs: Int64) {
		if let video = Self.decodeWireVideo(plain) {
			scheduleVideoFrame(video.image, senderTs: video.captureMs > 0 ? video.captureMs : senderTs)
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
		queue.asyncAfter(deadline: .now() + rxJitterWait, execute: work)
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
		stats.update { $0.audioGapSkip += 1 }
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
		let stats = self.stats
		let show = { [weak self] in
			guard let self else { return }
			// Main thread. A newer frame already shown wins: never step back.
			if senderTs > 0 {
				if senderTs < self.videoShownCaptureMs {
					stats.update { $0.rxSuperseded += 1 }
					return
				}
				self.videoShownCaptureMs = senderTs
			}
			stats.update { $0.rxShown += 1 }
			enabledCb?(true)
			cb?(image)
		}
		guard senderTs > 0 else {
			DispatchQueue.main.async(execute: show)
			return
		}
		guard senderTs > videoLastSenderTs else {
			stats.update { $0.rxSuperseded += 1 }
			return
		}
		videoLastSenderTs = senderTs
		let now = Int64(Date().timeIntervalSince1970 * 1000)
		let delta = now - senderTs
		// Track the fastest transit; relax slowly so a slower path is adopted.
		let minDelta = videoMinDeltaMs.map { min(delta, $0 + 2) } ?? delta
		videoMinDeltaMs = minDelta
		let waitMs = max(0, senderTs + minDelta + Self.videoPlayoutDelayMs - now)
		DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(waitMs)), execute: show)
	}

	/// `BJPG` (12-byte header) or `BJP2` (20-byte header with capture time)
	/// → decoded image. Decodes here, on the channel queue, so the main thread
	/// only swaps a ready bitmap. `captureMs` is 0 for `BJPG`.
	private static func decodeWireVideo(_ plain: Data) -> (image: UIImage, captureMs: Int64)? {
		guard plain.count >= 12 else { return nil }
		let magic = [UInt8](plain.prefix(4))
		let headerBytes: Int
		var captureMs: Int64 = 0
		if magic == jpgMagic {
			headerBytes = 12
		} else if magic == jp2Magic, plain.count > 20 {
			headerBytes = 20
			let start = plain.startIndex + 12
			var ts: UInt64 = 0
			for i in 0 ..< 8 { ts |= UInt64(plain[start + i]) << (8 * UInt64(i)) }
			captureMs = Int64(clamping: ts)
		} else {
			return nil
		}
		let jpeg = plain.subdata(in: (plain.startIndex + headerBytes) ..< plain.endIndex)
		guard !jpeg.isEmpty, let image = UIImage(data: jpeg) else { return nil }
		return (image.preparingForDisplay() ?? image, captureMs)
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
		// Accept arrived: the ringback must be gone before voice processing starts.
		BeamioCallTonePlayer.shared.stopRingback(reason: "voice-engine")
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
			self.flushVideoStatsLocked()
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

	/// Route-PGP for call frames: the dedicated encryptor, or the shared host in
	/// QA legacy mode.
	private func routeEncrypt(
		plaintext: String,
		routeArmor: String,
		completion: @escaping (Result<String, Error>) -> Void
	) {
		if legacyMode {
			BeamioOpenPgpHost.shared.encrypt(plaintext: plaintext, publicKeyArmor: routeArmor, completion: completion)
		} else {
			BeamioVoiceRoutePgp.shared.encrypt(plaintext: plaintext, routeArmor: routeArmor, completion: completion)
		}
	}

	/// One `[VideoStats]` line per diagnostics tick while video moves. Runs on `queue`.
	private func flushVideoStatsLocked() {
		// Touch the capture object only after video was used: `.shared` builds an
		// AVCaptureSession, which a voice-only call must not create.
		let enc = BeamioInCallVideoCapture.instantiated
			? BeamioInCallVideoCapture.shared.takeEncodeStats()
			: (count: 0, sumMs: 0, maxMs: 0)
		if enc.count > 0 {
			stats.update {
				$0.capEncodeN += enc.count
				$0.capEncodeMsSum += enc.sumMs
				$0.capEncodeMsMax = max($0.capEncodeMsMax, enc.maxMs)
			}
		}
		let now = Date()
		let seconds = now.timeIntervalSince(statsLastFlush)
		statsLastFlush = now
		let mode = legacyMode ? "legacy" : (videoSplitSeq ? "v2" : "v1")
		guard let line = stats.flush(mode: mode, peerCaps: peerVideoCaps, seconds: seconds) else { return }
		BeamioNativeVoiceSignaling.qaTrail(line)
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
			// No microphone audio leaves the device while muted, and no stale
			// audio is kept. A 20 ms silent packet each second tells the peer
			// this side is still on the call (its connection-lost check), and
			// its accept/fail result tells us whether the peer still is.
			uplinkAccum = Data()
			let now = Date()
			if now.timeIntervalSince(lastKeepaliveAt) >= Self.mutedKeepaliveInterval,
			   live.mediaEnabled, !live.peerMediaSessionId.isEmpty,
			   uplinkSlotAvailable(active: live)
			{
				lastKeepaliveAt = now
				sendUplinkFrame(Data(count: 320 * MemoryLayout<Int16>.size), active: live)
			}
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
		// Callee: the caller's session is on its per-call relay node (signed in
		// the offer). Dialer: the callee listens on its own mailbox.
		let relayOffer: BeamioVoiceOfferIdentity.Resolved? = {
			guard let active, active.role == .callee,
			      active.offer.relayRouteArmored.contains("BEGIN PGP PUBLIC KEY")
			else { return nil }
			return active.offer
		}()
		uplinkPostQueue.async { [weak self] in
			var resolved: UplinkRoute?
			if let relay = relayOffer {
				let nodes = BeamioChatPgpKeychain.loadSiNodes()
				var exclude = Set<String>()
				if let relayIp = BeamioSiCipherPost.normalizeIp(relay.relayIp) { exclude.insert(relayIp) }
				if let mailbox = BeamioSiCipherPost.normalizeIp(BeamioChatPgpKeychain.load()?.mailboxIp ?? "") {
					exclude.insert(mailbox)
				}
				if let node = BeamioSiCipherPost.getRandomNode(nodes: nodes, excludeIps: exclude) {
					resolved = UplinkRoute(
						routePublicKeyArmor: relay.relayRouteArmored,
						nodes: nodes,
						exclude: exclude,
						entries: BeamioEntryRotation(first: node.ip)
					)
				}
			} else if let keys = BeamioAddressPgp.searchKey(address: peer),
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
				// Announce media caps once a route exists (again after a route
				// reset until the peer has answered).
				if resolved != nil, let live = self.active, self.capsSent == 0 || self.peerVideoCaps == 0 {
					self.sendMediaCapsLocked(active: live, reason: "route")
				}
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
			lastTxOkAt = Date()
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
		self.routeEncrypt(
			plaintext: opaque,
			routeArmor: route.routePublicKeyArmor
		) { [weak self] result in
			guard let self else { return }
			guard let armor = try? result.get(), armor.contains("BEGIN PGP MESSAGE") else {
				self.queue.async { self.uplinkInFlight = max(0, self.uplinkInFlight - 1) }
				return
			}
			let wireBytes = armor.utf8.count
			self.stats.update {
				$0.audioTx += 1
				$0.audioTxWireBytes += wireBytes
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
	/// `maxPlayBacklog`. Runs on `queue`.
	private func playPcm(_ pcm: Data) {
		guard !pcm.isEmpty else { return }
		let frames = pcm.count / MemoryLayout<Int16>.size
		guard frames > 0 else { return }
		if playPrebuffering {
			playPending.append(pcm)
			playPendingSamples += frames
			guard playPendingSamples >= playoutTargetSamples else { return }
			playPrebuffering = false
			NSLog("[BeamioNativeVoiceChannel] playout start depthMs=%d", playPendingSamples * 1000 / Self.wireRate)
			let pending = playPending
			playPending.removeAll()
			playPendingSamples = 0
			for chunk in pending { schedulePcm(chunk) }
			return
		}
		// Latency cap: the player is well behind, drop this frame.
		decayPlayoutTargetIfStable()
		if rxBacklogSamples > maxPlayBacklog {
			playFadeNext = true
			return
		}
		schedulePcm(pcm)
	}

	private func growPlayoutTargetAfterUnderrun() {
		let now = Date()
		lastUnderrunAt = now
		lastDecayAt = now
		stats.update { $0.audioUnderrun += 1 }
		let next = min(Self.playoutMaxSamples, playoutTargetSamples + Self.playoutStepUpSamples)
		if next != playoutTargetSamples {
			playoutTargetSamples = next
			NSLog("[BeamioNativeVoiceChannel] underrun — playout depth %dms", next * 1000 / Self.wireRate)
		}
	}

	private func decayPlayoutTargetIfStable() {
		guard playoutTargetSamples > Self.playoutMinSamples else { return }
		let now = Date()
		guard now.timeIntervalSince(lastUnderrunAt) >= Self.playoutDecayInterval,
		      now.timeIntervalSince(lastDecayAt) >= Self.playoutDecayInterval
		else { return }
		lastDecayAt = now
		playoutTargetSamples = max(Self.playoutMinSamples, playoutTargetSamples - Self.playoutStepDownSamples)
		NSLog("[BeamioNativeVoiceChannel] stable — playout depth %dms", playoutTargetSamples * 1000 / Self.wireRate)
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
					self.growPlayoutTargetAfterUnderrun()
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
