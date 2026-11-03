import AVFoundation
import Combine
import SwiftUI
import UIKit

/// The call the shell answered itself (CallKit Answer → native temporary relay).
///
/// Drives the shell `BeamioInCallScreen` (aligned layout for banner Answer and
/// lock-screen slide-to-answer). Apple requires CallKit for PushKit VoIP;
/// SpringBoard owns the full-screen connected CallKit UI after lock-screen
/// Answer and **no app window (including `alert+2`) can paint over it**. After
/// unlock / when `applicationState == .active`, product UI is ContentView’s
/// `BeamioInCallScreen` (host window is torn down so the main hierarchy is not
/// gated blank). Residual CallKit until the user leaves system chrome (or taps
/// the app name on the CallKit screen) is an OS constraint, not a shell bug.
///
/// Calls the PWA dialed keep their own PWA call screen; only shell-answered
/// calls are tracked here.
final class BeamioInCallScreenModel: ObservableObject {
	static let shared = BeamioInCallScreenModel()

	/// A shell-answered call is connected.
	@Published private(set) var live = false
	/// The call screen is on top of the WebView.
	@Published var presented = false
	/// True while the dedicated InCall `UIWindow` is showing (ContentView
	/// skips its duplicate full-screen overlay to avoid double chrome).
	@Published private(set) var externalHostActive = false
	@Published private(set) var callId = ""
	@Published private(set) var sessionId = ""
	/// Verified `@BeamioTag`; empty when the lookup has not produced one.
	@Published private(set) var tag = ""
	@Published private(set) var address = ""
	@Published private(set) var answeredAt = Date()
	/// False while an outgoing call is still ringing (dialer, before Accept).
	@Published private(set) var connected = true
	@Published private(set) var muted = false
	@Published private(set) var speakerOn = false
	/// This party pressed FaceTime and is capturing/uplinking local video.
	@Published private(set) var localVideoOn = false
	/// Peer announced FaceTime uplink (control frame) and/or we have a remote JPEG.
	@Published private(set) var remoteVideoOn = false
	@Published private(set) var remoteVideoImage: UIImage?
	/// English camera / FaceTime error; cleared on success or call end.
	@Published private(set) var videoError: String?
	@Published private(set) var videoToggleBusy = false
	/// The PWA could not place a prepared dial; shown in place of the status.
	@Published private(set) var prepareError = ""

	/// Dialer wake receipt: `.ringing` once the callee's device sends
	/// `voice_call_ringing_v1`, `.restricted` after 8 s without one (the call
	/// keeps ringing). Five rings without one end the call: `showUnreachable`.
	enum PeerWake { case waiting, ringing, restricted }
	@Published private(set) var peerWake: PeerWake = .waiting

	/// Main thread. Only for the dial on screen, and only before Accept.
	func notePeerWake(callId: String, _ wake: PeerWake) {
		guard !connected, !callId.isEmpty, self.callId == callId else { return }
		// A receipt that arrives late still wins over the 8 s notice.
		if wake == .restricted && peerWake != .waiting { return }
		if peerWake != wake { peerWake = wake }
	}

	/// The media link dropped mid-call and the shell is reopening it.
	@Published private(set) var reconnecting = false
	/// Shown for a moment before the screen closes on a lost connection.
	@Published private(set) var endNotice = ""

	/// Replaces the call timer while reconnecting or ending on a lost link.
	var statusOverride: String? {
		if !endNotice.isEmpty { return endNotice }
		if reconnecting && connected { return "Reconnecting…" }
		return nil
	}

	/// No ringing receipt after five rings: the callee's phone never got the
	/// call. Say so until the screen closes (main thread).
	func showUnreachable(callId: String) {
		guard live, !connected, callId.isEmpty || self.callId.isEmpty || self.callId == callId else { return }
		endNotice = "Unreachable"
	}

	func setReconnecting(_ on: Bool) {
		guard live || !on else { return }
		if reconnecting != on { reconnecting = on }
	}

	/// No peer frames and no accepted uplink for the limit: say why, then end
	/// the call the same way as End (hang-up signal, CallKit end, screen close).
	func connectionLost(callId: String, sessionId: String) {
		NSLog("[BeamioInCall] connection lost callId=%@", callId)
		crumb("incall-connection-lost:\(callId.prefix(8))")
		reconnecting = false
		if live {
			endNotice = "Call ended: connection lost"
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
			guard let self else { return }
			if self.live, callId.isEmpty || self.callId.isEmpty || self.callId == callId {
				self.hangUp()
			} else {
				BeamioVoipIncomingBootstrap.shared.callKit.end(callId: callId, sessionId: sessionId)
			}
		}
	}

	/// Status text before the call connects: "Connecting…" while the PWA still
	/// builds the offer, "Calling…" once the callee is being rung.
	var pendingLabel: String {
		if !prepareError.isEmpty { return prepareError }
		if isPrepared { return "Connecting…" }
		switch peerWake {
		case .ringing: return "Ringing…"
		case .restricted: return "Their phone may be restricting Beamio"
		case .waiting: return "Calling…"
		}
	}

	/// One-line status for the return pill and the collapsed bar.
	var pendingShortLabel: String {
		peerWake == .restricted && prepareError.isEmpty && !isPrepared ? "Calling…" : pendingLabel
	}

