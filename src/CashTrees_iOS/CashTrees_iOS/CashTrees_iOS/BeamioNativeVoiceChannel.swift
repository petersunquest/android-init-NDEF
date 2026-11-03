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
	private var statsLastFlush = Date()
	private var onRemoteVideoFrame: ((UIImage) -> Void)?
	private var onPeerVideoEnabled: ((Bool) -> Void)?

	// MARK: Channel chunks (CVC2: no per-frame metadata at the node)
	private var v2TxChunks = 0
	private var v2RxChunks = 0

	// MARK: Voice protocol v3 (paid channels; `active.v3`)

	/// Second SSE: our own video channel (opened with the voice one, pre-warmed).
	private var videoListenHandle: BeamioSiCipherPost.SseHandle?
	private var videoListenGen = 0
	private var videoReady = false
	private var videoReopenAttempt = 0
	/// Caller: the callee has our relays (`voice_channel_ready_v3` accepted).
	private var v3ReadySent = false
	private var v3ReadyInFlight = false
	/// Set by the first frame the relay accepts into the peer's channel. Read and
	/// written on the post queue, so it has its own lock.
	private let peerChannelSeen = PeerChannelFlag()

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
	/// The uplink entry pool, readable off `queue`: Hang Up takes it on the main
	/// thread before `stop()` clears the route.
	private let warmEntriesLock = NSLock()
	private var warmEntriesRef: BeamioEntryRotation?
	private var uplinkInFlight = 0
	/// Per-call audio uplink tally, [0] = v1 frames, [1] = v2 chunks (bytes on the wire, timing). On `queue`.
	private struct WireTally {
		var n = 0, fail = 0, bytes = 0, encMs = 0, postMs = 0, postMax = 0
		var line: String {
			let d = max(n, 1)
			return "n=\(n) fail=\(fail) avgB=\(bytes / d) encAvg=\(encMs / d)ms postAvg=\(postMs / d)ms postMax=\(postMax)ms"
		}
	}
	private var audioTally = [WireTally(), WireTally()]
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
	/// The call's first listen is still opening (encrypt, entry, HTTP). It is not
	/// "closed", so the watchdog must not tear it down and show Reconnecting… at
	/// call start. Cleared when that listen opens or closes; capped at 8 s.
	private var firstListenOpeningSince: Date?
	private static let firstListenOpenGrace: TimeInterval = 8
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
			self.firstListenOpeningSince = Date()
			BeamioQALog.write("voice start role=\(active.role.rawValue) callId=\(active.offer.callId.prefix(8)) listen=\(active.listenSessionId.prefix(8)) media=\(active.mediaEnabled)")
			guard active.v3 != nil else {
				// Voice protocol v3 only: a call without its channels cannot open.
				NSLog("[BeamioNativeVoiceChannel] start skipped — no v3 channels")
				return
			}
			self.startV3ListensLocked(active: active)
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
		v2TxChunks = 0
		v2RxChunks = 0
		v3ReadySent = false
		v3ReadyInFlight = false
		peerChannelSeen.set(false)
		audioTally = [WireTally(), WireTally()]
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
				"video": Self.localVideoCaps,
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
		guard active.mediaEnabled, !active.peerMediaSessionId.isEmpty, uplinkRoute != nil else { return }
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
		BeamioQALog.write("voice caps sent reason=\(reason) callId=\(active.offer.callId.prefix(8))")
	}

	/// Peer capability from `voice_media_caps_v1` or a video enable control.
	private func notePeerCapsLocked(_ json: [String: Any], active: BeamioNativeVoiceSignaling.ActiveCall) {
		guard let video = Self.intValue(json["video"]), video > 0 else { return }
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
			let seq: Int
			if split {
				self.videoSeqOffset += 1
				seq = Self.videoSeqBase + self.videoSeqOffset
			} else {
				seq = self.takeUplinkSeq()
			}
			guard let entryIp = route.entries.next() else { return }
			self.videoUplinkInFlight += 1
			let jpegBytes = jpeg.count
			let encStarted = Date()
			self.buildUplinkArmorLocked(
				active: active, route: route, plain: framed, kind: .video,
				seq: seq, captureMs: captureMs, frameId: frameId, mediaKind: "video"
			) { [weak self] armor, usedV2 in
				guard let self else { return }
				guard let armor else {
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
					let outcome = self.postAwaitingPeerChannel(armor: armor, ip: entryIp)
					self.noteEntryOutcome(outcome, ip: entryIp, route: route)
					self.stats.update {
						if outcome.ok { $0.txOk += 1 } else { $0.txFail += 1 }
						$0.txPostMsSum += outcome.ms
						$0.txPostMsMax = max($0.txPostMsMax, outcome.ms)
					}
					self.queue.async {
						self.videoUplinkInFlight = max(0, self.videoUplinkInFlight - 1)
						self.noteV2OutcomeLocked(outcome, usedV2: usedV2)
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
		guard let jsonData = try? JSONSerialization.data(withJSONObject: body, options: []) else { return }
		let seq = takeUplinkSeq()
		guard let entryIp = route.entries.next() else { return }
		buildUplinkArmorLocked(
			active: active, route: route, plain: jsonData, kind: .control,
			seq: seq, captureMs: Int64(Date().timeIntervalSince1970 * 1000)
		) { [weak self] armor, usedV2 in
			guard let self, let armor else { return }
			self.uplinkPostQueue.async {
				let outcome = self.postAwaitingPeerChannel(armor: armor, ip: entryIp)
				self.noteEntryOutcome(outcome, ip: entryIp, route: route)
				self.queue.async { self.noteV2OutcomeLocked(outcome, usedV2: usedV2) }
			}
		}
	}

	/// Route armor for one outgoing frame. v2 when the peer opened a v2 channel:
	/// the node sees only `CVC2 ‖ locator ‖ mac ‖ blob`. Otherwise (or when the
	/// binary encrypt fails) the v1 `voice_uplink` command. Runs on `queue`;
	/// `completion` runs on any thread with (armor, usedV2).
	private func buildUplinkArmorLocked(
		active: BeamioNativeVoiceSignaling.ActiveCall,
		route: UplinkRoute,
		plain: Data,
		kind: BeamioVoiceChannelV2.Kind,
		seq: Int,
		captureMs: Int64,
		frameId: UInt32 = 0,
		mediaKind: String? = nil,
		completion: @escaping (String?, Bool) -> Void
	) {
		if let v3 = active.v3 {
			// Audio and control to the peer's voice channel, video to its video
			// channel, each with that channel's own keys.
			let target = kind == .video ? v3.peerVideo : v3.peerVoice
			guard let relay = target.relay, let loc = target.channel.locator,
			      let key = try? BeamioVoiceAesGcm.keyFromBase64(target.channel.keyB64),
			      let literal = try? BeamioVoiceChannelV2.sealChunk(
			      	sessionKey: key, peer: .init(locator: loc, writeKey: target.channel.wk),
			      	kind: kind, seq: seq, captureMs: captureMs, frameId: frameId, data: plain
			      )
			else {
				completion(nil, false)
				return
			}
			BeamioVoiceRoutePgp.shared.encryptBinary(literal, routeArmor: relay.armor) { result in
				completion(try? result.get(), true)
			}
			return
		}
		// Voice protocol v3 only.
		completion(nil, false)
	}

	/// Counts accepted chunks. A missing peer channel (reconnecting) loses that
	/// frame, not the call. Runs on `queue`.
	private func noteV2OutcomeLocked(_ outcome: (ok: Bool, status: Int, ms: Int, note: String), usedV2: Bool) {
		// A POST still in flight when the call stopped says nothing about the next call.
		guard usedV2, running, outcome.ok else { return }
		v2TxChunks += 1
		if v2TxChunks == 1 {
			NSLog("[BeamioNativeVoiceChannel] first chunk accepted")
			BeamioQALog.write("voice first chunk accepted")
		}
	}

	private func stopLocked() {
		// Capture before tear-down: dialer Stop must free mailbox voice_listen
		// so the next redial can re-occupy the same sessionId (or a new one).
		let v3 = active?.v3
		running = false
		endLinkWatchLocked()
		listenGen += 1
		listenHandle?.cancel()
		listenHandle = nil
		videoListenGen += 1
		videoListenHandle?.cancel()
		videoListenHandle = nil
		videoReady = false
		videoReopenAttempt = 0
		listenEntryIp = nil
		listenStartedAt = nil
		active = nil
		if audioTally[0].n + audioTally[1].n > 0 {
			BeamioQALog.write("audio wire v1 \(audioTally[0].line) | v2 \(audioTally[1].line)")
		}
		resetMediaStateLocked()
		if let v3 {
			reconnectQueue.async {
				for own in [v3.ownVoice, v3.ownVideo] { Self.postV3Unlisten(own) }
			}
		}
		NSLog("[BeamioNativeVoiceChannel] stopped")
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
		let firstListenOpening = firstListenOpeningSince.map {
			now.timeIntervalSince($0) < Self.firstListenOpenGrace
		} ?? false
		guard !(listenAlive || firstListenOpening) || silent else { return }
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
		firstListenOpeningSince = nil
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
			// Same channel, same T and relay: the listen is signed again.
			if unlistenFirst, let v3 = live.v3 {
				Self.postV3Unlisten(v3.ownVoice)
				Thread.sleep(forTimeInterval: 1.5)
			}
			let opened = self.openV3Sse(active: live, which: .voice, gen: gen, avoidEntry: previousEntry)
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

	// MARK: - Voice protocol v3 channels

	nonisolated enum V3Which: Sendable { case voice, video }

	/// Own relay moved after the peer learned it: announce again.
	private var v3OwnRelayMoved = false

	/// Open both own channels (voice + video, pre-warmed). Runs on `queue`.
	private func startV3ListensLocked(active: BeamioNativeVoiceSignaling.ActiveCall) {
		firstListenOpeningSince = Date()
		listenGen += 1
		videoListenGen += 1
		let gen = listenGen
		let vgen = videoListenGen
		listenAlive = false
		listenReady = false
		videoReady = false
		v3OwnRelayMoved = false
		BeamioCallTiming.mark("listen-post")
		BeamioQALog.write(
			"voice v3 listens role=\(active.role.rawValue) callId=\(active.offer.callId.prefix(8)) "
				+ "relays own=\(active.v3?.ownVoice.relay?.domain ?? "-")/\(active.v3?.ownVideo.relay?.domain ?? "-") "
				+ "peer=\(active.v3?.peerVoice.relay?.domain ?? "-")/\(active.v3?.peerVideo.relay?.domain ?? "-")"
		)
		// Caller: sign and encrypt the voice listen first; the video one waits for it
		// (they share one crypto WebView, and the first word needs only voice).
		let voiceFirst = DispatchSemaphore(value: 0)
		let serial = active.role == .dialer
		for which in [V3Which.voice, .video] {
			DispatchQueue.global(qos: .userInitiated).async { [weak self] in
				guard let self else { voiceFirst.signal(); return }
				if serial, which == .video { _ = voiceFirst.wait(timeout: .now() + 4) }
				let opened = self.openV3Sse(active: active, which: which, gen: which == .voice ? gen : vgen, avoidEntry: nil)
				if which == .voice { voiceFirst.signal() }
				self.queue.async {
					guard self.running else { opened?.handle.cancel(); return }
					if which == .voice {
						guard gen == self.listenGen, let opened else { opened?.handle.cancel(); return }
						self.listenHandle = opened.handle
						self.listenEntryIp = opened.entryIp
						self.listenStartedAt = Date()
					} else {
						guard vgen == self.videoListenGen, let opened else { opened?.handle.cancel(); return }
						self.videoListenHandle = opened.handle
					}
				}
			}
			// A relay that never answers is replaced once (stale node table, node down).
			queue.asyncAfter(deadline: .now() + 6) { [weak self] in self?.checkV3RelayLocked(which, gen: which == .voice ? gen : vgen) }
		}
		// Caller: our relays are chosen; tell the callee now, beside the listens.
		if serial { maybeSendV3ChannelReadyLocked() }
	}

	/// `voice_listen` v3 for one own channel through an entry that is neither the
	/// relay nor our mailbox. Blocking (signs with T, encrypts to the relay):
	/// never on `queue` or the main thread.
	private func openV3Sse(
		active live: BeamioNativeVoiceSignaling.ActiveCall,
		which: V3Which,
		gen: Int,
		avoidEntry: String?
	) -> (handle: BeamioSiCipherPost.SseHandle, entryIp: String)? {
		guard let v3 = live.v3 else { return nil }
		let own = which == .video ? v3.ownVideo : v3.ownVoice
		guard let relay = own.relay else { return nil }
		var armorOut: String?
		// Built while the call rang (callee): no signing or encryption on the Answer path.
		if let prepared = BeamioVoiceV3.PreparedListens.take(sid: own.channel.sid, relayDomain: relay.domain) {
			armorOut = prepared
			BeamioQALog.write("voice v3 listen prepared which=\(which)")
		} else {
			guard let command = BeamioVoiceV3.listenCommand(own, relay: relay),
			      let jsonData = try? JSONSerialization.data(withJSONObject: command, options: [])
			else {
				BeamioQALog.write("voice v3 listen build failed which=\(which)")
				return nil
			}
			let sem = DispatchSemaphore(value: 0)
			BeamioOpenPgpHost.shared.encrypt(plaintext: jsonData.base64EncodedString(), publicKeyArmor: relay.armor) { result in
				armorOut = try? result.get()
				sem.signal()
			}
			_ = sem.wait(timeout: .now() + 10)
		}
		guard let armor = armorOut, armor.contains("BEGIN PGP MESSAGE") else { return nil }
		let nodes = BeamioChatPgpKeychain.loadSiNodes()
		var exclude: Set<String> = []
		if let ip = BeamioSiCipherPost.normalizeIp(relay.ip) { exclude.insert(ip) }
		if let mailbox = BeamioSiCipherPost.normalizeIp(BeamioChatPgpKeychain.loadMailboxIp()) { exclude.insert(mailbox) }
		var avoid = exclude
		if let previous = avoidEntry { avoid.insert(previous) }
		guard let entryIp = pickEntryIp(nodes: nodes, exclude: avoid) ?? pickEntryIp(nodes: nodes, exclude: exclude),
		      let url = BeamioSiCipherPost.postUrl(for: entryIp)
		else { return nil }
		BeamioQALog.write("voice v3 listen post which=\(which) session=\(own.channel.sid.prefix(8))")
		let handle = BeamioSiCipherPost.postSse(
			url: url,
			armor: armor,
			connectTimeout: 10,
			idleTimeout: 3600,
			onOpen: { [weak self] in
				self?.queue.async {
					guard let self else { return }
					if which == .voice, self.listenGen == gen {
						BeamioCallTiming.mark("listen-open")
						self.listenAlive = true
						self.firstListenOpeningSince = nil
					}
				}
			},
			onEvent: { [weak self] payload in
				self?.queue.async {
					guard let self else { return }
					if which == .voice {
						guard self.listenGen == gen else { return }
						self.handleSsePayload(payload)
					} else {
						guard self.videoListenGen == gen else { return }
						self.handleV3VideoPayloadLocked(payload)
					}
				}
			},
			onClosed: { [weak self] reason in
				BeamioQALog.write("voice v3 listen closed which=\(which) reason=\(reason ?? "eof")")
				self?.queue.async {
					guard let self else { return }
					if which == .voice {
						guard self.listenGen == gen else { return }
						self.firstListenOpeningSince = nil
						self.listenAlive = false
						self.listenReady = false
					} else {
						guard self.videoListenGen == gen else { return }
						self.videoReady = false
						self.scheduleV3VideoReopenLocked()
					}
				}
			}
		)
		guard let handle else { return nil }
		return (handle, entryIp)
	}

	/// Our video SSE: handshake and chunks (the link watchdog follows voice only).
	private func handleV3VideoPayloadLocked(_ payload: String) {
		guard let data = payload.data(using: .utf8),
		      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return }
		if (obj["t"] as? String) == "c", let blob = obj["d"] as? String {
			handleInboundChunkLocked(blob, which: .video)
			return
		}
		if (obj["ok"] as? Bool) == true, (obj["type"] as? String) == "voice_ready" {
			videoReady = true
			videoReopenAttempt = 0
			BeamioQALog.write("voice v3 video ready")
		}
	}

	private func scheduleV3VideoReopenLocked() {
		guard running, let live = active, live.v3 != nil else { return }
		videoReopenAttempt += 1
		let delay = min(8, pow(2, Double(videoReopenAttempt - 1)))
		videoListenGen += 1
		let vgen = videoListenGen
		queue.asyncAfter(deadline: .now() + delay) { [weak self] in
			guard let self, self.running, vgen == self.videoListenGen, !self.videoReady, let live = self.active else { return }
			self.reconnectQueue.async {
				let opened = self.openV3Sse(active: live, which: .video, gen: vgen, avoidEntry: nil)
				self.queue.async {
					guard self.running, vgen == self.videoListenGen, let opened else {
						opened?.handle.cancel()
						return
					}
					self.videoListenHandle = opened.handle
				}
			}
		}
	}

	/// 6 s after opening: a channel whose relay never answered moves to another relay.
	private func checkV3RelayLocked(_ which: V3Which, gen: Int) {
		guard running, var live = active, var v3 = live.v3 else { return }
		let ready = which == .voice ? listenReady : videoReady
		let sameGen = which == .voice ? gen == listenGen : gen == videoListenGen
		guard !ready, sameGen else { return }
		var own = which == .voice ? v3.ownVoice : v3.ownVideo
		var exclude: Set<String> = [own.relay?.ip ?? ""]
		if let mailbox = BeamioSiCipherPost.normalizeIp(BeamioChatPgpKeychain.loadMailboxIp()) { exclude.insert(mailbox) }
		let avoidArmors = [BeamioChatPgpKeychain.loadRoutePublicArmor(), live.offer.callerRouteArmored]
		guard let next = BeamioVoiceV3.RelayNodes.pick(excludeIps: exclude, excludeArmors: avoidArmors) else { return }
		BeamioQALog.write("voice v3 \(which) relay \(own.relay?.domain ?? "-") did not answer; moving to \(next.domain)")
		own.relay = next
		if which == .voice { v3.ownVoice = own } else { v3.ownVideo = own }
		live.v3 = v3
		active = live
		BeamioNativeVoiceSignaling.updateV3Call(callId: live.offer.callId, v3: v3)
		// The callee's relays were in the accept; the caller's go out in channel ready.
		// A ready on its way carries the old relay: announce again too.
		if live.role == .callee || v3ReadySent || v3ReadyInFlight { v3OwnRelayMoved = true }
		if which == .voice {
			listenHandle?.cancel()
			listenHandle = nil
			listenGen += 1
		} else {
			videoListenHandle?.cancel()
			videoListenHandle = nil
			videoListenGen += 1
		}
		let newGen = which == .voice ? listenGen : videoListenGen
		reconnectQueue.async { [weak self] in
			guard let self else { return }
			let opened = self.openV3Sse(active: live, which: which, gen: newGen, avoidEntry: nil)
			self.queue.async {
				guard self.running, let opened else { opened?.handle.cancel(); return }
				if which == .voice, newGen == self.listenGen {
					self.listenHandle = opened.handle
					self.listenEntryIp = opened.entryIp
				} else if which == .video, newGen == self.videoListenGen {
					self.videoListenHandle = opened.handle
				} else {
					opened.handle.cancel()
				}
			}
		}
	}

	/// Caller: as soon as our relays are chosen, tell the callee where our
	/// channels are (control chunk on its voice channel). We do not wait for our
	/// own listen: the callee builds its route and encryption meanwhile, and posts
	/// that reach the relay before our channel exists are retried by the callee
	/// (`postRetryingUntilPeerChannel`). Either side: again after a relay move,
	/// once the new listen is up. Retried every 300 ms for 10 s.
	private func maybeSendV3ChannelReadyLocked() {
		guard running, let live = active, let v3 = live.v3, !v3ReadyInFlight else { return }
		let firstFromCaller = live.role == .dialer && !v3ReadySent && !v3OwnRelayMoved
		guard listenReady || firstFromCaller else { return }
		let due = firstFromCaller || v3OwnRelayMoved
		guard due, v3.peerVoice.relay != nil, let voiceRelay = v3.ownVoice.relay, let videoRelay = v3.ownVideo.relay else { return }
		guard let route = uplinkRoute else {
			resolveUplinkRouteIfNeeded(peer: live.peerEoa.lowercased(), callId: live.offer.callId)
			queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.maybeSendV3ChannelReadyLocked() }
			return
		}
		let body = BeamioVoiceV3.channelReadyBody(callId: live.offer.callId, voice: voiceRelay, video: videoRelay)
		guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
		v3ReadyInFlight = true
		let deadline = Date().addingTimeInterval(10)
		var tries = 0
		func attempt() {
			guard running, let current = active, current.offer.callId == live.offer.callId else {
				v3ReadyInFlight = false
				return
			}
			tries += 1
			guard let entryIp = route.entries.next() else {
				v3ReadyInFlight = false
				return
			}
			buildUplinkArmorLocked(
				active: current, route: route, plain: data, kind: .control,
				seq: 0, captureMs: Int64(Date().timeIntervalSince1970 * 1000)
			) { [weak self] armor, _ in
				guard let self else { return }
				guard let armor else {
					self.queue.async { self.v3ReadyInFlight = false }
					return
				}
				self.uplinkPostQueue.async {
					let outcome = Self.postDirect(armor: armor, ip: entryIp)
					self.noteEntryOutcome(outcome, ip: entryIp, route: route)
					self.queue.async {
						if outcome.ok {
							self.v3ReadySent = true
							// A relay that moved while this ready was on its way is announced
							// again once its new listen is up.
							let now = self.active?.v3
							let stale = now?.ownVoice.relay?.domain != voiceRelay.domain
								|| now?.ownVideo.relay?.domain != videoRelay.domain
							self.v3OwnRelayMoved = stale
							self.v3ReadyInFlight = false
							BeamioCallTiming.mark("channel-ready-sent")
							BeamioQALog.write("voice v3 channel ready sent tries=\(tries)")
							if stale { self.maybeSendV3ChannelReadyLocked() }
							return
						}
						if self.running, Date() < deadline {
							self.queue.asyncAfter(deadline: .now() + 0.3) { attempt() }
						} else {
							self.v3ReadyInFlight = false
							BeamioQALog.write("voice v3 channel ready not delivered note=\(outcome.note)")
						}
					}
				}
			}
		}
		attempt()
	}

	/// The peer reports (or moves) its relays. Runs on `queue`.
	private func applyV3PeerRelaysLocked(_ json: [String: Any]) {
		guard var live = active, var v3 = live.v3, (json["callId"] as? String) == live.offer.callId else { return }
		let relays = BeamioVoiceV3.relays(fromReady: json)
		let first = v3.peerVoice.relay == nil
		if let r = relays.voice { v3.peerVoice.relay = r }
		if let r = relays.video { v3.peerVideo.relay = r }
		live.v3 = v3
		active = live
		BeamioNativeVoiceSignaling.updateV3Call(callId: live.offer.callId, v3: v3)
		BeamioCallTiming.mark("channel-ready-rx")
		BeamioQALog.write("voice v3 peer relays voice=\(relays.voice?.domain ?? "-") video=\(relays.video?.domain ?? "-") first=\(first)")
		// Entries must avoid the new relays: rebuild the route.
		uplinkRoute = nil
		uplinkRouteResolving = false
		resolveUplinkRouteIfNeeded(peer: live.peerEoa.lowercased(), callId: live.offer.callId)
		maybeSendV3ChannelReadyLocked()
	}

	/// `voice_unlisten` for one own v3 channel, to its relay. Blocking.
	private static func postV3Unlisten(_ own: BeamioVoiceV3.Own) {
		guard let relay = own.relay else { return }
		let command: [String: Any] = [
			"command": "voice_unlisten",
			"sessionId": own.channel.sid,
			"timestamp": Int(Date().timeIntervalSince1970),
		]
		guard let data = try? JSONSerialization.data(withJSONObject: command) else { return }
		let sem = DispatchSemaphore(value: 0)
		var armorOut: String?
		BeamioOpenPgpHost.shared.encrypt(plaintext: data.base64EncodedString(), publicKeyArmor: relay.armor) { result in
			armorOut = try? result.get()
			sem.signal()
		}
		_ = sem.wait(timeout: .now() + 8)
		guard let armor = armorOut, armor.contains("BEGIN PGP MESSAGE") else { return }
		var exclude: Set<String> = []
		if let ip = BeamioSiCipherPost.normalizeIp(relay.ip) { exclude.insert(ip) }
		if let mailbox = BeamioSiCipherPost.normalizeIp(BeamioChatPgpKeychain.loadMailboxIp()) { exclude.insert(mailbox) }
		let posted = BeamioSiCipherPost.post(armor: armor, nodes: BeamioChatPgpKeychain.loadSiNodes(), excludeIps: exclude, maxAttempts: 3, timeout: 8)
		BeamioQALog.write("voice v3 unlisten session=\(own.channel.sid.prefix(8)) ok=\(posted.ok)")
	}

	/// Entry exclusions for v3 frames: both mailboxes and all four relays.
	private func v3UplinkExcludes(_ live: BeamioNativeVoiceSignaling.ActiveCall) -> Set<String> {
		var out: Set<String> = []
		if let mailbox = BeamioSiCipherPost.normalizeIp(BeamioChatPgpKeychain.loadMailboxIp()) { out.insert(mailbox) }
		guard let v3 = live.v3 else { return out }
		for relay in [v3.ownVoice.relay, v3.ownVideo.relay, v3.peerVoice.relay, v3.peerVideo.relay] {
			if let ip = BeamioSiCipherPost.normalizeIp(relay?.ip ?? "") { out.insert(ip) }
		}
		let norm = { (s: String) in s.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
		let peerRoute = norm(live.role == .callee ? live.offer.callerRouteArmored : (BeamioAddressPgp.searchKey(address: live.peerEoa)?.routePublicKeyArmored ?? ""))
		if !peerRoute.isEmpty {
			for r in BeamioVoiceV3.RelayNodes.all() where norm(r.armor) == peerRoute { out.insert(r.ip) }
		}
		return out
	}

	/// v3 Hang Up: an AES `voice_end_v1` on the peer's voice channel. Blocking.
	/// The current call's uplink entries, fastest first (already connected, so a
	/// control frame posted there skips a cold connection). Any thread.
	func warmEntriesForControl() -> [String] {
		warmEntriesLock.lock()
		let pool = warmEntriesRef
		warmEntriesLock.unlock()
		return pool?.fastestFirst() ?? []
	}

	static func postV3Control(
		_ body: [String: Any],
		call v3: BeamioVoiceV3.Call,
		preferredEntries: [String] = []
	) -> Bool {
		guard let armor = sealV3ControlArmor(body, call: v3) else { return false }
		return postV3ControlArmor(armor, call: v3, preferredEntries: preferredEntries)
	}

	/// One control frame for the peer's voice channel, sealed and encrypted to its
	/// relay. Blocking (the encrypt runs on the shared route-PGP WebView).
	/// `seq` nil takes the next uplink seq. A frame built ahead of time passes 0:
	/// both receivers act on `voice_end_v1` whatever its seq, and an old seq does
	/// not leave a gap the peer's jitter buffer would wait on.
	static func sealV3ControlArmor(_ body: [String: Any], call v3: BeamioVoiceV3.Call, seq: Int? = nil) -> String? {
		guard let relay = v3.peerVoice.relay, let loc = v3.peerVoice.channel.locator,
		      let key = try? BeamioVoiceAesGcm.keyFromBase64(v3.peerVoice.channel.keyB64),
		      let data = try? JSONSerialization.data(withJSONObject: body),
		      let literal = try? BeamioVoiceChannelV2.sealChunk(
		      	sessionKey: key, peer: .init(locator: loc, writeKey: v3.peerVoice.channel.wk),
		      	kind: .control, seq: seq ?? shared.takeUplinkSeq(), captureMs: Int64(Date().timeIntervalSince1970 * 1000), frameId: 0, data: data
		      )
		else { return nil }
		let sem = DispatchSemaphore(value: 0)
		var armorOut: String?
		BeamioVoiceRoutePgp.shared.encryptBinary(literal, routeArmor: relay.armor) { result in
			armorOut = try? result.get()
			sem.signal()
		}
		_ = sem.wait(timeout: .now() + 8)
		return armorOut
	}

	/// Post a sealed control frame (see `sealV3ControlArmor`).
	static func postV3ControlArmor(
		_ armor: String,
		call v3: BeamioVoiceV3.Call,
		preferredEntries: [String] = []
	) -> Bool {
		var exclude: Set<String> = []
		for r in [v3.ownVoice.relay, v3.ownVideo.relay, v3.peerVoice.relay, v3.peerVideo.relay] {
			if let ip = BeamioSiCipherPost.normalizeIp(r?.ip ?? "") { exclude.insert(ip) }
		}
		if let mailbox = BeamioSiCipherPost.normalizeIp(BeamioChatPgpKeychain.loadMailboxIp()) { exclude.insert(mailbox) }
		// Warm entries first, then random ones; never a relay or our mailbox.
		var candidates: [String] = []
		for ip in preferredEntries {
			guard let n = BeamioSiCipherPost.normalizeIp(ip), !exclude.contains(n), !candidates.contains(n) else { continue }
			candidates.append(n)
			if candidates.count == 2 { break }
		}
		var skip = exclude.union(candidates)
		while candidates.count < 3,
		      let node = BeamioSiCipherPost.getRandomNode(nodes: BeamioChatPgpKeychain.loadSiNodes(), excludeIps: skip)
		{
			candidates.append(node.ip)
			skip.insert(node.ip)
		}
		return postHedged(armor: armor, candidates: candidates, hedgeAfter: 0.5)
	}

	/// Post to the first entry; when it has not answered within `hedgeAfter` (or
	/// failed), also post to the next one. The first success wins. Only Hang Up
	/// uses this: a second copy of `voice_end_v1` just ends a call already ending.
	private static func postHedged(armor: String, candidates: [String], hedgeAfter: TimeInterval) -> Bool {
		guard !candidates.isEmpty else { return false }
		let lock = NSLock()
		var finished = 0
		var succeeded = false
		let done = DispatchSemaphore(value: 0)
		func launch(_ ip: String) {
			DispatchQueue.global(qos: .userInitiated).async {
				let ok = postDirect(armor: armor, ip: ip).ok
				lock.lock()
				finished += 1
				if ok { succeeded = true }
				lock.unlock()
				done.signal()
			}
		}
		func state() -> (ok: Bool, finished: Int) {
			lock.lock(); defer { lock.unlock() }
			return (succeeded, finished)
		}
		var launched = 0
		for ip in candidates {
			launch(ip)
			launched += 1
			let hedgeAt = DispatchTime.now() + hedgeAfter
			while done.wait(timeout: hedgeAt) == .success {
				let st = state()
				if st.ok { return true }
				if st.finished == launched { break }
			}
		}
		while state().finished < launched {
			if done.wait(timeout: .now() + 6) == .timedOut { break }
			if state().ok { return true }
		}
		return state().ok
	}

	// MARK: - voice_listen SSE

	private func pickEntryIp(nodes: [BeamioChatPgpKeychain.SiNode], exclude: Set<String>) -> String? {
		// getRandomNode takes a warm entry from the SDK pool first (no probe here).
		return BeamioSiCipherPost.getRandomNode(nodes: nodes, excludeIps: exclude)?.ip
	}

	/// One SSE event. `postSse` already split the stream and joined the `data:` lines.
	private func handleSsePayload(_ payload: String) {
		guard !payload.isEmpty,
		      let jsonData = payload.data(using: .utf8),
		      let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
		else {
			BeamioQALog.write("voice sse non-json len=\(payload.count)")
			return
		}
		if obj["ok"] as? Bool == false {
			BeamioQALog.write("voice sse error \(obj["error"] as? String ?? "?")")
		}
		// The SI handshake is `voice_ready` with `ok: true` and no `kind`, so each
		// test stands alone (an `if let kind` here hid the handshake, and v2 with it).
		if (obj["ok"] as? Bool) == true {
			NSLog("[BeamioNativeVoiceChannel] listen handshake ok listen=%d", Self.intValue(obj["listen"]) ?? 0)
			BeamioQALog.write("voice v3 voice ready listen=\(Self.intValue(obj["listen"]) ?? 0) capsSent=\(capsSent)")
			listenReady = true
			listenAlive = true
			maybeSendV3ChannelReadyLocked()
			return
		}
		if (obj["t"] as? String) == "c", let blob = obj["d"] as? String {
			// A chunk is a peer frame for the link watchdog too.
			noteRxLocked()
			handleInboundChunkLocked(blob, which: .voice)
		}
	}

	/// v2 chunk on our own channel: AES with AAD = CVC2 ‖ our locator; seq and
	/// capture time come from the encrypted header.
	private func handleInboundChunkLocked(_ blobB64: String, which: V3Which) {
		guard let active, running, let blob = Data(base64Encoded: blobB64) else { return }
		guard let v3 = active.v3 else { return }
		let own = which == .video ? v3.ownVideo.channel : v3.ownVoice.channel
		guard let loc = own.locator else { return }
		do {
			let key = try BeamioVoiceAesGcm.keyFromBase64(own.keyB64)
			let opened = try BeamioVoiceChannelV2.openChunk(sessionKey: key, ownLocator: loc, blob: blob)
			if opened.kind == BeamioVoiceChannelV2.Kind.control.rawValue,
			   let json = try? JSONSerialization.jsonObject(with: opened.data) as? [String: Any],
			   (json["type"] as? String) == "voice_channel_ready_v3"
			{
				applyV3PeerRelaysLocked(json)
				return
			}
			v2RxChunks += 1
			if v2RxChunks == 1 {
				NSLog("[BeamioNativeVoiceChannel] first v2 chunk rx kind=%d", opened.kind)
				BeamioQALog.write("voice v2 first chunk rx kind=\(opened.kind)")
			}
			handleInboundPlainLocked(opened.data, active: active, seq: opened.seq, senderTs: opened.captureMs)
		} catch {
			NSLog("[BeamioNativeVoiceChannel] v2 chunk open fail %@", error.localizedDescription)
			BeamioQALog.write("voice v2 chunk open fail \(error.localizedDescription)")
		}
	}

	/// One decrypted frame (v1 payload or v2 chunk data). Runs on `queue`.
	private func handleInboundPlainLocked(
		_ plain: Data,
		active: BeamioNativeVoiceSignaling.ActiveCall,
		seq frameSeq: Int?,
		senderTs: Int64
	) {
		do {
			if let json = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
			   let type = json["type"] as? String
			{
				NSLog("[BeamioNativeVoiceChannel] control frame type=%@ role=%@", type, active.role.rawValue)
				// Control frames share the media seq counter; mark the slot so the
				// jitter buffer does not wait on it.
				if active.mediaEnabled, let seq = frameSeq {
					enqueueRxMedia(seq: seq, plain: Data(), senderTs: 0, controlSlot: true)
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
			if let seq = frameSeq, seq >= Self.videoSeqBase {
				handleSplitVideoLocked(plain)
				return
			}
			enqueueRxMedia(seq: frameSeq, plain: plain, senderTs: senderTs)
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

	/// Route-PGP for call frames: the dedicated encryptor.
	private func routeEncrypt(
		plaintext: String,
		routeArmor: String,
		completion: @escaping (Result<String, Error>) -> Void
	) {
		BeamioVoiceRoutePgp.shared.encrypt(plaintext: plaintext, routeArmor: routeArmor, completion: completion)
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
		let mode = videoSplitSeq ? "v2" : "v1"
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

	/// The entry pool for this call's frames. Resolved once per call (and again
	/// when relays change): the entry pick probes over the network, so it may
	/// not sit on the per-frame path.
	private func resolveUplinkRouteIfNeeded(peer: String, callId: String) {
		guard !uplinkRouteResolving else { return }
		uplinkRouteResolving = true
		let v3Live: BeamioNativeVoiceSignaling.ActiveCall? = active?.v3 != nil ? active : nil
		uplinkPostQueue.async { [weak self] in
			var resolved: UplinkRoute?
			if let live = v3Live, let self {
				// Frames go to the peer's relays (sealed per chunk); here only the
				// entry pool, never a mailbox or one of the call's relays.
				let nodes = BeamioChatPgpKeychain.loadSiNodes()
				let exclude = self.v3UplinkExcludes(live)
				// Warm entry from the SDK pool: the first frame goes out without a probe.
				if let first = BeamioSiCipherPost.getRandomNode(nodes: nodes, excludeIps: exclude)?.ip {
					resolved = UplinkRoute(
						routePublicKeyArmor: live.v3?.peerVoice.relay?.armor ?? "",
						nodes: nodes,
						exclude: exclude,
						entries: BeamioEntryRotation(first: first)
					)
				}
			}
			if let resolved { self?.refillEntries(resolved) }
			self?.queue.async {
				guard let self, self.running, self.active?.offer.callId == callId else { return }
				self.uplinkRoute = resolved
				self.uplinkRouteResolving = false
				if let resolved {
					self.warmEntriesLock.lock()
					self.warmEntriesRef = resolved.entries
					self.warmEntriesLock.unlock()
				}
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

	typealias PostOutcome = (ok: Bool, status: Int, ms: Int, note: String)
	static let peerChannelWaitSeconds: TimeInterval = 3
	static let peerChannelRetryGap: TimeInterval = 0.15

	/// The caller sends `channel ready` before its own listen is up, so our first
	/// frames can reach the relay before the caller's channel exists. The relay
	/// keeps nothing and answers `target_voice_session_not_found`. Until the first
	/// frame of this call is accepted, such a frame is posted again to the same
	/// entry every 150 ms for up to 3 s. After that the old rule holds: a late
	/// frame is dropped. Pure (inputs injected) for the unit test.
	static func postRetryingUntilPeerChannel(
		seenBefore: Bool,
		waitSeconds: TimeInterval = peerChannelWaitSeconds,
		gap: TimeInterval = peerChannelRetryGap,
		post: () -> PostOutcome,
		sleep: (TimeInterval) -> Void,
		now: () -> Date
	) -> (outcome: PostOutcome, tries: Int) {
		var outcome = post()
		var tries = 1
		guard !seenBefore else { return (outcome, tries) }
		let deadline = now().addingTimeInterval(waitSeconds)
		while !outcome.ok, outcome.note == "target_voice_session_not_found", now() < deadline {
			sleep(gap)
			outcome = post()
			tries += 1
		}
		return (outcome, tries)
	}

	/// `postDirect` with the start-of-call wait for the peer's channel. Blocking.
	private func postAwaitingPeerChannel(armor: String, ip: String) -> PostOutcome {
		let r = Self.postRetryingUntilPeerChannel(
			seenBefore: peerChannelSeen.get(),
			post: { Self.postDirect(armor: armor, ip: ip) },
			sleep: { Thread.sleep(forTimeInterval: $0) },
			now: { Date() }
		)
		if r.outcome.ok, !peerChannelSeen.setTrue(), r.tries > 1 {
			BeamioQALog.write("voice peer channel up after tries=\(r.tries)")
		}
		return r.outcome
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
			BeamioEntryPool.shared.reportFailure(ip: ip)
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
		guard let entryIp = route.entries.next() else { return }
		uplinkInFlight += 1
		let encStarted = Date()
		buildUplinkArmorLocked(
			active: active, route: route, plain: framed, kind: .audio,
			seq: seq, captureMs: Int64(Date().timeIntervalSince1970 * 1000)
		) { [weak self] armor, usedV2 in
			guard let self else { return }
			guard let armor else {
				self.queue.async { self.uplinkInFlight = max(0, self.uplinkInFlight - 1) }
				return
			}
			let wireBytes = armor.utf8.count
			let encMs = Int(Date().timeIntervalSince(encStarted) * 1000)
			self.stats.update {
				$0.audioTx += 1
				$0.audioTxWireBytes += wireBytes
			}
			// Network I/O is blocking; keep it off the OpenPGP callback thread.
			self.uplinkPostQueue.async {
				let outcome = self.postAwaitingPeerChannel(armor: armor, ip: entryIp)
				self.noteEntryOutcome(outcome, ip: entryIp, route: route)
				self.queue.async {
					let i = usedV2 ? 1 : 0
					self.audioTally[i].n += 1
					if !outcome.ok { self.audioTally[i].fail += 1 }
					self.audioTally[i].bytes += wireBytes
					self.audioTally[i].encMs += encMs
					self.audioTally[i].postMs += outcome.ms
					self.audioTally[i].postMax = max(self.audioTally[i].postMax, outcome.ms)
					self.uplinkInFlight = max(0, self.uplinkInFlight - 1)
					self.noteV2OutcomeLocked(outcome, usedV2: usedV2)
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

	/// Healthy entries, lowest average post time first (unmeasured ones last).
	func fastestFirst() -> [String] {
		lock.lock(); defer { lock.unlock() }
		return healthy.sorted { (latencyEwma[$0] ?? .greatestFiniteMagnitude) < (latencyEwma[$1] ?? .greatestFiniteMagnitude) }
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

/// A lock-protected Bool for flags read on the post queue.
private final class PeerChannelFlag: @unchecked Sendable {
	private let lock = NSLock()
	private var value = false
	func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
	func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
	/// Sets the flag; returns the value it had before.
	func setTrue() -> Bool { lock.lock(); defer { lock.unlock() }; let old = value; value = true; return old }
}
