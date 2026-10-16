import AVFoundation
import CallKit
import Foundation
import PushKit
import UIKit

/// Shared CallKit + PushKit owner. Must start in `AppDelegate.didFinishLaunching`
/// so VoIP pushes can `reportNewIncomingCall` when the app was force-quit
/// (WebView / CashTreesWebCoordinator may not exist yet — same idea as Android
/// MessagingService → IncomingCallActivity).
final class BeamioCallKitManager: NSObject, CXProviderDelegate {
	private struct AudioSessionSnapshot {
		let category: AVAudioSession.Category
		let mode: AVAudioSession.Mode
		let options: AVAudioSession.CategoryOptions
	}

	private var provider: CXProvider
	private let controller = CXCallController()
	private struct CallIdentity {
		let callId: String
		let sessionId: String
		/// First-report CallKit handle (opaque `"Beamio"`). Kept for Answer gating.
		let displayHandle: String
		/// True after Keychain PGP decrypt applied @tag + short address.
		var verifiedIdentityApplied: Bool = false
	}
	private var callIds: [UUID: CallIdentity] = [:]
	/// UUIDs that have already been Answered. Unanswered `CXEndCallAction` is
	/// Decline (must emit `callRejected` so the dialer stops ringing); answered
	/// End is Hang Up (`callEnded`). Matches Android Decline → `callRejected`.
	private var answeredCallUUIDs: Set<UUID> = []
	/// Answered UUID waiting for CallKit `didActivate` before notifying PWA
	/// (getUserMedia / WebRTC must not race the system in-call layout).
	private var pendingMediaStartUUID: UUID?
	private var audioSessionBeforeCall: AudioSessionSnapshot?
	/// Last successfully reported CallKit callId (debug-answer default).
	private(set) var lastReportedCallId: String = ""
	var onAction: ((String, String, String) -> Void)?

	override init() {
		provider = CXProvider(configuration: Self.makeConfiguration())
		super.init()
		provider.setDelegate(self, queue: .main)
	}