	private var surfaceRetryWorkItems: [DispatchWorkItem] = []
	private var surfaceForegroundObservers: [NSObjectProtocol] = []
	/// Staging window while inactive/background. Cannot cover SpringBoard
	/// CallKit; torn down when `.active` so ContentView shows InCall.
	private var hostWindow: UIWindow?
	private var hostController: UIHostingController<BeamioInCallScreen>?

	private init() {}

	/// Dual-write busy-qa + voice-qa for Device Hub pull.
	private func crumb(_ line: String) {
		BeamioVoipIncomingBootstrap.shared.callKit.writeBusyQaBreadcrumb(line)
		BeamioNativeVoiceSignaling.qaTrail(line)
	}

	// MARK: Call lifecycle (main thread)

	/// Dialer inside the native shell: show this screen as soon as the call is
	/// placed ("Calling…"), then switch to the timer on Accept.
	func beginOutgoing(callId: String, sessionId: String, address: String) {
		let sameLiveCall = live && self.callId == callId
		// Keep the tag a prepared screen already looked up for this peer.
		let preparedTag = (live && self.callId.isEmpty
			&& self.address.caseInsensitiveCompare(address) == .orderedSame) ? tag : ""
		preparedId = ""
		begin(callId: callId, sessionId: sessionId, tag: preparedTag, address: address, foregroundDial: true)
		if !sameLiveCall {
			connected = false
			peerWake = .waiting
		}
		lookUpTag(for: address)
	}

	/// The PWA's `prepareSystemCall` id while the screen waits for `startSystemCall`.
	private var preparedId = ""
	private var cancelledPrepareIds: [String] = []

	/// Dial pressed: show "Calling…" at once while the PWA still builds the
	/// offer. `beginOutgoing` later fills in the real call ids.
	func beginPrepared(prepareId: String, address: String) {
		if live && !isPrepared {
			NSLog("[BeamioInCall] prepare skipped; a call is live")
			return
		}
		begin(callId: "", sessionId: "", tag: "", address: address, foregroundDial: true)
		connected = false
		peerWake = .waiting
		prepareError = ""
		preparedId = prepareId
		NSLog("[BeamioInCall] incall-prepared")
		lookUpTag(for: address)
	}

	/// True while the screen is shown for a dial that has no call ids yet.
	var isPrepared: Bool { live && callId.isEmpty && sessionId.isEmpty }

	/// End a prepared screen. An empty `prepareId` means "whatever is prepared".
	@discardableResult
	func cancelPrepared(prepareId: String = "") -> Bool {
		guard isPrepared else { return false }
		if !prepareId.isEmpty, !preparedId.isEmpty, prepareId != preparedId { return false }
		let id = prepareId.isEmpty ? preparedId : prepareId
		if !id.isEmpty {
			cancelledPrepareIds.append(id)
			if cancelledPrepareIds.count > 20 { cancelledPrepareIds.removeFirst() }
		}
		preparedId = ""
		prepareError = ""
		end(callId: "")
		crumb("incall-prepared-cancelled")
		return true
	}

	/// The PWA could not place the prepared dial. Keep the screen up with the
	/// reason; End (or a short timeout) closes it. Returns false when no
	/// matching prepared screen is showing.
	@discardableResult
	func failPrepared(prepareId: String, message: String) -> Bool {
		guard isPrepared else { return false }
		if !prepareId.isEmpty, !preparedId.isEmpty, prepareId != preparedId { return false }
		let id = prepareId.isEmpty ? preparedId : prepareId
		if !id.isEmpty {
			cancelledPrepareIds.append(id)
			if cancelledPrepareIds.count > 20 { cancelledPrepareIds.removeFirst() }
		}
		prepareError = message
		crumb("incall-prepared-failed")
		DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
			guard let self, self.isPrepared, self.prepareError == message else { return }
			self.cancelPrepared()
		}
		return true
	}

	/// The user hung up while this dial was still being prepared.
	func wasPrepareCancelled(_ prepareId: String) -> Bool {
		!prepareId.isEmpty && cancelledPrepareIds.contains(prepareId)
	}

	private func lookUpTag(for address: String) {
		guard !address.isEmpty else { return }
		BeamioTagAddressLookup.fetchExactTag(for: address) { [weak self] tag in
			DispatchQueue.main.async {
				guard let self, self.live,
				      self.address.caseInsensitiveCompare(address) == .orderedSame,
				      let tag, let normalized = BeamioIncomingCallPayload.normalizedBeamioTag(tag)
				else { return }
				self.tag = normalized
			}
		}
	}

	/// Dialer: the callee accepted. Start the call timer.
	func markConnected(callId: String) {
		guard live, callId.isEmpty || callId == self.callId, !connected else { return }
		connected = true
		answeredAt = Date()
		NSLog("[BeamioInCall] outgoing connected callId=%@", self.callId)
		BeamioCallKitVideoButton.callDidConnect()
	}

	/// `foregroundDial`: the user dialed from the app in the foreground. The
	/// screen only needs `presented`; the lock-screen answer wake below (scene
	/// activation, own-URL open, timed retries, fsynced breadcrumbs) costs
	/// hundreds of milliseconds on the main thread before the screen paints.
	func begin(callId: String, sessionId: String, tag: String, address: String, foregroundDial: Bool = false) {
		let sameLiveCall = live && self.callId == callId
		self.callId = callId
		self.sessionId = sessionId
		let normalizedTag = BeamioIncomingCallPayload.normalizedBeamioTag(tag) ?? ""
		if !normalizedTag.isEmpty {
			self.tag = normalizedTag
		} else if !sameLiveCall {
			self.tag = ""
		}
		if !address.isEmpty {
			self.address = address
		} else if !sameLiveCall {
			self.address = ""
		}
		if !sameLiveCall {
			answeredAt = Date()
			connected = true
			muted = false
			speakerOn = false
			stopLocalVideo(emitBridge: false, sendControl: false)
			remoteVideoOn = false
			remoteVideoImage = nil
			videoError = nil
			BeamioNativeVoiceChannel.shared.setRemoteVideoHandlers(
				onFrame: { [weak self] image in
					DispatchQueue.main.async {
						guard let self, self.live else { return }
						self.remoteVideoImage = image
						self.remoteVideoOn = true
						// Frames also count (peers that skip or send the enable
						// control once); the notice dedups per call.
						BeamioPeerVideoNotice.peerVideoChanged(enabled: true)
					}
				},
				onPeerEnabled: { [weak self] enabled in
					DispatchQueue.main.async {
						guard let self, self.live else { return }
						self.remoteVideoOn = enabled
						if !enabled {
							self.remoteVideoImage = nil
						}
						BeamioPeerVideoNotice.peerVideoChanged(enabled: enabled)
					}
				}
			)
		}
		live = true
		// Always request the full shell in-call UI (aligned layout: no keypad,
		// FaceTime top-center, End bottom-center, peer video bg). CallKit's own
		// lock-screen chrome cannot be restyled; once the scene can paint —
		// including after lock-screen slide-to-answer + unlock — raise the
		// dedicated host window (and ContentView fallback) over system Keypad.
		presented = true
		if !sameLiveCall {
			reconnecting = false
			endNotice = ""
		}
		if foregroundDial && UIApplication.shared.applicationState == .active {
			destroyHostWindow()
			NSLog("[BeamioInCall] begin callId=%@ presented=yes foreground-dial", callId)
			return
		}
		NSLog(
			"[BeamioInCall] begin callId=%@ tag=%@ presented=yes same=%@ appState=%ld",
			callId,
			self.tag.isEmpty ? "-" : self.tag,
			sameLiveCall ? "yes" : "no",
			Int(UIApplication.shared.applicationState.rawValue)
		)
		crumb(
			"lock-answer-shell-begin:callId=\(callId.prefix(8)):same=\(sameLiveCall ? "yes" : "no"):appState=\(UIApplication.shared.applicationState.rawValue)"
		)
		ensureSurfaceVisible(source: sameLiveCall ? "accept-refresh" : "answer-immediate")
		scheduleSurfaceAfterLockAnswer()
		armForegroundSurfaceObservers()
	}

	/// Force `presented=true`, raise product InCall chrome, and wake the scene.
	///
	/// Lock-screen Answer calls `begin` while the app is often still
	/// `.inactive`/`.background`. SpringBoard CallKit cannot be overdrawn; a
	/// dedicated `UIWindow` at `alert+2` is only a pre-unlock staging host.
	/// Once `.active`, prefer ContentView InCall (destroy host) so we never
	/// leave `externalHostActive` true with a host that CallKit already won —
	/// that combination hid ContentView and showed Home after CallKit yielded.
	/// Always re-asserts (never early-returns when already presented).
	func ensureSurfaceVisible(source: String) {
		guard live else {
			NSLog("[BeamioInCall] ensureSurface skip !live source=%@", source)
			return
		}
		let wasPresented = presented
		if !presented {
			presented = true
		} else {
			// Already true — still poke SwiftUI so overlay re-evaluates after unlock.
			objectWillChange.send()
		}
		let state = UIApplication.shared.applicationState
		let hostToken: String
		if state == .active {
			// Main hierarchy owns product UI once we can paint.
			destroyHostWindow()
			hostToken = "contentView"
			tearDownForegroundSurfaceObserversIfActive(source: source)
		} else {
			let hostRaised = installOrRaiseHostWindow(source: source)
			hostToken = hostRaised ? "yes" : "pending"
		}
		NSLog(
			"[BeamioInCall] ensureSurface source=%@ wasPresented=%@ presented=yes host=%@ appState=%ld",
			source,
			wasPresented ? "yes" : "no",
			hostToken,
			Int(state.rawValue)
		)
		crumb(
			"lock-answer-surface-visible:\(source):host=\(hostToken):appState=\(state.rawValue)"
		)
		// Always request scene / beamio://incall — inactive needs wake; active
		// still benefits after CallKit yields key-window ownership. Not for the
		// `beamio://incall` link itself while active: that link is our own wake,
		// and re-opening it from here looped (dozens of wakes per second, each
		// with fsynced breadcrumbs on the main thread) for the whole call.
		if !(state == .active && source == "deepLink-incall") {
			Self.bringAppForward(source: source)
		}
	}

	/// Lock-screen Answer often refuses `openURL` until unlock. Retry present +
	/// wake so the shell screen appears after unlock instead of lingering on
	/// CallKit’s system Accept/Keypad chrome. Also used from `didActivate`.
	func scheduleSurfaceAfterLockAnswer() {
		cancelSurfaceRetries()
		// Cover Answer → audio activate → unlock → late scene activation.
		let delays: [TimeInterval] = [0.25, 0.6, 1.2, 2.0, 3.5, 5.5, 8.0]
		for delay in delays {
			let work = DispatchWorkItem { [weak self] in
				guard let self, self.live else { return }
				self.ensureSurfaceVisible(source: String(format: "answer-retry-%.1f", delay))
			}
			surfaceRetryWorkItems.append(work)
			DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
		}
		NSLog("[BeamioInCall] surface-retry armed count=%d", delays.count)
	}

	/// CallKit `didActivate` — audio is ready; re-assert shell chrome + retries.
	func reassertAfterCallKitActivate() {
		guard live else { return }
		crumb("lock-answer-reassert:didActivate:callId=\(callId.prefix(8))")
		ensureSurfaceVisible(source: "didActivate")
		scheduleSurfaceAfterLockAnswer()
		armForegroundSurfaceObservers()
	}

	private func cancelSurfaceRetries() {
		for item in surfaceRetryWorkItems {
			item.cancel()
		}
		surfaceRetryWorkItems.removeAll()
	}

	private func armForegroundSurfaceObservers() {
		tearDownForegroundSurfaceObservers()
		let names: [Notification.Name] = [
			UIApplication.didBecomeActiveNotification,
			UIApplication.willEnterForegroundNotification,
			UIScene.didActivateNotification,
		]
		for name in names {
			let token = NotificationCenter.default.addObserver(
				forName: name,
				object: nil,
				queue: .main
			) { [weak self] _ in
				guard let self, self.live else { return }
				self.ensureSurfaceVisible(source: "notif-\(name.rawValue)")
			}
			surfaceForegroundObservers.append(token)
		}
		NSLog("[BeamioInCall] foreground surface observers armed")
	}

	private func tearDownForegroundSurfaceObservers() {
		for token in surfaceForegroundObservers {
			NotificationCenter.default.removeObserver(token)
		}
		surfaceForegroundObservers.removeAll()
	}

	/// Stop retries once we are truly foreground with product InCall presented
	/// (ContentView path). Brief `.active` under CallKit still reasserts via
	/// `scheduleSurfaceAfterLockAnswer` until unlockish sources fire.
	private func tearDownForegroundSurfaceObserversIfActive(source: String) {
		let unlockish =
			source == "becameActive"
			|| source == "scenePhase-active"
			|| source == "contentView-onAppear"
			|| source == "didActivate"
			|| source.hasPrefix("notif-")
		guard unlockish,
		      UIApplication.shared.applicationState == .active,
		      presented,
		      live,
		      !externalHostActive
		else { return }
		tearDownForegroundSurfaceObservers()
		cancelSurfaceRetries()
	}

	// MARK: Dedicated InCall UIWindow

	/// Prefer the foreground scene; fall back to any connected scene so we can
	/// attach a window before unlock finishes activating the app.
	private func preferredWindowScene() -> UIWindowScene? {
		let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
		return scenes.first(where: { $0.activationState == .foregroundActive })
			?? scenes.first(where: { $0.activationState == .foregroundInactive })
			?? scenes.first
	}

	@discardableResult
	private func installOrRaiseHostWindow(source: String) -> Bool {
		guard let scene = preferredWindowScene() else {
			externalHostActive = false
			NSLog("[BeamioInCall] host window pending (no scene) source=%@", source)
			return false
		}
		if let existing = hostWindow {
			if existing.windowScene !== scene {
				existing.windowScene = scene
			}
			existing.isHidden = false
			existing.makeKeyAndVisible()
			externalHostActive = true
			return true
		}
		let window = UIWindow(windowScene: scene)
		// Above normal app + typical alert sheets; cannot float over SpringBoard
		// CallKit while the device is locked, but wins once our process paints.
		window.windowLevel = UIWindow.Level.alert + 2
		window.backgroundColor = .black
		window.overrideUserInterfaceStyle = .dark
		let root = UIHostingController(rootView: BeamioInCallScreen(model: self))
		root.view.backgroundColor = .black
		window.rootViewController = root
		hostController = root
		hostWindow = window
		window.makeKeyAndVisible()
		externalHostActive = true
		NSLog("[BeamioInCall] host window raised source=%@", source)
		return true
	}

	private func hideHostWindow() {
		hostWindow?.isHidden = true
		if hostWindow?.isKeyWindow == true {
			// Return key status to the main SwiftUI window when possible.
			UIApplication.shared.connectedScenes
				.compactMap { $0 as? UIWindowScene }
				.flatMap(\.windows)
				.first(where: { $0 !== hostWindow && !$0.isHidden })?
				.makeKey()
		}
		externalHostActive = false
	}

	private func destroyHostWindow() {
		hideHostWindow()
		hostWindow?.rootViewController = nil
		hostWindow = nil
		hostController = nil
	}

	/// Opening the shell's own URL scheme activates the app from the background
	/// (the same wake the CallKit busy-rescue path relies on).
	static func bringAppForward(source: String) {
		let state = UIApplication.shared.applicationState
		NSLog(
			"[BeamioInCall] bringAppForward source=%@ appState=%ld",
			source,
			Int(state.rawValue)
		)
		// Prefer the focused scene session when available.
		let sessions = UIApplication.shared.openSessions
		let preferred =
			sessions.first(where: { $0.scene?.activationState == .foregroundActive })
			?? sessions.first(where: { $0.scene?.activationState == .foregroundInactive })
			?? sessions.first
		if let session = preferred {
			UIApplication.shared.requestSceneSessionActivation(
				session,
				userActivity: nil,
				options: nil
			) { error in
				NSLog(
					"[BeamioInCall] scene activation (%@) failed: %@",
					source,
					error.localizedDescription
				)
			}
			NSLog("[BeamioInCall] scene activation requested (%@)", source)
		}
		if let url = URL(string: "\(BeamioDeepLink.customScheme)://\(BeamioDeepLink.inCallHost)") {
			UIApplication.shared.open(url, options: [:]) { opened in
				NSLog(
					"[BeamioInCall] bring app forward (%@) open=%@",
					source,
					opened ? "ok" : "refused"
				)
			}
		}
	}

	func end(callId: String) {
		guard live, callId.isEmpty || callId == self.callId else { return }
		cancelSurfaceRetries()
		tearDownForegroundSurfaceObservers()
		destroyHostWindow()
		if speakerOn {
			try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
		}
		stopLocalVideo(emitBridge: true, sendControl: false)
		BeamioNativeVoiceChannel.shared.setRemoteVideoHandlers(onFrame: nil, onPeerEnabled: nil)
		BeamioPeerVideoNotice.callEnded()
		live = false
		presented = false
		connected = true
		muted = false
		speakerOn = false
		remoteVideoOn = false
		remoteVideoImage = nil
		videoError = nil
		videoToggleBusy = false
		prepareError = ""
		reconnecting = false
		endNotice = ""
		NSLog("[BeamioInCall] end callId=%@", callId)
	}

	/// Compatibility entry used by scenePhase / becameActive / deep link.
	/// Always re-asserts surface (does not early-return when already presented).
	func presentIfLive() {
		ensureSurfaceVisible(source: "presentIfLive")
	}

	func minimize() {
		presented = false
		cancelSurfaceRetries()
		tearDownForegroundSurfaceObservers()
		hideHostWindow()
	}

	/// CallKit's mute state is the source of truth (system UI and this screen share it).
	func syncMuted(_ value: Bool) {
		muted = value
	}

	// MARK: Controls

	func toggleMute() {
		BeamioVoipIncomingBootstrap.shared.callKit.requestMuted(
			callId: callId,
			sessionId: sessionId,
			muted: !muted
		)
	}

	func toggleSpeaker() {
		speakerOn.toggle()
		do {
			try AVAudioSession.sharedInstance().overrideOutputAudioPort(speakerOn ? .speaker : .none)
		} catch {
			NSLog("[BeamioInCall] speaker route failed %@", error.localizedDescription)
			speakerOn.toggle()
		}
	}

	func hangUp() {
		if !prepareError.isEmpty, isPrepared {
			// The dial already failed; the PWA has nothing left to cancel.
			cancelPrepared()
			return
		}
		if cancelPrepared() {
			// Hung up while the PWA was still preparing the dial: no call
			// exists yet. Tell the PWA to drop the dial it is building.
			NSLog("[BeamioInCall] End on prepared screen — cancel dial")
			BeamioVoipIncomingBootstrap.shared.emitCallActionToWeb("callEnded", callId: "", sessionId: "")
			return
		}
		BeamioVoipIncomingBootstrap.shared.callKit.end(callId: callId, sessionId: sessionId)
	}

	/// FaceTime: only this party starts capture + uplink. Peer must press separately.
	func toggleFaceTime() {
		guard live else {
			BeamioVoipIncomingBootstrap.shared.callKit.writeBusyQaBreadcrumb(
				"faceTime skip !live"
			)
			NSLog("[BeamioInCall] FaceTime skip !live")
			return
		}
		guard !videoToggleBusy else {
			BeamioVoipIncomingBootstrap.shared.callKit.writeBusyQaBreadcrumb(
				"faceTime skip busy callId=\(callId)"
			)
			NSLog("[BeamioInCall] FaceTime skip busy callId=%@", callId)
			return
		}
		if localVideoOn {
			stopLocalVideo(emitBridge: true, sendControl: true)
			return
		}
		// Ensure shell call chrome is visible so the camera permission sheet can present.
		if !presented {
			presented = true
		}
		videoToggleBusy = true
		videoError = nil
		let cid = callId
		let sid = sessionId
		BeamioVoipIncomingBootstrap.shared.callKit.writeBusyQaBreadcrumb(
			"faceTime start-req callId=\(cid) sessionId=\(sid)"
		)
		BeamioInCallVideoCapture.shared.onJpegFrame = { jpeg, w, h in
			BeamioNativeVoiceChannel.shared.sendVideoJpegFrame(jpeg, width: w, height: h)
		}
		// If permission UI never returns (rare), clear busy so a later press can retry.
		DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
			guard let self, self.videoToggleBusy, self.callId == cid, !self.localVideoOn else { return }
			self.videoToggleBusy = false
			self.videoError =
				"Camera did not start in time. Check Camera permission for Beamio in Settings and try FaceTime again."
			BeamioInCallVideoCapture.shared.onJpegFrame = nil
			BeamioInCallVideoCapture.shared.stop()
			BeamioVoipIncomingBootstrap.shared.callKit.writeBusyQaBreadcrumb(
				"faceTime start-timeout callId=\(cid)"
			)
			NSLog("[BeamioInCall] FaceTime start timeout callId=%@", cid)
		}
		BeamioInCallVideoCapture.shared.start { [weak self] result in
			DispatchQueue.main.async {
				guard let self else { return }
				self.videoToggleBusy = false
				switch result {
				case .success:
					guard self.live, self.callId == cid else {
						BeamioInCallVideoCapture.shared.stop()
						BeamioVoipIncomingBootstrap.shared.callKit.writeBusyQaBreadcrumb(
							"faceTime start-ok-stale callId=\(cid)"
						)
						return
					}
					self.localVideoOn = true
					self.videoError = nil
					BeamioNativeVoiceChannel.shared.sendVideoEnableControl(enabled: true)
					BeamioVoipIncomingBootstrap.shared.emitToWeb(
						"localVideoStarted",
						callId: cid,
						sessionId: sid
					)
					BeamioVoipIncomingBootstrap.shared.callKit.writeBusyQaBreadcrumb(
						"faceTime local ON callId=\(cid) sessionId=\(sid)"
					)
					NSLog("[BeamioInCall] FaceTime local ON callId=%@", cid)
				case .failure(let error):
					self.localVideoOn = false
					BeamioInCallVideoCapture.shared.onJpegFrame = nil
					BeamioInCallVideoCapture.shared.stop()
					let message = (error as? LocalizedError)?.errorDescription
						?? "Camera access is required for FaceTime. Enable Camera for Beamio in Settings and try again."
					self.videoError = message
					BeamioVoipIncomingBootstrap.shared.callKit.writeBusyQaBreadcrumb(
						"faceTime start-fail callId=\(cid) err=\(message.prefix(80))"
					)
					NSLog("[BeamioInCall] FaceTime start failed %@", message)
				}
			}
		}
	}

	private func stopLocalVideo(emitBridge: Bool, sendControl: Bool) {
		let wasOn = localVideoOn
		localVideoOn = false
		videoToggleBusy = false
		if BeamioInCallVideoCapture.instantiated {
			BeamioInCallVideoCapture.shared.onJpegFrame = nil
			BeamioInCallVideoCapture.shared.stop()
		}
		guard wasOn else { return }
		if sendControl {
			BeamioNativeVoiceChannel.shared.sendVideoEnableControl(enabled: false)
		}
		if emitBridge, !callId.isEmpty {
			BeamioVoipIncomingBootstrap.shared.emitToWeb(
				"localVideoStopped",
				callId: callId,
				sessionId: sessionId
			)
			BeamioVoipIncomingBootstrap.shared.callKit.writeBusyQaBreadcrumb(
				"faceTime local OFF callId=\(callId) sessionId=\(sessionId)"
			)
		}
		NSLog("[BeamioInCall] FaceTime local OFF callId=%@", callId)
	}
}