	/// Drop a stale CXProvider (old icon / dual-handle chrome) and build a
	/// fresh one before the next Incoming. CallKit can keep a previous call's
	/// identity across process death when the UUID is reused.
	///
	/// B35: waits for zombie `CXEndCallAction` to finish (or timeout) before
	/// invalidating, then settles briefly so InCallService releases dual-header
	/// chrome before the next `reportNewIncomingCall`.
	func recreateProvider(completion: (() -> Void)? = nil) {
		NSLog("[BeamioCallKit] recreateProvider — end zombies, then invalidate + new CXProvider")
		// End FIRST while the provider is still valid. Invalidating before
		// CXEndCallAction leaves lock-screen dual-header chrome (EOA + @tag)
		// stuck with a piled Speaker/Mute/End grid.
		endZombieCalls(except: nil) { [weak self] in
			guard let self else {
				DispatchQueue.main.async { completion?() }
				return
			}
			self.provider.invalidate()
			self.callIds.removeAll()
			self.answeredCallUUIDs.removeAll()
			self.pendingMediaStartUUID = nil
			self.lastReportedCallId = ""
			self.provider = CXProvider(configuration: Self.makeConfiguration())
			self.provider.setDelegate(self, queue: .main)
			// Extra settle so system CallKit chrome releases before report.
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
				completion?()
			}
		}
	}

	/// Device QA: `beamio://debug-end-all` — tear down every CallKit call the
	/// system still holds (including pre-install dual-identity zombies).
	func endAllCallsForDebug() {
		NSLog("[BeamioCallKit] debug-end-all")
		recreateProvider(completion: nil)
	}

	/// Audio-only CallKit chrome.
	/// Prefer `iconTemplateImageData = nil` (system default). Custom masks that
	/// are not true white-alpha templates make FaceTime show "?" and, together
	/// with dual-identity headers, collapse the bottom Speaker/Mute/End grid
	/// into a corner pile on SE.
	private static func makeConfiguration() -> CXProviderConfiguration {
		// iOS 14+: use default init (localizedName initializer is deprecated).
		let configuration = CXProviderConfiguration()
		configuration.supportsVideo = false
		configuration.maximumCallsPerCallGroup = 1
		configuration.maximumCallGroups = 1
		configuration.supportedHandleTypes = [.generic]
		// Intentionally nil — custom PNG templates have repeatedly broken
		// post-answer chrome (FaceTime "?" + piled controls) on SE.
		configuration.iconTemplateImageData = nil
		if #available(iOS 11.0, *) {
			configuration.includesCallsInRecents = false
		}
		return configuration
	}

	/// Opaque first-report label (PushKit deadline). Verified identity is
	/// applied later via `updateVerifiedIdentity` (@tag + short address).
	private static func callKitDisplayLabel(_ raw: String) -> String {
		_ = raw
		return "Beamio"
	}

	/// Product (ratified): larger `@beamioTag` as `localizedCallerName`,
	/// smaller short address as `remoteHandle`. First report stays opaque
	/// `"Beamio"` so PushKit can complete within Apple's deadline.
	private static func makeVerifiedIdentityUpdate(tag: String, shortAddress: String) -> CXCallUpdate {
		let update = CXCallUpdate()
		let short = shortAddress.trimmingCharacters(in: .whitespacesAndNewlines)
		let rawTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
		let name: String = {
			if rawTag.isEmpty { return short.isEmpty ? "Beamio" : short }
			return rawTag.hasPrefix("@") ? rawTag : "@\(rawTag)"
		}()
		update.remoteHandle = CXHandle(
			type: .generic,
			value: short.isEmpty ? "Beamio" : short
		)
		update.localizedCallerName = name
		update.hasVideo = false
		update.supportsHolding = true
		update.supportsGrouping = false
		update.supportsUngrouping = false
		update.supportsDTMF = true
		return update
	}

	/// `0x…`, ASCII `...`, unicode `…`, or short hex capsules like `81ae…5940`.
	private static func looksLikeAddressCapsule(_ raw: String) -> Bool {
		let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		if s.isEmpty { return false }
		let lower = s.lowercased()
		if lower.hasPrefix("0x") { return true }
		if s.contains("...") || s.contains("…") { return true }
		// Sanitized short hex left after stripping ellipsis (e.g. 81ae5940).
		let hexOnly = s.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
		if hexOnly, (6...12).contains(s.count) { return true }
		return false
	}

	/// Letters / digits / underscore / hyphen only; max 18 chars.
	private static func sanitizeCallKitToken(_ raw: String) -> String {
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
		let filtered = String(raw.unicodeScalars.filter { allowed.contains($0) })
		if filtered.isEmpty { return "" }
		if filtered.count <= 18 { return filtered }
		return String(filtered.prefix(18))
	}

	private static func makeAudioOnlyUpdate(displayHandle: String) -> CXCallUpdate {
		let update = CXCallUpdate()
		let display = callKitDisplayLabel(displayHandle)
		// Compact CallKit (SE) draws `remoteHandle` on the leading edge and
		// `localizedCallerName` on the trailing edge of the SAME header row.
		// Setting BOTH — even to the identical string — still allocates two
		// columns and piles Speaker/Mute/End. Only set the handle; CallKit
		// uses it as the single title when localizedCallerName is nil.
		update.remoteHandle = CXHandle(type: .generic, value: display)
		update.localizedCallerName = nil
		update.hasVideo = false
		// Holding must stay enabled for CallKit's connected UI; forcing false
		// has been linked to broken post-answer chrome on some iOS versions.
		update.supportsHolding = true
		update.supportsGrouping = false
		update.supportsUngrouping = false
		// Keypad is part of the standard audio CallKit grid; claiming
		// supportsDTMF=false while chrome still draws Keypad has been linked
		// to piled controls on some iOS builds.
		update.supportsDTMF = true
		return update
	}

	/// End leftover answered/ringing calls so a new Incoming does not stack a
	/// broken mini control strip on top of the banner / full-screen UI.
	/// Also ends calls still known to the **system** `CXCallObserver` (e.g.
	/// after kill/reinstall when our in-memory map is empty but CallKit still
	/// holds a previous UUID with EOA/@tag dual identity).
	///
	/// Prefer `CXEndCallAction` — `reportCall(endedAt:)` alone often leaves the
	/// answered dual-identity chrome on the lock screen after install-over.
	///
	/// B35: `completion` fires on the main queue after all end transactions
	/// finish, or after a 1.0s timeout — whichever first (once only).
	private func endZombieCalls(except keep: UUID? = nil, completion: (() -> Void)? = nil) {
		var uuids = Set<UUID>()
		for uuid in callIds.keys where uuid != keep {
			uuids.insert(uuid)
		}
		for call in controller.callObserver.calls {
			if call.uuid == keep { continue }
			if call.hasEnded { continue }
			uuids.insert(call.uuid)
		}
		guard !uuids.isEmpty else {
			DispatchQueue.main.async { completion?() }
			return
		}
		let group = DispatchGroup()
		var finished = false
		let finishOnce: () -> Void = {
			guard !finished else { return }
			finished = true
			DispatchQueue.main.async { completion?() }
		}
		for uuid in uuids {
			NSLog("[BeamioCallKit] end zombie uuid=%@", uuid.uuidString)
			group.enter()
			let end = CXEndCallAction(call: uuid)
			controller.request(CXTransaction(action: end)) { [weak self] error in
				if let error {
					NSLog(
						"[BeamioCallKit] CXEndCallAction failed uuid=%@ err=%@ — reportCall fallback",
						uuid.uuidString,
						error.localizedDescription
					)
					self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
				}
				group.leave()
			}
			// Tear down chrome immediately; do not wait for the async transaction.
			provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
			answeredCallUUIDs.remove(uuid)
			if pendingMediaStartUUID == uuid {
				pendingMediaStartUUID = nil
			}
			callIds.removeValue(forKey: uuid)
		}
		group.notify(queue: .main) { finishOnce() }
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { finishOnce() }
	}

	/// Apple WWDC16 / Speakerbox: set category+mode **before** Answer
	/// `fulfill()`. Do **not** `setActive` here — CallKit activates at elevated
	/// priority and then calls `didActivate`. Activating early (or again in
	/// `didActivate`) fights CallKit and breaks the system in-call layout.
	/// Do **not** set `.defaultToSpeaker` — CallKit owns the Speaker button;
	/// fighting that route also corrupts the control grid.
	private func configureAudioSessionForCall() {
		let session = AVAudioSession.sharedInstance()
		if audioSessionBeforeCall == nil {
			audioSessionBeforeCall = AudioSessionSnapshot(
				category: session.category,
				mode: session.mode,
				options: session.categoryOptions
			)
		}
		do {
			try session.setCategory(
				.playAndRecord,
				mode: .voiceChat,
				options: [.allowBluetoothHFP]
			)
			NSLog("[BeamioCallKit] audio session configured (CallKit will activate)")
		} catch {
			NSLog("[BeamioCallKit] audio configure failed: %@", error.localizedDescription)
		}
	}

	/// Report (or refresh) an incoming CallKit call.
	/// - Parameter completion: Always invoked on the main queue after the
	///   `reportNewIncomingCall` completion (or immediately on update path).
	///   PushKit **must** wait for this before calling its own `completion()`.
	func reportIncoming(
		callId: String,
		handle: String,
		sessionId: String = "",
		completion: ((Error?) -> Void)? = nil
	) {
		let display = Self.callKitDisplayLabel(handle)
		if let existing = callIds.first(where: { matches($0.value, callId: callId, sessionId: sessionId) }) {
			// CRITICAL: never change CallKit remoteHandle / localizedCallerName after
			// the first report. VoIP often reports short EOA first, then PWA refreshes
			// with @BeamioTag — iOS keeps BOTH strings in the in-call header and the
			// bottom control grid collapses (Speaker/Mute/End piled bottom-left).
			let locked = existing.value.displayHandle
			if display != locked {
				NSLog(
					"[BeamioCallKit] skip handle update callId=%@ uuid=%@ locked=%@ ignored=%@",
					callId,
					existing.key.uuidString,
					locked,
					display
				)
			} else {
				NSLog(
					"[BeamioCallKit] re-report same handle callId=%@ uuid=%@ handle=%@",
					callId,
					existing.key.uuidString,
					locked
				)
			}
			lastReportedCallId = callId
			DispatchQueue.main.async { completion?(nil) }
			return
		}
		// B35: ALWAYS a fresh UUID. Deterministic uuid(forCallId:) + async zombie
		// end let Answer attach to orphan dual-header chrome (EOA + @tag) with
		// Speaker/Mute/End piled bottom-left.
		let uuid = UUID()
		let update = Self.makeAudioOnlyUpdate(displayHandle: display)
		let doReport: () -> Void = { [weak self] in
			guard let self else {
				DispatchQueue.main.async { completion?(nil) }
				return
			}
			self.callIds[uuid] = CallIdentity(callId: callId, sessionId: sessionId, displayHandle: display)
			NSLog(
				"[BeamioCallKit] reportIncoming callId=%@ sessionId=%@ uuid=%@ handle=%@",
				callId,
				sessionId,
				uuid.uuidString,
				display
			)
			self.provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
				guard let self else {
					completion?(error)
					return
				}
				if let error {
					let ns = error as NSError
					NSLog(
						"[BeamioCallKit] reportIncoming FAILED callId=%@ uuid=%@ error=%@ code=%ld",
						callId,
						uuid.uuidString,
						error.localizedDescription,
						ns.code
					)
					self.callIds.removeValue(forKey: uuid)
					completion?(error)
					return
				}
				self.lastReportedCallId = callId
				NSLog("[BeamioCallKit] reportIncoming OK callId=%@ uuid=%@", callId, uuid.uuidString)
				self.suspendForFullCallKitChrome()
				completion?(nil)
			}
		}
		// Wait for zombie CXEndCallAction before report — fire-and-forget left
		// dual-identity chrome alive for the next Answer.
		endZombieCalls(except: uuid, completion: doReport)
	}

	/// After opaque PushKit report: apply verified `@tag` + short address once.
	func updateVerifiedIdentity(callId: String, sessionId: String, tag: String, shortAddress: String) {
		guard let existing = callIds.first(where: { matches($0.value, callId: callId, sessionId: sessionId) })
		else {
			NSLog("[BeamioCallKit] updateVerifiedIdentity — no active call for %@", callId)
			return
		}
		if existing.value.verifiedIdentityApplied {
			NSLog("[BeamioCallKit] updateVerifiedIdentity skip — already applied %@", callId)
			return
		}
		let update = Self.makeVerifiedIdentityUpdate(tag: tag, shortAddress: shortAddress)
		callIds[existing.key]?.verifiedIdentityApplied = true
		provider.reportCall(with: existing.key, updated: update)
		NSLog(
			"[BeamioCallKit] verified identity uuid=%@ tag=%@ short=%@",
			existing.key.uuidString,
			tag,
			shortAddress
		)
	}

	private func suspendForFullCallKitChrome() {
		DispatchQueue.main.async {
			if UIApplication.shared.applicationState == .active {
				UIApplication.shared.perform(Selector(("suspend")))
				NSLog("[BeamioCallKit] suspend after reportIncoming for full CallKit chrome")
			}
		}
	}

	func startOutgoing(callId: String, handle: String, sessionId: String = "") {
		// B35: fresh UUID + opaque "Beamio" (ignore peer/tag from bridge).
		let uuid = UUID()
		let display = Self.callKitDisplayLabel(handle)
		endZombieCalls(except: uuid) { [weak self] in
			guard let self else { return }
			self.callIds[uuid] = CallIdentity(callId: callId, sessionId: sessionId, displayHandle: display)
			self.lastReportedCallId = callId
			// Same short display for CXStartCallAction handle — never follow with a
			// reportCall(updated:) that swaps EOA↔@tag (that collapses bottom chrome).
			let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: display))
			action.isVideo = false
			self.controller.request(CXTransaction(action: action)) { [weak self] error in
				if error != nil {
					self?.callIds.removeValue(forKey: uuid)
				}
			}
		}
	}

	func end(callId: String, sessionId: String = "") {
		guard let uuid = callIds.first(where: {
			matches($0.value, callId: callId, sessionId: sessionId)
		})?.key else {
			NSLog("[BeamioCallKit] end skip — no uuid for callId=%@ sessionId=%@", callId, sessionId)
			return
		}
		NSLog("[BeamioCallKit] end request callId=%@ uuid=%@", callId, uuid.uuidString)
		controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { error in
			if let error {
				NSLog("[BeamioCallKit] end request FAILED %@", error.localizedDescription)
			}
		}
	}

	/// Device QA: programmatically Answer the ringing CallKit call
	/// (`beamio://debug-answer`) so in-call chrome can be screenshot-verified.
	/// Suspend first, then Answer while backgrounded — CallKit only shows the
	/// full Speaker/Mute/End grid when the host app is not in the foreground.
	/// Do NOT open Safari after Answer: that replaces CallKit chrome with a
	/// green status pill and prevents layout QA of the bottom button bar.
	func answer(callId: String, sessionId: String = "") {
		// ONLY answer UUIDs we reported this process (opaque "Beamio" handle).
		// Never answer orphan CXCallObserver UUIDs — install-over leftovers often
		// keep EOA/@tag dual identity; Answering them piles Speaker/Mute/End left.
		let resolvedCallId = callId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			? lastReportedCallId
			: callId.trimmingCharacters(in: .whitespacesAndNewlines)
		let uuid: UUID?
		if let mapped = callIds.first(where: {
			matches($0.value, callId: resolvedCallId, sessionId: sessionId)
		})?.key {
			uuid = mapped
		} else if let ownedRinging = callIds.first(where: { entry in
			controller.callObserver.calls.contains {
				$0.uuid == entry.key && !$0.hasEnded && !$0.hasConnected && !$0.isOutgoing
			}
		})?.key {
			uuid = ownedRinging
			NSLog(
				"[BeamioCallKit] answer via owned ringing uuid=%@ callId=%@",
				ownedRinging.uuidString,
				resolvedCallId
			)
		} else {
			// End any system orphans so the next debug-incoming is clean.
			endZombieCalls(except: nil)
			NSLog(
				"[BeamioCallKit] answer skip — no owned ringing callId=%@ sessionId=%@ last=%@ (zombies cleared)",
				callId,
				sessionId,
				lastReportedCallId
			)
			uuid = nil
		}
		guard let uuid else { return }
		if answeredCallUUIDs.contains(uuid) {
			NSLog("[BeamioCallKit] answer skip — already answered uuid=%@", uuid.uuidString)
			return
		}
		guard callIds[uuid] != nil else {
			NSLog("[BeamioCallKit] answer REFUSE — unknown uuid=%@", uuid.uuidString)
			return
		}
		NSLog("[BeamioCallKit] answer request callId=%@ uuid=%@", resolvedCallId, uuid.uuidString)
		DispatchQueue.main.async {
			UIApplication.shared.perform(Selector(("suspend")))
			NSLog("[BeamioCallKit] suspend before answer for CallKit chrome")
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
			guard let self else { return }
			guard !self.answeredCallUUIDs.contains(uuid) else { return }
			self.controller.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { error in
				if let error {
					NSLog("[BeamioCallKit] answer request FAILED %@", error.localizedDescription)
				} else {
					NSLog("[BeamioCallKit] answer request OK — stay suspended for full CallKit chrome")
				}
			}
			// Re-suspend after Answer in case iOS briefly foregrounded the host.
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
				UIApplication.shared.perform(Selector(("suspend")))
				NSLog("[BeamioCallKit] re-suspend after answer")
			}
		}
	}

	private func matches(_ identity: CallIdentity, callId: String, sessionId: String) -> Bool {
		if !callId.isEmpty, identity.callId == callId { return true }
		if !sessionId.isEmpty, identity.sessionId == sessionId { return true }
		return false
	}

	/// Deterministic UUID so re-delivery of the same callId updates one CallKit call.
	private static func uuid(forCallId callId: String) -> UUID {
		let trimmed = callId.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty { return UUID() }
		if let parsed = UUID(uuidString: trimmed) { return parsed }
		var bytes = [UInt8](repeating: 0, count: 16)
		let data = Data(trimmed.utf8)
		for (i, b) in data.enumerated() {
			bytes[i % 16] ^= b
		}
		bytes[6] = (bytes[6] & 0x0F) | 0x40 // version 4-ish
		bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
		return UUID(uuid: (
			bytes[0], bytes[1], bytes[2], bytes[3],
			bytes[4], bytes[5], bytes[6], bytes[7],
			bytes[8], bytes[9], bytes[10], bytes[11],
			bytes[12], bytes[13], bytes[14], bytes[15]
		))
	}

	func providerDidReset(_ provider: CXProvider) {
		NSLog("[BeamioCallKit] providerDidReset — clearing %d call(s)", callIds.count)
		callIds.removeAll()
		answeredCallUUIDs.removeAll()
		pendingMediaStartUUID = nil
		restoreAudioSession()
	}

	func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
		guard callIds[action.callUUID] != nil else {
			NSLog("[BeamioCallKit] Answer REFUSE unknown uuid=%@", action.callUUID.uuidString)
			action.fail()
			return
		}
		NSLog("[BeamioCallKit] Answer uuid=%@", action.callUUID.uuidString)
		answeredCallUUIDs.insert(action.callUUID)
		pendingMediaStartUUID = action.callUUID
		// Must configure AVAudioSession *before* fulfill — otherwise CallKit
		// presents the connected UI without a ready audio session and the
		// system button grid collapses (Speaker / Mute / End piled left).
		configureAudioSessionForCall()
		// Do NOT reportCall(updated:) here — mid-Answer CXCallUpdate races the
		// system connected-call layout. Do NOT emit callAnswered yet — PWA
		// getUserMedia / WebRTC must wait until didActivate.
		action.fulfill()
	}

	func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
		let identity = callIds[action.callUUID]
		let wasAnswered = answeredCallUUIDs.contains(action.callUUID)
		// Before Answer: user tapped Decline on CallKit → peer must get reject.
		// After Answer: Hang Up → local teardown only (`callEnded`).
		let bridgeAction = wasAnswered ? "callEnded" : "callRejected"
		NSLog(
			"[BeamioCallKit] End uuid=%@ callId=%@ sessionId=%@ answered=%@ → %@",
			action.callUUID.uuidString,
			identity?.callId ?? "",
			identity?.sessionId ?? "",
			wasAnswered ? "yes" : "no",
			bridgeAction
		)
		if pendingMediaStartUUID == action.callUUID {
			pendingMediaStartUUID = nil
		}
		emit(bridgeAction, action.callUUID)
		answeredCallUUIDs.remove(action.callUUID)
		callIds.removeValue(forKey: action.callUUID)
		action.fulfill()
	}

	func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
		configureAudioSessionForCall()
		provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
		emit("callStarted", action.callUUID)
		action.fulfill()
	}

	func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
		action.fulfill()
	}

	func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
		NSLog("[BeamioCallKit] timedOutPerforming %@", String(describing: type(of: action)))
		action.fulfill()
	}

	func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
		// CallKit already activated this session at elevated priority.
		// Do NOT call setActive(true) again — that races CallKit and can
		// corrupt the system in-call control layout after Answer.
		if audioSessionBeforeCall == nil {
			audioSessionBeforeCall = AudioSessionSnapshot(
				category: audioSession.category,
				mode: audioSession.mode,
				options: audioSession.categoryOptions
			)
		}
		NSLog(
			"[BeamioCallKit] didActivate category=%@ mode=%@",
			audioSession.category.rawValue,
			audioSession.mode.rawValue
		)
		// Start PWA media only after CallKit owns the audio session and has
		// finished presenting the connected UI. Delay so Speaker / Mute / End
		// finish Auto Layout before WebView getUserMedia reconfigures audio.
		guard let uuid = pendingMediaStartUUID else { return }
		pendingMediaStartUUID = nil
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
			guard let self else { return }
			guard self.answeredCallUUIDs.contains(uuid), self.callIds[uuid] != nil else { return }
			NSLog("[BeamioCallKit] emit callAnswered after didActivate uuid=%@", uuid.uuidString)
			self.emit("callAnswered", uuid)
		}
	}

	func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
		restoreAudioSession()
	}

	private func restoreAudioSession() {
		let audioSession = AVAudioSession.sharedInstance()
		let snapshot = audioSessionBeforeCall
		audioSessionBeforeCall = nil
		// Leave Bluetooth HFP so prior music/audio can resume after voiceChat.
		try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
		guard let snapshot else { return }
		try? audioSession.setCategory(snapshot.category, mode: snapshot.mode, options: snapshot.options)
	}

	private func emit(_ action: String, _ uuid: UUID) {
		guard let identity = callIds[uuid] else { return }
		onAction?(action, identity.callId, identity.sessionId)
	}
}