private extension Color {
	init(inCallHex hex: UInt32) {
		self.init(
			red: Double((hex >> 16) & 0xFF) / 255,
			green: Double((hex >> 8) & 0xFF) / 255,
			blue: Double(hex & 0xFF) / 255
		)
	}
}

/// Shown over the page while a shell-answered call is live and its screen is
/// minimized. iOS's own green bar only re-activates the app, so when the user
/// minimized inside the app (no activation happens) this is the way back.
/// A floating capsule, not a navigation bar.
struct BeamioInCallReturnPill: View {
	@ObservedObject var model: BeamioInCallScreenModel

	var body: some View {
		VStack {
			HStack {
				Spacer(minLength: 0)
				Button(action: { model.presentIfLive() }) {
					HStack(spacing: 6) {
						Image(systemName: "phone.fill")
							.font(.system(size: 13, weight: .bold))
						TimelineView(.periodic(from: .now, by: 1)) { context in
							let total = max(0, Int(context.date.timeIntervalSince(model.answeredAt)))
							Text(model.statusOverride ?? (model.connected ? String(format: "%02d:%02d", (total % 3600) / 60, total % 60) : model.pendingShortLabel))
								.font(.system(size: 14, weight: .semibold, design: .monospaced))
						}
						Text("Return to call")
							.font(.system(size: 14, weight: .semibold))
					}
					.foregroundStyle(.white)
					.padding(.horizontal, 14)
					.frame(height: 40)
					.background(Capsule().fill(Color(inCallHex: 0x2FAF52)))
					.shadow(color: Color.black.opacity(0.22), radius: 6, x: 0, y: 3)
					.contentShape(Capsule())
				}
				.accessibilityLabel("Return to call")
			}
			.padding(.trailing, 12)
			.padding(.top, 8)
			Spacer(minLength: 0)
		}
	}
}

/// Full-screen shell call UI after Answer (banner or lock-screen slide). Same
/// layout for both paths: peer video as full-bleed background (or audio gradient),
/// @BeamioTag + elapsed, collapsible tools over video, FaceTime control top-center,
/// End bottom-center. No keypad. CallKit’s lock-screen system chrome is not
/// restylable; this view replaces it as soon as the app can present.
struct BeamioInCallScreen: View {
	@ObservedObject var model: BeamioInCallScreenModel
	/// When peer video fills the background, tools (from @tag down) can collapse to the bottom.
	@State private var toolsExpanded = true

	private var title: String {
		if !model.tag.isEmpty { return model.tag }
		let short = BeamioIncomingAddressFormat.short(model.address)
		return short.isEmpty ? "Beamio call" : short
	}

	private var hasPeerVideoBackground: Bool {
		model.remoteVideoImage != nil
	}

	private static func clock(_ seconds: TimeInterval) -> String {
		let total = max(0, Int(seconds))
		let h = total / 3600
		let m = (total % 3600) / 60
		let s = total % 60
		return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
	}

	private let buttonSize: CGFloat = 78

	var body: some View {
		ZStack {
			// Full-screen peer video when available; otherwise audio-call gradient.
			Group {
				if let remote = model.remoteVideoImage {
					// The fill image sits in an overlay so it never sizes the
					// ZStack: a peer frame wider than the screen used to widen
					// the layout and push the self-view PiP off the right edge.
					Color.clear
						.overlay(
							Image(uiImage: remote)
								.resizable()
								.scaledToFill()
						)
						.clipped()
						.accessibilityLabel("Remote video")
				} else {
					LinearGradient(
						colors: [Color(inCallHex: 0x2C3A4D), Color(inCallHex: 0x161E2A), Color(inCallHex: 0x0A0E15)],
						startPoint: .top,
						endPoint: .bottom
					)
				}
			}
			.ignoresSafeArea()

			if hasPeerVideoBackground {
				LinearGradient(
					colors: [Color.black.opacity(0.35), Color.black.opacity(0.05), Color.black.opacity(0.55)],
					startPoint: .top,
					endPoint: .bottom
				)
				.ignoresSafeArea()
				.allowsHitTesting(false)
			}

			VStack(spacing: 0) {
				HStack {
					Button(action: { model.minimize() }) {
						Image(systemName: "chevron.down")
							.font(.system(size: 17, weight: .bold))
							.foregroundStyle(Color.white.opacity(0.85))
							.frame(width: 36, height: 36)
							.background(Circle().fill(Color.white.opacity(0.16)))
							.overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
							.frame(width: 44, height: 44)
							.contentShape(Rectangle())
					}
					.accessibilityLabel("Minimize call")
					Spacer()
					if model.localVideoOn {
						BeamioInCallLocalPreviewRepresentable()
							.frame(width: 88, height: 118)
							.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
							.overlay(
								RoundedRectangle(cornerRadius: 12, style: .continuous)
									.stroke(Color.white.opacity(0.45), lineWidth: 1)
							)
							.accessibilityLabel("Your camera preview")
					}
				}
				.padding(.horizontal, 12)
				.padding(.top, 8)
				.overlay(alignment: .top) { productLine.padding(.top, 18) }

				Spacer(minLength: 0)

				if hasPeerVideoBackground && !toolsExpanded {
					collapsedToolsBar
						.padding(.bottom, 28)
				} else {
					callToolsPanel
						.padding(.bottom, 28)
						.transition(.move(edge: .bottom).combined(with: .opacity))
				}
			}
			.animation(.easeInOut(duration: 0.28), value: toolsExpanded)
			.animation(.easeInOut(duration: 0.28), value: hasPeerVideoBackground)
		}
		.onChange(of: hasPeerVideoBackground) { _, active in
			if active {
				toolsExpanded = false
			} else {
				toolsExpanded = true
			}
		}
		.onAppear {
			BeamioCallTiming.mark("screen-onAppear")
			DispatchQueue.main.async { BeamioCallTiming.mark("screen-runloop") }
		}
	}