/// Early PushKit + CallKit bootstrap for force-quit incoming calls.
final class BeamioVoipIncomingBootstrap: NSObject, PKPushRegistryDelegate {
	static let shared = BeamioVoipIncomingBootstrap()

	let callKit = BeamioCallKitManager()
	private var voipRegistry: PKPushRegistry?
	private var started = false
	private var pendingBridgeActions: [(action: String, callId: String, sessionId: String)] = []
	private var webBridge: ((String, String, String) -> Void)?
	/// Last reported callId — suppress duplicate CallKit reports within a short window
	/// (debug-incoming re-delivery / alert+VoIP race).
	private var lastReportedCallId: String = ""
	private var lastReportedAt: Date = .distantPast
	/// Foreground custom Incoming (tag + AddressCapsule); nil when using CallKit.
	private var glassIncomingPayload: BeamioIncomingCallPayload?

	private override init() {
		super.init()
		callKit.onAction = { [weak self] action, callId, sessionId in
			self?.forwardCallKitAction(action, callId: callId, sessionId: sessionId)
		}
	}

	/// Call synchronously from `application(_:didFinishLaunchingWithOptions:)`.
	func start() {
		guard !started else { return }
		started = true
		// Drop App Store production VoIP leftovers once (invalidate). Do **not**
		// also clearVoip + tear down after install — that races PushKit didUpdate
		// and left ios_voip unregistered (force-quit CallKit never wakes).
		_ = CashTreesPushRegistration.invalidateStalePushTokensForSignedApsEnvironment()
		let reason = CashTreesPushRegistration.signedApsEnvironment() == "development"
			? "launch-dev"
			: "launch"
		installVoipRegistry(reason: reason)
		scheduleVoipTokenPoll(reason: reason)
		// Do NOT auto `endAllCallsForDebug` on launch. That raced
		// `beamio://debug-incoming` (report then 0.4s recreate wiped the
		// ringing UUID, so debug-answer hit a zombie / piled chrome).
		// QA teardown is explicit: `beamio://debug-end-all`.
		NSLog("[BeamioVoip] bootstrap started — PushKit+CallKit ready before WebView")
	}