	/// Same product line as Android and the incoming screens: Beamio mark + "Beamio Audio".
	private var productLine: some View {
		HStack(spacing: 7) {
			Image("BeamioCallMark")
				.resizable()
				.scaledToFit()
				.frame(width: 20, height: 20)
				.clipShape(Circle())
				.accessibilityHidden(true)
			Text("Beamio Audio")
				.font(.system(size: 15, weight: .regular))
				.foregroundStyle(Color(inCallHex: 0xEBEBF5).opacity(0.6))
		}
		.accessibilityElement(children: .combine)
		.allowsHitTesting(false)
	}

	/// Compact bottom strip when peer video is full-screen and tools are collapsed.
	private var collapsedToolsBar: some View {
		Button(action: { toolsExpanded = true }) {
			VStack(spacing: 8) {
				Capsule()
					.fill(Color.white.opacity(0.45))
					.frame(width: 40, height: 5)
				HStack(spacing: 10) {
					Text(title)
						.font(.system(size: 17, weight: .semibold))
						.foregroundStyle(.white)
						.lineLimit(1)
					TimelineView(.periodic(from: .now, by: 1)) { context in
						Text(model.statusOverride ?? (model.connected ? Self.clock(context.date.timeIntervalSince(model.answeredAt)) : model.pendingShortLabel))
							.font(.system(size: 15, weight: .medium).monospacedDigit())
							.foregroundStyle(Color.white.opacity(0.75))
					}
					Image(systemName: "chevron.up")
						.font(.system(size: 13, weight: .bold))
						.foregroundStyle(Color.white.opacity(0.7))
				}
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 14)
			.frame(maxWidth: .infinity)
			.background(
				RoundedRectangle(cornerRadius: 22, style: .continuous)
					.fill(Color.black.opacity(0.42))
					.overlay(
						RoundedRectangle(cornerRadius: 22, style: .continuous)
							.stroke(Color.white.opacity(0.18), lineWidth: 1)
					)
			)
			.padding(.horizontal, 16)
		}
		.buttonStyle(.plain)
		.accessibilityLabel("Show call controls")
	}