	/// Ensure PushKit has a usable VoIP hex for PWA HTTP `ios_voip` register.
	/// Call from bindIdentity when `needsVoipCredentialRefresh`.
	///
	/// **Never** tear down a live or waiting `PKPushRegistry` — recreate wiped
	/// the waiting registry before `didUpdate`, left hex empty forever, and
	/// blocked force-quit CallKit wake (no `ios_voip` in DB).
	func forceRefreshVoipCredentials() {
		if CashTreesPushRegistration.hasLiveVoipCredentialThisProcess {
			NSLog("[BeamioVoip] forceRefresh skipped — live VoIP already minted this process")
			CashTreesPushRegistration.notifyWebOfCachedVoipTokenIfNeeded()
			return
		}
		if harvestVoipTokenFromRegistryIfAvailable(reason: "forceRefresh-poll") {
			return
		}
		// Registry already installed (start()) and waiting for didUpdate —
		// poll only; do **not** clearVoip / tear down.
		if voipRegistry != nil {
			NSLog("[BeamioVoip] forceRefresh — registry waiting, poll only (no teardown)")
			scheduleVoipTokenPoll(reason: "forceRefresh-wait")
			CashTreesPushRegistration.notifyWebOfCachedVoipTokenIfNeeded()
			return
		}
		_ = CashTreesPushRegistration.invalidateStalePushTokensForSignedApsEnvironment()
		installVoipRegistry(reason: "forceRefresh-cold")
		scheduleVoipTokenPoll(reason: "forceRefresh-cold")
	}