	/// Identity + controls from @tag down (collapsible over peer video).
	private var callToolsPanel: some View {
		VStack(spacing: 0) {
			if hasPeerVideoBackground {
				Button(action: { toolsExpanded = false }) {
					Capsule()
						.fill(Color.white.opacity(0.45))
						.frame(width: 40, height: 5)
						.padding(.bottom, 12)
						.contentShape(Rectangle().size(width: 80, height: 28))
				}
				.buttonStyle(.plain)
				.accessibilityLabel("Hide call controls")
			}

			VStack(spacing: 6) {
				Text(title)
					.font(.system(size: 28, weight: .semibold))
					.foregroundStyle(.white)
					.lineLimit(1)
					.minimumScaleFactor(0.6)
					.padding(.horizontal, 24)
					.accessibilityLabel("Caller \(title)")
				TimelineView(.periodic(from: .now, by: 1)) { context in
					Text(model.statusOverride ?? (model.connected ? Self.clock(context.date.timeIntervalSince(model.answeredAt)) : model.pendingLabel))
						.font(.system(size: 18, weight: .regular).monospacedDigit())
						.foregroundStyle(Color.white.opacity(0.7))
						.multilineTextAlignment(.center)
						.padding(.horizontal, 28)
				}
				if let err = model.videoError, !err.isEmpty {
					Text(err)
						.font(.system(size: 13, weight: .medium))
						.foregroundStyle(Color(inCallHex: 0xFBBF24))
						.multilineTextAlignment(.center)
						.padding(.horizontal, 28)
						.padding(.top, 4)
						.accessibilityLabel(err)
				}
				if !model.address.isEmpty {
					HStack(spacing: 6) {
						Image(systemName: "wallet.pass")
							.font(.system(size: 12, weight: .semibold))
							.foregroundStyle(Color(inCallHex: 0x0051D1))
						Text(BeamioIncomingAddressFormat.short(model.address))
							.font(.system(size: 13, weight: .medium, design: .monospaced))
							.foregroundStyle(Color(inCallHex: 0x424655))
					}
					.padding(.horizontal, 12)
					.padding(.vertical, 6)
					.background(Capsule().fill(Color(inCallHex: 0xE9EDFF)))
					.overlay(Capsule().stroke(Color(inCallHex: 0xDCE2F7), lineWidth: 1))
					.padding(.top, 6)
					.accessibilityLabel(model.address)
				}
			}
			.padding(.bottom, 22)

			// Only controls that work. Same set as Android (which has no
			// camera uplink, so no Video there).
			VStack(spacing: 22) {
				HStack(alignment: .top, spacing: 26) {
					gridButton(
						symbol: model.muted ? "mic.slash.fill" : "mic.fill",
						label: "Mute",
						on: model.muted,
						action: { model.toggleMute() }
					)
					gridButton(
						symbol: model.localVideoOn ? "video.fill" : "video.slash.fill",
						label: "Video",
						on: model.localVideoOn,
						enabled: model.connected && !model.videoToggleBusy,
						action: { model.toggleFaceTime() }
					)
					gridButton(
						symbol: "speaker.wave.3.fill",
						label: "Speaker",
						on: model.speakerOn,
						action: { model.toggleSpeaker() }
					)
				}
				endCallButton
			}
		}
		.padding(.top, 16)
		.padding(.bottom, 12)
		.frame(maxWidth: .infinity)
		.background(
			Group {
				if hasPeerVideoBackground {
					RoundedRectangle(cornerRadius: 28, style: .continuous)
						.fill(Color.black.opacity(0.48))
						.overlay(
							RoundedRectangle(cornerRadius: 28, style: .continuous)
								.stroke(Color.white.opacity(0.12), lineWidth: 1)
						)
						.padding(.horizontal, 8)
				}
			}
		)
	}

	private var endCallButton: some View {
		VStack(spacing: 8) {
			Button(action: { model.hangUp() }) {
				Image(systemName: "phone.down.fill")
					.font(.system(size: 30, weight: .semibold))
					.foregroundStyle(.white)
					.frame(width: buttonSize, height: buttonSize)
					.background(Circle().fill(Color(inCallHex: 0xFF3B30)))
			}
			.accessibilityLabel("End Call")
			Text("End")
				.font(.system(size: 14, weight: .regular))
				.foregroundStyle(Color.white)
		}
	}

	/// Round control: translucent grey, white when switched on.
	private func gridButton(
		symbol: String,
		label: String,
		on: Bool,
		enabled: Bool = true,
		action: @escaping () -> Void = {}
	) -> some View {
		VStack(spacing: 8) {
			Button(action: action) {
				Image(systemName: symbol)
					.font(.system(size: 28, weight: .medium))
					.foregroundStyle(on ? Color(inCallHex: 0x161E2A) : Color.white)
					.frame(width: buttonSize, height: buttonSize)
					.background(Circle().fill(on ? Color.white : Color.white.opacity(0.18)))
			}
			.disabled(!enabled)
			.opacity(enabled ? 1 : 0.35)
			.accessibilityLabel(label)
			Text(label)
				.font(.system(size: 14, weight: .regular))
				.foregroundStyle(Color.white.opacity(enabled ? 1 : 0.5))
		}
	}
}