	private func installVoipRegistry(reason: String) {
		if let existing = voipRegistry {
			existing.desiredPushTypes = []
			existing.delegate = nil
			voipRegistry = nil
			NSLog("[BeamioVoip] torn down PushKit registry (%@)", reason)
		}
		let registry = PKPushRegistry(queue: .main)
		registry.delegate = self
		registry.desiredPushTypes = [.voIP]
		voipRegistry = registry
		NSLog("[BeamioVoip] PushKit registry installed (%@)", reason)
	}

	/// PushKit may mint the token before `didUpdate` is delivered (or after a
	/// recreate that never re-fires). Poll `pushToken(for:)` a few times.
	private func scheduleVoipTokenPoll(reason: String) {
		for delay in [0.5, 1.5, 3.0, 6.0, 12.0] {
			DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
				guard let self else { return }
				if CashTreesPushRegistration.hasLiveVoipCredentialThisProcess { return }
				_ = self.harvestVoipTokenFromRegistryIfAvailable(reason: "\(reason)+poll@\(delay)s")
			}
		}
	}

	@discardableResult
	private func harvestVoipTokenFromRegistryIfAvailable(reason: String) -> Bool {
		guard let registry = voipRegistry,
		      let data = registry.pushToken(for: .voIP),
		      !data.isEmpty
		else { return false }
		let token = data.map { String(format: "%02x", $0) }.joined()
		NSLog(
			"[BeamioVoip] harvested PushKit token via pushToken(for:) reason=%@ hex=%@…",
			reason,
			String(token.prefix(12))
		)
		CashTreesPushRegistration.handleVoipDidRegister(deviceTokenHex: token)
		return true
	}

	/// WebView coordinator registers so Answer/End reach PWA once the shell is up.
	func setWebBridge(_ bridge: ((String, String, String) -> Void)?) {
		webBridge = bridge
		guard let bridge, !pendingBridgeActions.isEmpty else { return }
		let queued = pendingBridgeActions
		pendingBridgeActions.removeAll()
		for item in queued {
			bridge(item.action, item.callId, item.sessionId)
		}
	}

	/// Alert APNs / debug-incoming: foreground glass or CallKit (no WebView wait).
	func reportFromUserInfo(_ userInfo: [AnyHashable: Any], completion: ((Error?) -> Void)? = nil) {
		let callId = (userInfo["callId"] as? String) ?? ""
		let sessionId = (userInfo["sessionId"] as? String) ?? ""
		let peerAddress = (userInfo["peerAddress"] as? String) ?? ""
		let displayName = (userInfo["displayName"] as? String) ?? "Beamio call"
		let claimedTag = (userInfo["claimedTag"] as? String) ?? ""
		let claimedAddress = (userInfo["claimedAddress"] as? String) ?? ""
		let identityWarning = (userInfo["identityWarning"] as? String) ?? ""
		guard !callId.isEmpty else {
			completion?(nil)
			return
		}
		reportIncomingCallKit(
			callId: callId,
			sessionId: sessionId,
			peerAddress: peerAddress,
			displayName: displayName,
			claimedTag: claimedTag,
			claimedAddress: claimedAddress,
			identityWarning: identityWarning,
			completion: completion
		)
	}

	/// Soft-seed / alert / PWA → glass when `.active` (shows `@tag` + AddressCapsule).
	/// PushKit must pass `requiresCallKit: true` (Apple kills apps that skip CallKit).
	func reportIncomingCallKit(
		callId: String,
		sessionId: String,
		peerAddress: String,
		displayName: String,
		claimedTag: String = "",
		claimedAddress: String = "",
		identityWarning: String = "",
		requiresCallKit: Bool = false,
		completion: ((Error?) -> Void)? = nil
	) {
		var payload = BeamioIncomingCallPayload(
			callId: callId,
			sessionId: sessionId,
			peerAddress: peerAddress,
			displayName: displayName,
			claimedTag: claimedTag,
			claimedAddress: claimedAddress,
			identityWarning: identityWarning
		)
		// Same callId within 2s → CallKit handle stays locked, but glass
		// identity (`@tag` / capsule) may still upgrade after address lookup.
		let now = Date()
		if callId == lastReportedCallId, now.timeIntervalSince(lastReportedAt) < 2 {
			NSLog("[BeamioVoip] re-report within 2s callId=%@ (handle locked)", callId)
			if BeamioIncomingCallGlassHost.isPresented {
				let apply: () -> Void = { [weak self] in
					self?.glassIncomingPayload = payload
					BeamioIncomingCallGlassHost.update(payload)
					self?.enrichGlassTagIfNeeded(payload)
					completion?(nil)
				}
				if Thread.isMainThread {
					apply()
				} else {
					DispatchQueue.main.async(execute: apply)
				}
				return
			}
		}
		lastReportedCallId = callId
		lastReportedAt = now

		let appActive = UIApplication.shared.applicationState == .active
		if !requiresCallKit && appActive {
			glassIncomingPayload = payload
			let present: () -> Void = { [weak self] in
				guard let self else {
					completion?(nil)
					return
				}
				NSLog(
					"[BeamioVoip] glass Incoming callId=%@ tag=%@ addr=%@",
					payload.callId,
					payload.titleTag,
					BeamioIncomingAddressFormat.short(payload.capsuleAddress)
				)
				BeamioIncomingCallGlassHost.present(
					payload,
					onAccept: { self.acceptGlassIncoming() },
					onDecline: { self.declineGlassIncoming() }
				)
				self.enrichGlassTagIfNeeded(payload)
				completion?(nil)
			}
			if Thread.isMainThread {
				present()
			} else {
				DispatchQueue.main.async(execute: present)
			}
			return
		}

		NSLog(
			"[BeamioVoip] CallKit report callId=%@ sessionId=%@ handle=%@ (opaque; tag=%@ PWA-only)",
			callId,
			sessionId,
			payload.callKitHandle,
			payload.titleTag
		)
		callKit.reportIncoming(
			callId: callId,
			handle: payload.callKitHandle,
			sessionId: sessionId,
			completion: completion
		)
	}

	/// When glass shows a wallet capsule but no `@tag`, resolve via exact-address search.
	private func enrichGlassTagIfNeeded(_ payload: BeamioIncomingCallPayload) {
		guard payload.titleTag.isEmpty else { return }
		let address = payload.capsuleAddress
		guard !address.isEmpty else { return }
		let callId = payload.callId
		BeamioTagAddressLookup.fetchExactTag(for: address) { [weak self] tag in
			guard let self, let tag, !tag.isEmpty else { return }
			DispatchQueue.main.async {
				guard BeamioIncomingCallGlassHost.isPresented,
				      let current = self.glassIncomingPayload ?? BeamioIncomingCallGlassHost.currentPayload,
				      current.callId == callId else { return }
				var next = current
				next.displayName = tag
				self.glassIncomingPayload = next
				BeamioIncomingCallGlassHost.update(next)
				NSLog("[BeamioVoip] glass tag enriched callId=%@ tag=%@", callId, tag)
			}
		}
	}

	/// Accept custom Incoming and forward `callAnswered` to the PWA bridge.
	func acceptGlassIncoming() {
		let payload = glassIncomingPayload ?? BeamioIncomingCallGlassHost.currentPayload
		BeamioIncomingCallGlassHost.dismiss()
		glassIncomingPayload = nil
		guard let payload else {
			NSLog("[BeamioVoip] acceptGlassIncoming — no payload")
			return
		}
		NSLog("[BeamioVoip] glass Accept callId=%@", payload.callId)
		forwardCallKitAction("callAnswered", callId: payload.callId, sessionId: payload.sessionId)
	}

	/// Decline custom Incoming and forward `callRejected` to the PWA bridge.
	func declineGlassIncoming() {
		let payload = glassIncomingPayload ?? BeamioIncomingCallGlassHost.currentPayload
		BeamioIncomingCallGlassHost.dismiss()
		glassIncomingPayload = nil
		guard let payload else {
			NSLog("[BeamioVoip] declineGlassIncoming — no payload")
			return
		}
		NSLog("[BeamioVoip] glass Decline callId=%@", payload.callId)
		forwardCallKitAction("callRejected", callId: payload.callId, sessionId: payload.sessionId)
	}

	/// Tear down glass without bridge (debug-end-all).
	func dismissGlassIncomingIfPresent() {
		guard BeamioIncomingCallGlassHost.isPresented || glassIncomingPayload != nil else { return }
		BeamioIncomingCallGlassHost.dismiss()
		glassIncomingPayload = nil
	}

	var isGlassIncomingPresented: Bool {
		BeamioIncomingCallGlassHost.isPresented || glassIncomingPayload != nil
	}

	private func forwardCallKitAction(_ action: String, callId: String, sessionId: String) {
		if let webBridge {
			webBridge(action, callId, sessionId)
			return
		}
		pendingBridgeActions.append((action, callId, sessionId))
		NSLog(
			"[BeamioVoip] queued CallKit action=%@ callId=%@ (WebView not ready)",
			action,
			callId
		)
	}

	// MARK: - PKPushRegistryDelegate

	func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
		let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
		NSLog("[BeamioVoip] PushKit didUpdate voip token=%@…", String(token.prefix(12)))
		CashTreesPushRegistration.handleVoipDidRegister(deviceTokenHex: token)
	}

	func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
		NSLog("[BeamioVoip] PushKit didInvalidate voip token")
		CashTreesPushRegistration.clearVoipDeviceToken()
		NotificationCenter.default.post(
			name: .cashTreesPushDeviceTokenUpdated,
			object: nil,
			userInfo: [
				"deviceToken": "",
				"platform": "ios_voip",
			]
		)
	}

	func pushRegistry(
		_ registry: PKPushRegistry,
		didReceiveIncomingPushWith payload: PKPushPayload,
		for type: PKPushType,
		completion: @escaping () -> Void
	) {
		BeamioGuardianRoster.kick()
		let body = payload.dictionaryPayload
		let callId = (body["callId"] as? String) ?? (body["call_id"] as? String) ?? ""
		let sessionId = (body["sessionId"] as? String) ?? (body["session_id"] as? String) ?? ""
		let peerAddress = (body["peerAddress"] as? String) ?? ""
		let displayNameRaw = (body["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let displayName: String = {
			if !displayNameRaw.isEmpty { return displayNameRaw }
			if !peerAddress.isEmpty { return peerAddress }
			return "Beamio call"
		}()
		let claimedTag = (body["claimedTag"] as? String) ?? ""
		let claimedAddress = (body["claimedAddress"] as? String) ?? ""
		NSLog(
			"[BeamioVoip] PushKit incoming type=%@ callId=%@ sessionId=%@",
			type.rawValue,
			callId,
			sessionId
		)
		let resolvedId: String
		if !callId.isEmpty {
			resolvedId = callId
		} else {
			resolvedId = UUID().uuidString
			NSLog("[BeamioVoip] PushKit missing callId — reporting fallback %@", resolvedId)
		}
		// Apple: report CallKit and wait for its completion BEFORE PushKit completion().
		// Calling PushKit completion early while app was woken by VoIP can end the call
		// or kill the process (iOS 13+ VoIP entitlement rules). Always CallKit here —
		// never glass (foreground soft-seed uses glass for @tag + AddressCapsule).
		reportIncomingCallKit(
			callId: resolvedId,
			sessionId: sessionId,
			peerAddress: peerAddress,
			displayName: displayName,
			claimedTag: claimedTag,
			claimedAddress: claimedAddress,
			requiresCallKit: true
		) { [weak self] error in
			if let error {
				NSLog(
					"[BeamioVoip] PushKit→CallKit done with error=%@ — still completing PushKit",
					error.localizedDescription
				)
			} else {
				NSLog("[BeamioVoip] PushKit→CallKit done OK — completing PushKit")
				// Opaque CallKit first (PushKit deadline). Best-effort dual identity
				// (@tag + short address) after Keychain decrypt — must not block completion().
				self?.scheduleVerifiedIdentityUpdate(callId: resolvedId, sessionId: sessionId)
			}
			NotificationCenter.default.post(
				name: .cashTreesIncomingVoiceCallPush,
				object: nil,
				userInfo: [
					"callId": resolvedId,
					"sessionId": sessionId,
					"peerAddress": peerAddress,
					"displayName": displayName,
					"claimedTag": claimedTag,
					"claimedAddress": claimedAddress,
					"fromVoip": true,
				]
			)
			completion()
		}
	}

	/// After opaque PushKit→CallKit: fetch+decrypt offerArmor → CallKit dual update.
	private func scheduleVerifiedIdentityUpdate(callId: String, sessionId: String) {
		guard !callId.isEmpty, sessionId.count >= 16 else { return }
		BeamioVoiceOfferIdentity.resolve(callId: callId, sessionId: sessionId) { [weak self] resolved in
			guard let self, let resolved else { return }
			DispatchQueue.main.async {
				self.callKit.updateVerifiedIdentity(
					callId: resolved.callId,
					sessionId: resolved.sessionId,
					tag: resolved.beamioTag,
					shortAddress: resolved.shortAddress
				)
				// If glass overlay is up (rare after PushKit), upgrade identity rows too.
				if BeamioIncomingCallGlassHost.isPresented,
				   var payload = self.glassIncomingPayload ?? BeamioIncomingCallGlassHost.currentPayload,
				   payload.callId == resolved.callId
				{
					if !resolved.beamioTag.isEmpty {
						payload.displayName = resolved.beamioTag
					}
					if !resolved.callerEoa.isEmpty {
						payload.peerAddress = resolved.callerEoa
						payload.claimedAddress = resolved.callerEoa
					}
					payload.claimedTag = resolved.beamioTag
					payload.identityWarning = ""
					self.glassIncomingPayload = payload
					BeamioIncomingCallGlassHost.update(payload)
				}
			}
		}
	}
}
