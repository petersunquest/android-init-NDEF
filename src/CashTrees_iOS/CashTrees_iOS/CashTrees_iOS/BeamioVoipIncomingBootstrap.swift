import AVFoundation
import CallKit
import Foundation
import PushKit
import UIKit

/// Private UIApplication `suspend` for CallKit chrome (not a public API).
@objc private protocol BeamioUIApplicationPrivateSuspend {
	func suspend()
}

private func beamioPerformPrivateAppSuspend() {
	let sel = #selector(BeamioUIApplicationPrivateSuspend.suspend)
	guard UIApplication.shared.responds(to: sel) else { return }
	UIApplication.shared.perform(sel)
}

/// Shared CallKit + PushKit owner. Must start in `AppDelegate.didFinishLaunching`
/// so VoIP pushes can `reportNewIncomingCall` when the app was force-quit
/// (WebView / CashTreesWebCoordinator may not exist yet — same idea as Android
/// MessagingService → IncomingCallActivity).
final class BeamioCallKitManager: NSObject, CXProviderDelegate, CXCallObserverDelegate {
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
		/// CallKit handle last locked for this UUID. Starts opaque `"Beamio"`;
		/// becomes `@BeamioTag` once verified identity is painted (var so
		/// soft-reassert / same-call heal can sync with chromeTitle).
		var displayHandle: String
		/// Last painted CallKit title (`@tag` / short / `"Beamio"`) for busy chrome refresh.
		var chromeTitle: String = ""
		/// Outgoing dialer vs incoming callee — unanswered End must not send Decline for dialer.
		var isOutgoing: Bool = false
		/// True after any `reportCall(updated:)` (short address or @tag).
		var verifiedIdentityApplied: Bool = false
		/// True once CallKit title is a real `@BeamioTag` (not short EOA / "Beamio").
		var verifiedBeamioTagApplied: Bool = false
	}
	private var callIds: [UUID: CallIdentity] = [:]
	/// UUID → when `callIds` was written ahead of `reportNewIncomingCall` completion.
	/// Soft re-delivery must NOT treat a completed-but-dead map as "keep-inflight"
	/// (flash-hide: CallKit died, map lingered, soft-recent-dead never re-reported).
	private var pendingIncomingReportStartedAt: [UUID: CFAbsoluteTime] = [:]
	/// callId → a `reportIncoming` that has not finished yet, plus the
	/// completions of duplicate deliveries that joined it. Main thread.
	private var inflightIncomingReports: [String: (startedAt: CFAbsoluteTime, waiters: [((Error?) -> Void)?])] = [:]
	/// UUIDs that have already been Answered. Unanswered `CXEndCallAction` is
	/// Decline (must emit `callRejected` so the dialer stops ringing); answered
	/// End is Hang Up (`callEnded`). Matches Android Decline → `callRejected`.
	private var answeredCallUUIDs: Set<UUID> = []
	/// First live Incoming/connected CallKit UUID this process owns. Busy second
	/// calls must never `CXEndCallAction` this UUID (endZombie false-negative was
	/// killing A when B arrived → Home idle / jitter).
	private var stickyPrimaryUUID: UUID?
	private var stickyPrimaryCallId: String = ""
	/// Survives system CXEnd of sticky A during openURL/busy wake (v17).
	/// Cleared only on Answer, intentional Decline of that callId, or provider reset.
	private var stickyRingingSnapshot: CallIdentity?
	/// UUIDs we ourselves asked CallKit to End (Decline / busy-flash / zombie).
	/// System End of sticky A is NOT in this set → soft-reassert, no peer Decline.
	private var intentionallyEndingUUIDs = Set<UUID>()
	/// Answered UUID waiting for CallKit `didActivate` before notifying PWA
	/// (getUserMedia / WebRTC must not race the system in-call layout).
	private var pendingMediaStartUUID: UUID?
	private var audioSessionBeforeCall: AudioSessionSnapshot?
	/// Last successfully reported CallKit callId (debug-answer default).
	private(set) var lastReportedCallId: String = ""
	/// UUID of the last successful Incoming report for `lastReportedCallId`.
	/// Soft-reassert / system CXEnd can clear `callIds` while SpringBoard chrome
	/// still shows — browser Cancel must still `reportCall(endedAt:)` this UUID.
	private var lastReportedUUID: UUID?
	/// Every Incoming UUID we reported this process, keyed by callId. Survives
	/// map clears so remote Cancel can tear orphan CallKit chrome.
	private var ownedIncomingCallIds: [UUID: String] = [:]
	var onAction: ((String, String, String) -> Void)?
	/// Same WebView bridge as Bootstrap — dialer accept/reject without CX action.
	private var webBridge: ((String, String, String) -> Void)?
	private var pendingBridgeActions: [(action: String, callId: String, sessionId: String)] = []
	/// Delay process suspend until BeamioTag `reportCall(updated:)` finishes (or timeout).
	/// Immediate suspend after opaque first-report was killing Keychain/network resolve so
	/// CallKit stayed on "Beamio" while NC still showed APNs "Incoming call".
	private var pendingChromeSuspendWorkItem: DispatchWorkItem?
	/// Single delayed private-suspend after busy/openURL woke the host (v16).
	private var restoreStickyChromeWorkItem: DispatchWorkItem?
	/// v18: one soft-reassert at a time; CXEnd must finish before reportNewIncomingCall.
	private var softReassertInFlight = false
	private var pendingSoftReassertWorkItem: DispatchWorkItem?
	/// v24/v25: after busy openURL / soft-reassert "sticky still live" skip, re-check
	/// whether system CXEnd cleared A (observer lag made it look alive). Dead →
	/// soft-reassert; still alive → one light suspend (no 6× forceSuspend thrash).
	/// v25: do **not** cancel remaining heal probes when a soft-reassert *starts*
	/// (cancel only on Answer / clear sticky / soft-reassert **OK**). v24 cancelled
	/// on first dead→reassert, so a failed report left Home idle with no follow-up.
	private var pendingStickyHealWorkItems: [DispatchWorkItem] = []
	private var identityBackgroundTask: UIBackgroundTaskIdentifier = .invalid
	/// v48: dedicated BG for busy resuspend/dead-probe timers. Must NOT be
	/// ended by `cancelPendingChromeSuspend` (v47 race: that async end killed
	/// identity BG right after `preserveStickyChromeAfterBusySync` began it →
	/// 0.12s resuspend timers never drained → after-b Home idle).
	private var busyChromeBackgroundTask: UIBackgroundTaskIdentifier = .invalid
	private var chromeSuspendConsumed = false
	/// Soft-reassert attempt counter (reset on success / clear sticky). Caps retries.
	private var softReassertAttempt = 0
	/// v70: hard stop soft-reassert / rescue-openURL storm (SE debug: attempt 86+
	/// after system-cxend with busy=no → jetsam; cancel voice_end never handled).
	private static let softReassertMaxAttempts = 3
	private static let busyChromeRescueMaxAttempts = 4
	/// v26: coalesce self-wake openURL while busy secondary lands in background.
	private var busyChromeRescueInFlight = false
	private var busyChromeRescueOpenedAt: CFAbsoluteTime = 0
	/// v33: openURL may return ok=true while DeepLink never reaches
	/// `handleBusyChromeRescue` (Call B `--no-activate`). Watchdog clears
	/// inFlight and retries; without it the 2.5s coalesce blocked the 1.8s
	/// dead-fallback → after-b Home idle (v32).
	private var busyChromeRescueWatchdogWorkItem: DispatchWorkItem?
	private var busyChromeRescueOpenAttempts = 0
	private var busyDeadFallbackWorkItems: [DispatchWorkItem] = []
	private var busyActiveRestorePollWorkItems: [DispatchWorkItem] = []
	/// v28: after busy secondary decline, block force-suspend / becameActive suspend
	/// for a short window. Call B openURL (even `--no-activate`) still wakes the
	/// host → `didBecomeActive` → `scheduleForceSuspendRetries` → private
	/// `suspend` collapsed sticky CallKit A to Home idle (v20–v27 after-b).
	private var busyChromeGuardUntil: CFAbsoluteTime = 0
	/// v34: after busy secondary, sticky UUID may stay LIVE while CallKit chrome
	/// is already gone (leave-alone / refresh-only cannot revive). Arm a short
	/// window so chrome-rescue + becameActive may force soft-reassert replace.
	/// Only armed by busy leave-alive; cleared on Answer / soft-reassert OK /
	/// clearSticky / expire.
	private var busyZombieChromeHealUntil: CFAbsoluteTime = 0
	private var busyZombieChromeHealWorkItems: [DispatchWorkItem] = []
	/// v54: Call B openURL / busy settle often kills CallKit Incoming chrome while
	/// sticky UUID stays LIVE in the observer. Absolute leave-alone (v53) then
	/// never recovers. Mark presumed-dead so we may chrome-rescue → ACTIVE →
	/// PRE-END A + report A' (never CXCallUpdate / forceSuspend while LIVE).
	private var busyChromePresumedDead = false
	private var busyPresumedDeadRescueWorkItems: [DispatchWorkItem] = []
	/// v62: after busy absolute-noop, assume chrome may die while observer
	/// still LIVE (Call B openURL). Delayed tear → wait-ended → report A'.
	private var busyChromeDeadWhileLiveWatchdogWorkItems: [DispatchWorkItem] = []
	private var busyTearWaitReportInFlight = false
	/// v65: debug `selfProbe=pwa` holds private chrome-suspend so an in-process
	/// second `reportIncomingCallKit` (mustReport=false) can run without a
	/// second openURL. openURL of call B was activating the scene and SpringBoard
	/// dismissed sticky Incoming while the observer stayed LIVE.
	private var debugSelfProbeSuspendHold = false
	private var debugSelfProbeBgTask: UIBackgroundTaskIdentifier = .invalid
	private var debugSelfProbeTimers: [Timer] = []
	/// v66: `callRejected` while Background wakes WKWebView. Hold until foreground.
	private var deferredForegroundWebEmits: [(action: String, callId: String, sessionId: String)] = []

	private func rememberOwnedIncoming(uuid: UUID, callId: String) {
		let cid = callId.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !cid.isEmpty else { return }
		ownedIncomingCallIds[uuid] = cid
		lastReportedCallId = cid
		lastReportedUUID = uuid
	}

	private func forgetOwnedIncoming(uuid: UUID) {
		ownedIncomingCallIds.removeValue(forKey: uuid)
		if lastReportedUUID == uuid {
			lastReportedUUID = nil
		}
	}

	private func clearOwnedIncomingTracking() {
		ownedIncomingCallIds.removeAll()
		lastReportedUUID = nil
		lastReportedCallId = ""
	}

	private func adoptStickyPrimary(uuid: UUID, callId: String) {
		stickyPrimaryUUID = uuid
		stickyPrimaryCallId = callId
		if let id = callIds[uuid], !id.isOutgoing {
			stickyRingingSnapshot = id
		}
		if !callId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			rememberOwnedIncoming(uuid: uuid, callId: callId)
		}
		NSLog(
			"[BeamioCallKit] sticky primary uuid=%@ callId=%@",
			uuid.uuidString,
			callId
		)
	}

	private func clearStickyPrimary(uuid: UUID?, keepPresumedDead: Bool = false) {
		guard let uuid, stickyPrimaryUUID == uuid else { return }
		NSLog(
			"[BeamioCallKit] clear sticky primary uuid=%@ callId=%@ keepPresumedDead=%@",
			uuid.uuidString,
			stickyPrimaryCallId,
			keepPresumedDead ? "yes" : "no"
		)
		stickyPrimaryUUID = nil
		stickyPrimaryCallId = ""
		softReassertAttempt = 0
		cancelStickyHealProbes(reason: "clear-sticky-\(uuid.uuidString)")
		clearBusyZombieChromeHeal(reason: "clear-sticky-\(uuid.uuidString)")
		// v60 zombie-tear: keep presumedDead armed until A' report succeeds —
		// clearing it here left no rescue path when 0.2s defer never fired.
		if !keepPresumedDead {
			clearBusyChromePresumedDead(reason: "clear-sticky-\(uuid.uuidString)")
		}
	}

	/// v70: stop soft-reassert ↔ rescue-openURL ↔ restore-dead loop. Clears sticky
	/// snap so a later schedule cannot revive a dead/declined/cancelled ring.
	private func abortSoftReassertStorm(reason: String, callId: String = "") {
		let cid = callId.isEmpty
			? (stickyRingingSnapshot?.callId ?? stickyPrimaryCallId)
			: callId
		NSLog(
			"[BeamioCallKit] abort soft-reassert storm callId=%@ reason=%@ attempt=%d rescue=%d",
			cid,
			reason,
			softReassertAttempt,
			busyChromeRescueOpenAttempts
		)
		writeBusyQaBreadcrumb(
			"soft-reassert-storm-abort:\(cid.isEmpty ? "-" : cid):attempt=\(softReassertAttempt):rescue=\(busyChromeRescueOpenAttempts):\(reason)"
		)
		pendingSoftReassertWorkItem?.cancel()
		pendingSoftReassertWorkItem = nil
		softReassertInFlight = false
		softReassertAttempt = 0
		busyChromeRescueInFlight = false
		busyChromeRescueOpenAttempts = 0
		cancelBusyChromeRescueWatchdog()
		cancelStickyHealProbes(reason: "storm-abort-\(reason)")
		cancelBusyDeadChromeRescueFallbacks()
		cancelBusyActiveRestorePoll()
		cancelBusyChromeResuspend()
		cancelBusyPresumedDeadChromeRescue()
		clearBusyZombieChromeHeal(reason: "storm-abort-\(reason)")
		clearBusyChromePresumedDead(reason: "storm-abort-\(reason)")
		stickyRingingSnapshot = nil
		if let sticky = stickyPrimaryUUID {
			clearStickyPrimary(uuid: sticky)
		} else {
			stickyPrimaryUUID = nil
			stickyPrimaryCallId = ""
		}
		busyChromeGuardUntil = 0
	}

	private func clearStickyRingingSnapshot(callId: String) {
		guard let snap = stickyRingingSnapshot else { return }
		if callId.isEmpty || snap.callId == callId {
			stickyRingingSnapshot = nil
		}
	}

	/// Mark UUID before we request CXEnd so the End handler knows it was us.
	private func markIntentionallyEnding(_ uuid: UUID) {
		intentionallyEndingUUIDs.insert(uuid)
	}

	/// True when another owned call is the sticky primary.
	/// Orphan sticky (pointer set but map/observer empty) still counts — otherwise
	/// a second openURL races past the busy gate, `recreateProvider` wipes A, and
	/// after-b lands on Home idle. v17: also honor `stickyRingingSnapshot` after
	/// system CXEnd cleared the UUID but we still own ringing A.
	func hasStickyPrimaryExcluding(callId: String, sessionId: String = "") -> Bool {
		if let sticky = stickyPrimaryUUID {
			if let id = callIds[sticky], matches(id, callId: callId, sessionId: sessionId) {
				return false
			}
			return true
		}
		if let snap = stickyRingingSnapshot {
			if matches(snap, callId: callId, sessionId: sessionId) {
				return false
			}
			return true
		}
		return false
	}

	/// Single busy gate used by report / DeepLink / wasBusy completion.
	func isStickyOrBusyExcluding(callId: String, sessionId: String = "") -> Bool {
		hasStickyPrimaryExcluding(callId: callId, sessionId: sessionId)
			|| isBusyExcluding(callId: callId, sessionId: sessionId)
	}

	/// v27: sticky primary UUID still listed as non-ended in CallKit observer.
	/// When true, busy secondary must **only** decline B — never rescue / soft-reassert /
	/// forceSuspend (those paths collapsed after-b to Home idle through v26).
	func isStickyPrimaryStillLive() -> Bool {
		guard let uuid = stickyPrimaryUUID else { return false }
		return controller.callObserver.calls.contains { $0.uuid == uuid && !$0.hasEnded }
	}

	/// v80/v81/v90: Tear a sticky UUID that busy-blocks new dials while CallKit
	/// chrome is gone. Orphan = sticky pointer set but `callIds` empty; also
	/// tear remote-ended / dead-map sticky. v81 tore Active Pending + different
	/// incoming; v90 keeps LIVE Pending sticky (Soft+PushKit dual callId) and
	/// only tears when `busyChromePresumedDead`. Short RunLoop spin so
	/// `isBusyExcluding` / `wasBusy` re-check see observer ended.
	func tearGhostStickyUUID(_ sticky: UUID, reason: String) {
		assert(Thread.isMainThread)
		let liveBefore = controller.callObserver.calls.contains {
			$0.uuid == sticky && !$0.hasEnded
		}
		NSLog(
			"[BeamioCallKit] tear ghost sticky (v80) uuid=%@ live=%@ reason=%@",
			sticky.uuidString,
			liveBefore ? "yes" : "no",
			reason
		)
		writeBusyQaBreadcrumb(
			"ghost-sticky-tear:\(sticky.uuidString):live=\(liveBefore ? "yes" : "no"):\(reason)"
		)
		markIntentionallyEnding(sticky)
		provider.reportCall(
			with: sticky,
			endedAt: Date(),
			reason: .failed
		)
		clearStickyPrimary(uuid: sticky)
		callIds.removeValue(forKey: sticky)
		answeredCallUUIDs.remove(sticky)
		forgetOwnedIncoming(uuid: sticky)
		stickyRingingSnapshot = nil
		let end = CXEndCallAction(call: sticky)
		controller.request(CXTransaction(action: end)) { [weak self] err in
			self?.intentionallyEndingUUIDs.remove(sticky)
			self?.writeBusyQaBreadcrumb(
				"ghost-sticky-cxend-done:\(sticky.uuidString):err=\(err?.localizedDescription ?? "nil"):\(reason)"
			)
		}
		let waitDeadline = Date().addingTimeInterval(0.35)
		while Date() < waitDeadline {
			let stillLive = controller.callObserver.calls.contains {
				$0.uuid == sticky && !$0.hasEnded
			}
			if !stillLive { break }
			RunLoop.current.run(
				mode: .default,
				before: Date().addingTimeInterval(0.05)
			)
		}
		let stillLive = controller.callObserver.calls.contains {
			$0.uuid == sticky && !$0.hasEnded
		}
		writeBusyQaBreadcrumb(
			"ghost-sticky-tear-wait-done:live=\(stillLive ? "yes" : "no"):\(sticky.uuidString):\(reason)"
		)
	}

	/// v80/v81: Clear orphan / remote-ended / invisible-Pending sticky before busy
	/// gate so a fresh PushKit / soft report can paint CallKit again (FG dial was
	/// auto-declined via busy-pushkit while invisible sticky UUID stayed LIVE).
	///
	/// v84: never tear unmapped LIVE UUIDs owned by *this* incoming callId
	/// (ownedIncoming / lastReported / sticky). Soft chat re-report ran this
	/// before the busy gate and CXEnded PushKit-success Incoming → flash-hide.
	@discardableResult
	func clearGhostStickyBlockingNewReport(
		reason: String,
		incomingCallId: String = "",
		incomingSessionId: String = ""
	) -> Bool {
		assert(Thread.isMainThread)
		var tore = false
		let incoming = incomingCallId.trimmingCharacters(in: .whitespacesAndNewlines)
		let sess = incomingSessionId.trimmingCharacters(in: .whitespacesAndNewlines)

		var protectSameIncoming = Set<UUID>()
		if !incoming.isEmpty {
			if lastReportedCallId == incoming, let u = lastReportedUUID {
				protectSameIncoming.insert(u)
			}
			for (u, cid) in ownedIncomingCallIds where cid == incoming {
				protectSameIncoming.insert(u)
			}
			if stickyPrimaryCallId == incoming, let u = stickyPrimaryUUID {
				protectSameIncoming.insert(u)
			}
		}

		func healUnmappedOwned(_ uuid: UUID, crumb: String) {
			let snap = stickyRingingSnapshot
			let display = snap?.displayHandle ?? "Beamio"
			let chrome = snap?.chromeTitle ?? display
			let sid: String = {
				if let s = snap?.sessionId, !s.isEmpty { return s }
				return sess
			}()
			callIds[uuid] = CallIdentity(
				callId: incoming,
				sessionId: sid,
				displayHandle: display,
				chromeTitle: chrome
			)
			rememberOwnedIncoming(uuid: uuid, callId: incoming)
			if stickyPrimaryUUID == nil || stickyPrimaryUUID == uuid {
				adoptStickyPrimary(uuid: uuid, callId: incoming)
			}
			writeBusyQaBreadcrumb("\(crumb):\(uuid.uuidString):in=\(incoming):\(reason)")
		}

		// v81: End live CallKit UUIDs with no callIds map (busy-flash leftovers
		// that keep isBusyExcluding true forever without sticky chrome).
		// v84: heal/keep unmapped UUIDs owned for *this* incoming callId.
		let unmappedLive: [(UUID, Bool)] = controller.callObserver.calls.compactMap { call in
			guard !call.hasEnded else { return nil }
			guard callIds[call.uuid] == nil else { return nil }
			guard stickyPrimaryUUID != call.uuid else { return nil }
			return (call.uuid, call.isOutgoing)
		}
		for (uuid, outgoing) in unmappedLive {
			if !incoming.isEmpty, protectSameIncoming.contains(uuid) {
				healUnmappedOwned(uuid, crumb: "ghost-unmapped-keep-owned")
				continue
			}
			// v85: never CXEnd a UUID we already own for *any* callId.
			// Soft clearGhost(incoming=B) used to tear PushKit UUID owned by A
			// (or a prior soft UUID for A) → flash-hide of the live Incoming.
			if let ownedCid = ownedIncomingCallIds[uuid], !ownedCid.isEmpty {
				if ownedCid == incoming || incoming.isEmpty {
					healUnmappedOwned(uuid, crumb: "ghost-unmapped-keep-owned")
				} else {
					writeBusyQaBreadcrumb(
						"ghost-unmapped-keep-other-owned:\(uuid.uuidString):owned=\(ownedCid):ask=\(incoming):\(reason)"
					)
					if callIds[uuid] == nil {
						let snap = stickyRingingSnapshot
						let display = snap?.displayHandle ?? "Beamio"
						let chrome = snap?.chromeTitle ?? display
						let sid: String = {
							if let s = snap?.sessionId, !s.isEmpty { return s }
							return sess
						}()
						callIds[uuid] = CallIdentity(
							callId: ownedCid,
							sessionId: sid,
							displayHandle: display,
							chromeTitle: chrome
						)
					}
				}
				continue
			}
			if lastReportedUUID == uuid {
				healUnmappedOwned(uuid, crumb: "ghost-unmapped-keep-lastReported")
				continue
			}
			writeBusyQaBreadcrumb(
				"ghost-unmapped-live-tear:\(uuid.uuidString):outgoing=\(outgoing ? "yes" : "no"):\(reason)"
			)
			tearGhostStickyUUID(uuid, reason: "unmapped-\(reason)")
			tore = true
		}

		if stickyPrimaryUUID == nil, let snap = stickyRingingSnapshot {
			if BeamioNativeVoiceSignaling.wasRemoteEnded(
				callId: snap.callId,
				sessionId: snap.sessionId
			) {
				writeBusyQaBreadcrumb(
					"ghost-snap-remote-ended-clear:\(snap.callId):\(reason)"
				)
				stickyRingingSnapshot = nil
				tore = true
			}
		}

		guard let sticky = stickyPrimaryUUID else { return tore }

		if !incoming.isEmpty,
		   let id = callIds[sticky],
		   matches(id, callId: incoming, sessionId: sess) {
			return tore
		}

		if let id = callIds[sticky] {
			if BeamioNativeVoiceSignaling.wasRemoteEnded(
				callId: id.callId,
				sessionId: id.sessionId
			) {
				writeBusyQaBreadcrumb(
					"ghost-sticky-remote-ended-tear:\(id.callId):\(sticky.uuidString):\(reason)"
				)
				tearGhostStickyUUID(sticky, reason: reason)
				return true
			}
			// Soft dial + PushKit often arrive with *different* callIds for the
			// same ring. v81 tore any Active Pending sticky for a different
			// incoming — that mutual-tear flash-hid CallKit Incoming (v90
			// crumbs: soft 9c681eb3 vs push 73546a both CXEnd'd). Keep LIVE
			// Pending sticky; busy-early / busy-pushkit declines the sibling.
			// Still clear a dead map entry, and still tear when chrome is
			// presumed dead (true orphan / invisible chrome — v81 intent).
			let incomingDifferent = !incoming.isEmpty
				&& !matches(id, callId: incoming, sessionId: sess)
			let stickyLive = controller.callObserver.calls.first {
				$0.uuid == sticky && !$0.hasEnded
			}
			let appActive = UIApplication.shared.applicationState == .active
			if incomingDifferent {
				guard let stickyLive else {
					writeBusyQaBreadcrumb(
						"ghost-sticky-dead-map-clear:\(id.callId):\(sticky.uuidString):incoming=\(incoming):\(reason)"
					)
					tearGhostStickyUUID(sticky, reason: "dead-map-\(reason)")
					return true
				}
				if !stickyLive.hasConnected {
					if busyChromePresumedDead {
						writeBusyQaBreadcrumb(
							"ghost-sticky-invisible-pending-tear:\(id.callId):\(sticky.uuidString):active=\(appActive ? "yes" : "no"):presumedDead=yes:incoming=\(incoming):\(reason)"
						)
						tearGhostStickyUUID(sticky, reason: "invisible-pending-\(reason)")
						return true
					}
					writeBusyQaBreadcrumb(
						"ghost-sticky-invisible-pending-keep:\(id.callId):\(sticky.uuidString):live=yes:incoming=\(incoming):\(reason)"
					)
					return tore
				}
			}
			return tore
		}

		// Orphan sticky: pointer set, no callIds entry.
		// v84: if orphan is *this* incoming, heal map — do not CXEnd PushKit chrome.
		if !incoming.isEmpty,
		   stickyPrimaryCallId == incoming || protectSameIncoming.contains(sticky)
		{
			healUnmappedOwned(sticky, crumb: "ghost-sticky-orphan-heal")
			return tore
		}
		writeBusyQaBreadcrumb(
			"ghost-sticky-orphan-tear:\(sticky.uuidString):primaryCallId=\(stickyPrimaryCallId.isEmpty ? "-" : stickyPrimaryCallId):\(reason)"
		)
		tearGhostStickyUUID(sticky, reason: reason)
		return true
	}

	/// True when CallKit still shows a live Incoming for this callId (map, owned,
	/// lastReported, or sticky) — soft re-delivery must not re-clearGhost/tear.
	func hasLiveIncoming(forCallId callId: String, sessionId: String = "") -> Bool {
		assert(Thread.isMainThread)
		let cid = callId.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !cid.isEmpty else { return false }
		let sess = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
		for call in controller.callObserver.calls where !call.hasEnded {
			if let id = callIds[call.uuid], matches(id, callId: cid, sessionId: sess) {
				return true
			}
			if ownedIncomingCallIds[call.uuid] == cid { return true }
			if lastReportedUUID == call.uuid, lastReportedCallId == cid { return true }
			if stickyPrimaryUUID == call.uuid, stickyPrimaryCallId == cid { return true }
		}
		return false
	}

	/// True when this callId was already pinned to a CallKit UUID (report succeeded
	/// or in-flight pin). Soft FG must still report when `voice_end` gossip-reordered
	/// *before* any report (`end skip — no uuid` + `soft-skip-remote-ended`); after a
	/// successful report, `reportIncoming` tears if `remoteEnded` is still set.
	func hasOwnedIncoming(forCallId callId: String) -> Bool {
		let cid = callId.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !cid.isEmpty else { return false }
		if lastReportedCallId == cid { return true }
		if stickyPrimaryCallId == cid { return true }
		return ownedIncomingCallIds.values.contains(cid)
	}

	/// v28/v30: arm after every busy secondary decline. Blocks force-suspend /
	/// becameActive suspend that would collapse sticky CallKit A **while LIVE**.
	/// Blocks force-suspend / chrome-rescue activate while sticky A must stay.
	/// v36: re-armed on soft-reassert OK (~default 18s) so becameActive cannot
	/// private-suspend the freshly reported call; banner = HOME, not suspend.
	/// v41: default **30s** — v40 QA after-b was ~17s after Call B; 18s window
	/// expired before settle finished. busy-resuspend is allowed under this guard.
	func armBusyChromeGuard(reason: String, seconds: CFTimeInterval = 30) {
		busyChromeGuardUntil = CFAbsoluteTimeGetCurrent() + seconds
		NSLog(
			"[BeamioCallKit] busy-chrome-guard arm reason=%@ for=%.1fs",
			reason,
			seconds
		)
	}

	/// Append one line to Documents/busy-qa-breadcrumb.log for QA (syslog often empty).
	/// v41: `synchronizeFile` so a mid-write process suspend still leaves the line.
	/// Shared with `BeamioVoipIncomingBootstrap` (PushKit / soft cancel paths).
	func writeBusyQaBreadcrumb(_ line: String) {
		let stamp = ISO8601DateFormatter().string(from: Date())
		let text = "\(stamp) \(line)\n"
		NSLog("[BeamioCallKit] qa-breadcrumb %@", line)
		guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
			return
		}
		let url = dir.appendingPathComponent("busy-qa-breadcrumb.log")
		if let data = text.data(using: .utf8) {
			if FileManager.default.fileExists(atPath: url.path) {
				if let handle = try? FileHandle(forWritingTo: url) {
					defer {
						try? handle.synchronize()
						try? handle.close()
					}
					_ = try? handle.seekToEnd()
					try? handle.write(contentsOf: data)
				}
			} else {
				try? data.write(to: url, options: .atomic)
			}
		}
	}

	func clearBusyChromeGuard(reason: String) {
		guard busyChromeGuardUntil > 0 else { return }
		busyChromeGuardUntil = 0
		cancelBusyChromeResuspend()
		cancelBusyChromeDeadProbes()
		cancelBusyChromeRevivePulses()
		cancelBusyChromeDeadWhileLiveWatchdog()
		busyTearWaitReportInFlight = false
		endBusyChromeBackgroundTask(reason: "clear-guard-\(reason)")
		NSLog("[BeamioCallKit] busy-chrome-guard clear reason=%@", reason)
	}

	private func cancelBusyChromeDeadWhileLiveWatchdog() {
		for item in busyChromeDeadWhileLiveWatchdogWorkItems {
			item.cancel()
		}
		busyChromeDeadWhileLiveWatchdogWorkItems.removeAll()
	}

	/// v62–v63 FAIL: chrome-dead-while-LIVE watchdog tore sticky A then
	/// report-invoke left Home idle / paste overlay (Carol’s iMac). Product
	/// busy gate must **not** tear the first ringing call to “rescue” chrome.
	/// **v64:** this scheduler is an absolute no-op. Sticky DEAD still recovers
	/// via `callObserver` / `becameActive` → `restoreStickyCallKitChrome`.
	private func scheduleBusyChromeDeadWhileLiveWatchdog(reason: String) {
		cancelBusyChromeDeadWhileLiveWatchdog()
		writeBusyQaBreadcrumb(
			"chrome-dead-while-live-watchdog-disabled-v64:\(reason)"
		)
		NSLog(
			"[BeamioCallKit] chrome-dead-while-LIVE watchdog DISABLED (v64 noop) reason=%@",
			reason
		)
	}

	/// v63 primary recovery: RunLoop spin delays (not asyncAfter) so BG after
	/// Call B still reaches tear→report before process fully suspends.
	private func runBusyChromeDeadWhileLiveWatchdogViaRunLoopSpin(reason: String) {
		assert(Thread.isMainThread)
		cancelBusyChromeDeadWhileLiveWatchdog()
		beginBusyChromeBackgroundTaskIfNeeded(
			reason: "chrome-dead-sync-spin-\(reason)"
		)
		beginIdentityBackgroundTaskIfNeeded()
		NSLog(
			"[BeamioCallKit] busy chrome-dead-while-LIVE watchdog SYNC arm (v63 RunLoop) reason=%@",
			reason
		)
		writeBusyQaBreadcrumb(
			"chrome-dead-while-live-watchdog-sync-arm:\(reason)"
		)
		// Spins between fires keep CallKit observer callbacks draining.
		let spinSeconds: [TimeInterval] = [1.5, 1.5]
		for (index, spin) in spinSeconds.enumerated() {
			guard isBusyChromeGuardActive() else {
				writeBusyQaBreadcrumb(
					"chrome-dead-while-live-sync-stop-no-guard:\(index):\(reason)"
				)
				return
			}
			if busyTearWaitReportInFlight {
				writeBusyQaBreadcrumb(
					"chrome-dead-while-live-sync-stop-in-flight:\(index):\(reason)"
				)
				return
			}
			let deadline = Date().addingTimeInterval(spin)
			while Date() < deadline {
				RunLoop.current.run(
					mode: .default,
					before: Date().addingTimeInterval(0.05)
				)
			}
			writeBusyQaBreadcrumb(
				"chrome-dead-while-live-sync-spin-done:\(index):\(reason)"
			)
			runBusyChromeDeadWhileLiveWatchdog(index: index, reason: reason)
			if busyTearWaitReportInFlight { return }
			if !isStickyPrimaryStillLive(), !hasStickyRingingSnapshot() {
				return
			}
		}
	}

	private func runBusyChromeDeadWhileLiveWatchdog(index: Int, reason: String) {
		assert(Thread.isMainThread)
		guard isBusyChromeGuardActive() else {
			writeBusyQaBreadcrumb(
				"chrome-dead-while-live-skip-no-guard:\(index):\(reason)"
			)
			return
		}
		guard answeredCallUUIDs.isEmpty else {
			writeBusyQaBreadcrumb(
				"chrome-dead-while-live-skip-answered:\(index):\(reason)"
			)
			cancelBusyChromeDeadWhileLiveWatchdog()
			return
		}
		guard isStickyPrimaryStillLive() || hasStickyRingingSnapshot() else {
			writeBusyQaBreadcrumb(
				"chrome-dead-while-live-skip-no-sticky:\(index):\(reason)"
			)
			return
		}
		if busyTearWaitReportInFlight {
			writeBusyQaBreadcrumb(
				"chrome-dead-while-live-skip-in-flight:\(index):\(reason)"
			)
			return
		}
		let state = UIApplication.shared.applicationState
		NSLog(
			"[BeamioCallKit] chrome-dead-while-LIVE watchdog fire idx=%d state=%d reason=%@ (v63-sync)",
			index,
			state.rawValue,
			reason
		)
		writeBusyQaBreadcrumb(
			"chrome-dead-while-live-fire:\(index):state=\(state.rawValue):\(reason)"
		)
		beginBusyChromeBackgroundTaskIfNeeded(
			reason: "chrome-dead-watchdog-\(index)-\(reason)"
		)
		beginIdentityBackgroundTaskIfNeeded()
		markBusyChromePresumedDead(reason: "chrome-dead-while-live-\(index)")
		cancelBusyChromeDeadWhileLiveWatchdog()
		kickBusyZombieRescueIfNeeded(
			reason: "chrome-dead-while-live-\(index)-\(reason)"
		)
	}

	/// Keep the process awake long enough for busy resuspend / dead-probe
	/// `asyncAfter` work items (~5s). Separate from identity BG so tag-applied
	/// cancel cannot tear it down.
	private func beginBusyChromeBackgroundTaskIfNeeded(reason: String) {
		assert(Thread.isMainThread)
		if busyChromeBackgroundTask != .invalid {
			writeBusyQaBreadcrumb("busy-bg-keep:\(reason)")
			return
		}
		busyChromeBackgroundTask = UIApplication.shared.beginBackgroundTask(
			withName: "BeamioBusyChromeResuspend"
		) { [weak self] in
			self?.writeBusyQaBreadcrumb("busy-bg-expire:\(reason)")
			self?.endBusyChromeBackgroundTask(reason: "expire-\(reason)")
		}
		if busyChromeBackgroundTask == .invalid {
			writeBusyQaBreadcrumb("busy-bg-begin-failed:\(reason)")
		} else {
			writeBusyQaBreadcrumb("busy-bg-begin:\(reason)")
		}
	}

	private func endBusyChromeBackgroundTask(reason: String) {
		guard busyChromeBackgroundTask != .invalid else { return }
		UIApplication.shared.endBackgroundTask(busyChromeBackgroundTask)
		busyChromeBackgroundTask = .invalid
		writeBusyQaBreadcrumb("busy-bg-end:\(reason)")
	}

	/// v53: busy+LIVE → absolute noop (v52 keepalive self-destructed A).
	/// v54: busy+LIVE+presumedDead → zombie-rescue (chrome-rescue / PRE-END).
	/// DEAD + snap → restoreStickyCallKitChrome only.
	func kickBusyChromeResuspendIfNeeded(reason: String) {
		guard isBusyChromeGuardActive() else {
			writeBusyQaBreadcrumb("kick-busy-resuspend-skip-no-guard:\(reason)")
			return
		}
		cancelBusyChromeResuspend()
		cancelBusyChromeRevivePulses()
		beginBusyChromeBackgroundTaskIfNeeded(reason: "kick-\(reason)")
		beginIdentityBackgroundTaskIfNeeded()
		if isStickyPrimaryStillLive() {
			if busyChromePresumedDead {
				writeBusyQaBreadcrumb("kick-busy-live-presumed-dead-rescue:\(reason)")
				kickBusyZombieRescueIfNeeded(reason: "kick-\(reason)")
				return
			}
			writeBusyQaBreadcrumb("kick-busy-leave-alone-live-absolute:\(reason)")
			return
		}
		if hasStickyRingingSnapshot() {
			writeBusyQaBreadcrumb("kick-busy-dead-restore:\(reason)")
			restoreStickyCallKitChrome(reason: "kick-dead-\(reason)")
			return
		}
		writeBusyQaBreadcrumb("kick-busy-resuspend-skip-sticky-dead:\(reason)")
	}

	/// v53: sticky LIVE → never CXEnd / soft-reassert (v52 self-destruct).
	/// sticky DEAD → restoreStickyCallKitChrome only (no ring-keepalive report).
	func kickBusyRingKeepaliveNow(reason: String) {
		assert(Thread.isMainThread)
		guard isBusyChromeGuardActive() else {
			writeBusyQaBreadcrumb("ring-keepalive-skip-no-guard:\(reason)")
			return
		}
		guard answeredCallUUIDs.isEmpty else {
			writeBusyQaBreadcrumb("ring-keepalive-skip-answered:\(reason)")
			return
		}
		if isStickyPrimaryStillLive() {
			NSLog(
				"[BeamioCallKit] ring-keepalive SKIP sticky LIVE absolute (v53) reason=%@",
				reason
			)
			writeBusyQaBreadcrumb("ring-keepalive-skip-sticky-live-absolute:\(reason)")
			return
		}
		guard hasStickyRingingSnapshot() else {
			writeBusyQaBreadcrumb("ring-keepalive-skip-no-snap:\(reason)")
			return
		}
		NSLog(
			"[BeamioCallKit] ring-keepalive → restoreSticky (DEAD) reason=%@",
			reason
		)
		writeBusyQaBreadcrumb("ring-keepalive-dead-restore:\(reason)")
		beginIdentityBackgroundTaskIfNeeded()
		restoreStickyCallKitChrome(reason: "ring-keepalive-dead-\(reason)")
	}

	func isBusyChromeGuardActive() -> Bool {
		CFAbsoluteTimeGetCurrent() < busyChromeGuardUntil
	}

	/// True when a ringing snapshot still owns Call A after system CXEnd.
	func hasStickyRingingSnapshot() -> Bool {
		stickyRingingSnapshot != nil
	}

	/// v34: busy leave-alive armed a zombie-chrome heal window.
	func isBusyZombieChromeHealArmed() -> Bool {
		busyZombieChromeHealUntil > CFAbsoluteTimeGetCurrent()
	}

	func clearBusyZombieChromeHeal(reason: String) {
		if busyZombieChromeHealUntil != 0 || !busyZombieChromeHealWorkItems.isEmpty {
			NSLog("[BeamioCallKit] clear zombie-chrome-heal reason=%@", reason)
		}
		busyZombieChromeHealUntil = 0
		cancelBusyZombieChromeHealWorkItems()
		cancelBusyLiveChromeRescue()
	}

	private func cancelBusyZombieChromeHealWorkItems() {
		for item in busyZombieChromeHealWorkItems {
			item.cancel()
		}
		busyZombieChromeHealWorkItems.removeAll()
	}

	private func armBusyZombieChromeHeal(seconds: CFTimeInterval, reason: String) {
		busyZombieChromeHealUntil = CFAbsoluteTimeGetCurrent() + seconds
		NSLog(
			"[BeamioCallKit] arm zombie-chrome-heal for %.1fs reason=%@",
			seconds,
			reason
		)
	}

	/// v39/v40: soft-reassert / chrome-revive reasons for chrome-dead-while-LIVE
	/// after Call B openURL. PushKit is required for bg `reportNewIncomingCall`;
	/// openURL wake alone → report fails. Prefer CXCallUpdate revive.
	private func isBusyZombieHealReason(_ reason: String) -> Bool {
		reason.contains("zombie-heal")
			|| reason.contains("chrome-revive")
			|| reason.contains("busy-live-sync")
			|| reason.contains("live-rescue")
	}

	/// v51: soft-reassert MUST reportNewIncomingCall while sticky LIVE
	/// (bypass absolute skip + CXCallUpdate leave-alone). ACTIVE only.
	private func isBusyRingKeepaliveReason(_ reason: String) -> Bool {
		reason.hasPrefix("ring-keepalive")
			|| reason.contains("ring-keepalive")
			|| reason.contains("call-observer-sticky-ended")
	}

	/// v54: ACTIVE-only PRE-END A → report A' after chrome-rescue. Distinct from
	/// v39 CXCallUpdate heal and v51 ring-keepalive (self-destructed).
	private func isBusyZombieRescueReason(_ reason: String) -> Bool {
		reason.contains("busy-zombie-rescue")
			|| reason.contains("presumed-dead-rescue")
	}

	func isBusyChromePresumedDead() -> Bool {
		busyChromePresumedDead
	}

	func markBusyChromePresumedDead(reason: String) {
		busyChromePresumedDead = true
		NSLog("[BeamioCallKit] busy chrome presumed-dead arm reason=%@", reason)
		writeBusyQaBreadcrumb("busy-chrome-presumed-dead:\(reason)")
	}

	func clearBusyChromePresumedDead(reason: String) {
		guard busyChromePresumedDead || !busyPresumedDeadRescueWorkItems.isEmpty else { return }
		busyChromePresumedDead = false
		cancelBusyPresumedDeadChromeRescue()
		NSLog("[BeamioCallKit] busy chrome presumed-dead clear reason=%@", reason)
		writeBusyQaBreadcrumb("busy-chrome-presumed-dead-clear:\(reason)")
	}

	private func cancelBusyPresumedDeadChromeRescue() {
		for item in busyPresumedDeadRescueWorkItems {
			item.cancel()
		}
		busyPresumedDeadRescueWorkItems.removeAll()
	}

	/// v54–v55: delayed openURL → ACTIVE → PRE-END hang / paste dialog.
	/// **v56:** CXCallUpdate / kick only — never openURL while sticky LIVE.
	private func scheduleBusyPresumedDeadChromeRescue(reason: String) {
		cancelBusyPresumedDeadChromeRescue()
		let delays: [TimeInterval] = [0.18, 0.7, 1.6, 3.0]
		for (idx, delay) in delays.enumerated() {
			let item = DispatchWorkItem { [weak self] in
				guard let self else { return }
				guard self.isBusyChromeGuardActive() else {
					self.writeBusyQaBreadcrumb(
						"presumed-dead-rescue-skip-no-guard:\(idx):\(reason)"
					)
					return
				}
				guard self.busyChromePresumedDead else {
					self.writeBusyQaBreadcrumb(
						"presumed-dead-rescue-skip-cleared:\(idx):\(reason)"
					)
					return
				}
				guard self.answeredCallUUIDs.isEmpty else {
					self.clearBusyChromePresumedDead(reason: "answered-\(idx)")
					return
				}
				guard self.isStickyPrimaryStillLive() || self.hasStickyRingingSnapshot() else {
					self.writeBusyQaBreadcrumb(
						"presumed-dead-rescue-skip-no-sticky:\(idx):\(reason)"
					)
					return
				}
				let state = UIApplication.shared.applicationState
				NSLog(
					"[BeamioCallKit] presumed-dead rescue CXCallUpdate idx=%d state=%d reason=%@",
					idx,
					state.rawValue,
					reason
				)
				self.writeBusyQaBreadcrumb(
					"presumed-dead-rescue-update:\(idx):state=\(state.rawValue):\(reason)"
				)
				self.kickBusyZombieRescueIfNeeded(
					reason: "presumed-dead-rescue-\(idx)-\(reason)"
				)
			}
			busyPresumedDeadRescueWorkItems.append(item)
			DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
		}
	}

	/// v54–v55: PRE-END hung. v56: CXCallUpdate-only while LIVE → chrome still gone.
	/// **v57 FAIL:** kick from ACTIVE only; BG leave-alone never kicked.
	/// **v58:** LIVE+presumedDead → soft-reassert forceReplace (report-first A'
	/// via else: endZombieCalls clears B, then reportNewIncomingCall; NO PRE-END
	/// of sticky A). Call from ACTIVE or BG (leave-alone sync kick).
	func kickBusyZombieRescueIfNeeded(reason: String) {
		assert(Thread.isMainThread)
		guard isBusyChromeGuardActive() else {
			writeBusyQaBreadcrumb("zombie-rescue-kick-skip-no-guard:\(reason)")
			return
		}
		guard busyChromePresumedDead else {
			writeBusyQaBreadcrumb("zombie-rescue-kick-skip-not-presumed:\(reason)")
			return
		}
		guard answeredCallUUIDs.isEmpty else {
			clearBusyChromePresumedDead(reason: "answered-kick-\(reason)")
			return
		}
		guard isStickyPrimaryStillLive() || hasStickyRingingSnapshot() else {
			writeBusyQaBreadcrumb("zombie-rescue-kick-skip-no-sticky:\(reason)")
			return
		}
		let state = UIApplication.shared.applicationState
		let live = isStickyPrimaryStillLive()
		beginBusyChromeBackgroundTaskIfNeeded(reason: "zombie-kick-\(reason)")
		beginIdentityBackgroundTaskIfNeeded()
		NSLog(
			"[BeamioCallKit] zombie-rescue kick → soft-reassert forceReplace (v58) live=%@ state=%d reason=%@",
			live ? "yes" : "no",
			state.rawValue,
			reason
		)
		writeBusyQaBreadcrumb(
			"zombie-rescue-kick-force:\(reason):live=\(live ? "yes" : "no"):state=\(state.rawValue)"
		)
		softReassertStickyKeepingProtection(
			reason: "busy-zombie-rescue-\(reason)",
			scheduleSuspendOnSuccess: false,
			forceReplaceEvenIfAlive: true
		)
	}

	/// v40: re-paint sticky Incoming via CXCallUpdate while observer still LIVE.
	/// Safe when chrome is already gone (Call B openURL). Does NOT end UUID,
	/// does NOT openURL-activate, does NOT need PushKit.
	@discardableResult
	func reviveStickyChromeViaCallUpdate(reason: String) -> Bool {
		func run() -> Bool {
			// v45: Call B openURL leaves host ACTIVE; CXCallUpdate then collapses
			// sticky Incoming → Home idle (v44: revive + becameActive kick).
			// v49: busy-guard + ACTIVE → still skip. busy-guard + BG/inactive →
			// allow CXCallUpdate (chrome-dead-while-LIVE recovery without FG).
			let state = UIApplication.shared.applicationState
			// v56: busy+ACTIVE normally skips (v44/v49 killer), but chrome-dead-
			// while-LIVE (presumedDead) must allow CXCallUpdate — PRE-END hung in v55.
			if isBusyChromeGuardActive(), state == .active, !busyChromePresumedDead {
				NSLog(
					"[BeamioCallKit] chrome-revive SKIP busy-guard+ACTIVE (v49) reason=%@",
					reason
				)
				writeBusyQaBreadcrumb("chrome-revive-skip-busy-active:\(reason)")
				return false
			}
			if isBusyChromeGuardActive(), state == .active, busyChromePresumedDead {
				writeBusyQaBreadcrumb("chrome-revive-allow-presumed-dead-active:\(reason)")
			}
			guard answeredCallUUIDs.isEmpty else {
				NSLog(
					"[BeamioCallKit] chrome-revive skip — answered reason=%@",
					reason
				)
				return false
			}
			guard let sticky = stickyPrimaryUUID else {
				NSLog(
					"[BeamioCallKit] chrome-revive skip — no sticky uuid reason=%@",
					reason
				)
				return false
			}
			guard isStickyPrimaryStillLive() else {
				NSLog(
					"[BeamioCallKit] chrome-revive skip — sticky DEAD reason=%@",
					reason
				)
				return false
			}
			guard let id = callIds[sticky] ?? stickyRingingSnapshot, id.isOutgoing != true else {
				NSLog(
					"[BeamioCallKit] chrome-revive skip — no identity reason=%@",
					reason
				)
				return false
			}
			let title: String = {
				let chrome = id.chromeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
				if !chrome.isEmpty { return chrome }
				let locked = id.displayHandle.trimmingCharacters(in: .whitespacesAndNewlines)
				if !locked.isEmpty { return locked }
				return "Beamio"
			}()
			let update = Self.makeVerifiedIdentityUpdate(tag: title, shortAddress: "")
			provider.reportCall(with: sticky, updated: update)
			NSLog(
				"[BeamioCallKit] chrome-revive CXCallUpdate uuid=%@ title=%@ reason=%@",
				sticky.uuidString,
				title,
				reason
			)
			writeBusyQaBreadcrumb(
				"chrome-revive:\(reason):uuid=\(sticky.uuidString):title=\(title)"
			)
			return true
		}
		if Thread.isMainThread {
			return run()
		}
		var ok = false
		DispatchQueue.main.sync { ok = run() }
		return ok
	}

	/// v40–v45: chrome-dead-while-LIVE recovery.
	/// **v43 FAIL:** ACTIVE soft-reassert forceReplace destroyed CallKit Incoming.
	/// **v44 FAIL:** LIVE CXCallUpdate + becameActive kick while ACTIVE → Home idle.
	/// **v45:** busy-guard + sticky LIVE → absolute noop (no CXCallUpdate /
	/// resuspend). Soft-reassert forceReplace **only** when sticky UUID DEAD.
	func forceReplaceStickyAliveChrome(reason: String) {
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			guard self.isBusyZombieChromeHealArmed() || self.isBusyChromeGuardActive() else {
				NSLog(
					"[BeamioCallKit] forceReplace sticky skip — heal not armed reason=%@",
					reason
				)
				return
			}
			let tagged = self.isBusyZombieHealReason(reason)
				? reason
				: "zombie-heal-\(reason)"
			let live = self.isStickyPrimaryStillLive()
			let state = UIApplication.shared.applicationState
			if live {
				// v49: ACTIVE + busy → noop (v44 killer). BG/inactive → CXCallUpdate.
				// v56: presumedDead + ACTIVE → allow CXCallUpdate (no PRE-END).
				if self.isBusyChromeGuardActive(),
				   state == .active,
				   !self.busyChromePresumedDead
				{
					NSLog(
						"[BeamioCallKit] forceReplace LIVE noop busy+ACTIVE (v49) reason=%@ state=%d",
						tagged,
						state.rawValue
					)
					self.writeBusyQaBreadcrumb(
						"force-replace-live-noop-busy-active:\(tagged):state=\(state.rawValue)"
					)
					return
				}
				let revived = self.reviveStickyChromeViaCallUpdate(
					reason: "force-replace-live-\(tagged)"
				)
				NSLog(
					"[BeamioCallKit] forceReplace LIVE → CXCallUpdate revive=%@ reason=%@ state=%d",
					revived ? "yes" : "no",
					tagged,
					state.rawValue
				)
				self.writeBusyQaBreadcrumb(
					"force-replace-live-revive:\(tagged):ok=\(revived):state=\(state.rawValue)"
				)
				return
			}
			NSLog(
				"[BeamioCallKit] forceReplace sticky DEAD → soft-reassert reason=%@",
				tagged
			)
			self.writeBusyQaBreadcrumb(
				"force-replace-zombie:\(tagged):live=no"
			)
			self.beginIdentityBackgroundTaskIfNeeded()
			self.softReassertStickyKeepingProtection(
				reason: tagged,
				scheduleSuspendOnSuccess: false,
				forceReplaceEvenIfAlive: true
			)
		}
	}

	/// Kick from `didBecomeActive` when zombie-heal is armed (bg report failed).
	/// **v45:** busy-guard + sticky LIVE → absolute noop (Call B openURL ACTIVE
	/// + CXCallUpdate was the v44 after-b killer).
	func kickBusyZombieHealIfArmed(reason: String) {
		guard isBusyZombieChromeHealArmed() else { return }
		guard answeredCallUUIDs.isEmpty else {
			clearBusyZombieChromeHeal(reason: "answered-\(reason)")
			return
		}
		if isBusyChromeGuardActive(), isStickyPrimaryStillLive() {
			let state = UIApplication.shared.applicationState
			if state == .active {
				NSLog(
					"[BeamioCallKit] kickBusyZombieHeal SKIP busy+LIVE+ACTIVE (v49) reason=%@",
					reason
				)
				writeBusyQaBreadcrumb("kick-heal-skip-busy-live-active:\(reason)")
				return
			}
			let revived = reviveStickyChromeViaCallUpdate(
				reason: "kick-heal-bg-\(reason)"
			)
			writeBusyQaBreadcrumb(
				"kick-heal-bg-revive:\(reason):ok=\(revived):state=\(state.rawValue)"
			)
			return
		}
		guard isStickyPrimaryStillLive() || hasStickyRingingSnapshot() else { return }
		forceReplaceStickyAliveChrome(reason: reason)
	}

	/// v40: delayed probes after leave-alone.
	/// - sticky LIVE → CXCallUpdate revive (immediate + probes); soft-reassert
	///   only when app active. Never chrome-rescue while LIVE.
	/// - sticky DEAD → soft-reassert (+ chrome-rescue if background).
	/// BG task keeps these running while suspended.
	private func scheduleBusyZombieChromeHeal(reason: String) {
		cancelBusyZombieChromeHealWorkItems()
		// 0.05s: revive while process still awake from Call B openURL.
		let delays: [TimeInterval] = [0.05, 0.35, 1.2, 3.0, 6.5, 12.0]
		for (idx, delay) in delays.enumerated() {
			let work = DispatchWorkItem { [weak self] in
				guard let self else { return }
				guard self.isBusyZombieChromeHealArmed() else {
					NSLog(
						"[BeamioCallKit] zombie-heal skip expired idx=%d reason=%@",
						idx,
						reason
					)
					return
				}
				guard self.answeredCallUUIDs.isEmpty else {
					self.clearBusyZombieChromeHeal(reason: "answered-heal-\(idx)")
					return
				}
				let state = UIApplication.shared.applicationState
				let live = self.isStickyPrimaryStillLive()
				if live {
					let revived = self.reviveStickyChromeViaCallUpdate(
						reason: "zombie-heal-live-\(idx)-\(reason)"
					)
					NSLog(
						"[BeamioCallKit] zombie-heal LIVE → CXCallUpdate revive=%@ (v44 no soft-reassert) idx=%d state=%ld reason=%@",
						revived ? "yes" : "no",
						idx,
						state.rawValue,
						reason
					)
					self.writeBusyQaBreadcrumb(
						"zombie-heal-live-revive:\(idx):ok=\(revived ? "yes" : "no"):\(reason)"
					)
					// v44: never soft-reassert / chrome-rescue while sticky LIVE.
					// ACTIVE after Call B → pulse resuspend for SpringBoard banner.
					if state == .active {
						self.writeBusyQaBreadcrumb(
							"zombie-heal-live-active-resuspend:\(idx):\(reason)"
						)
						self.scheduleBusyChromeResuspend(
							reason: "zombie-heal-live-\(idx)-\(reason)"
						)
					}
					return
				}
				guard self.stickyRingingSnapshot != nil || self.stickyPrimaryUUID != nil else {
					NSLog(
						"[BeamioCallKit] zombie-heal skip no-snap idx=%d reason=%@",
						idx,
						reason
					)
					return
				}
				NSLog(
					"[BeamioCallKit] zombie-heal DEAD soft-reassert idx=%d state=%ld reason=%@",
					idx,
					state.rawValue,
					reason
				)
				self.writeBusyQaBreadcrumb(
					"zombie-heal-dead-force:\(idx):\(reason)"
				)
				self.beginIdentityBackgroundTaskIfNeeded()
				self.softReassertStickyKeepingProtection(
					reason: "zombie-heal-dead-\(idx)-\(reason)",
					scheduleSuspendOnSuccess: false,
					forceReplaceEvenIfAlive: true
				)
				if state != .active {
					self.requestBusyChromeRescue(reason: "zombie-wake-\(idx)-\(reason)")
				}
			}
			busyZombieChromeHealWorkItems.append(work)
			DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
		}
	}

	/// After busy decline of B: restore CallKit A **only if** sticky is already dead.
	/// Alive sticky → leave CallKit alone (no activate / soft-reassert while LIVE).
	///
	/// **v30:** Dead sticky → try in-process soft-reassert first; if background
	/// `reportNewIncomingCall` fails, chrome-rescue activate (only when DEAD).
	/// v29 banned rescue entirely → after-b Home idle.
	/// **v33:** LIVE leave-alone schedules **multi-delay** dead fallbacks (system
	/// may CXEnd A after Call B); DEAD path also arms active-poll restore for
	/// `--no-activate` hosts that never get `becameActive`.
	/// **v34:** LIVE leave-alone also `beginIdentityBackgroundTaskIfNeeded` +
	/// zombie-chrome heal (v33 had no BG task → probes never ran while suspended).
	/// **v35:** zombie heal / becameActive / chrome-rescue **must not** forceReplace
	/// or activate while sticky LIVE (v34 forceReplace+suspend = after-b Home idle).
	/// LIVE probes only `refreshLiveIncomingChrome`; DEAD → soft-reassert no-suspend.
	/// **v36:** LIVE leave-alone must **not** arm chrome-rescue fallbacks / active-poll.
	/// Those fired on a brief sticky-DEAD blip after Call B openURL → activate →
	/// soft-reassert **with private-suspend** → killed A' (v35 after-b Home idle).
	/// SYSTEM CXEnd path still arms fallbacks itself. LIVE → zombie heal refresh only.
	/// **v37:** LIVE leave-alone canceled soft-reassert + heal permanently →
	/// chrome-dead-while-LIVE after Call B openURL had no recovery.
	/// **v38:** Same permanent cancel of soft/heal; breadcrumb proved cancelSoft=no
	/// and no soft-reassert / system-cxend — absolute noop left A visually dead.
	/// **v39:** Still cancel **immediate** soft-reassert / chrome-rescue / sticky
	/// heal (they collapse LIVE A). Then **re-arm + schedule** zombie-chrome heal
	/// so delayed probes can soft-reassert forceReplace (report A' then end old)
	/// without chrome-rescue while sticky LIVE. Chat busy decline unchanged.
	/// **v40:** Call B openURL collapses Incoming chrome while observer stays
	/// LIVE. CXCallUpdate revive **immediately** (openURL wake window), then
	/// arm heal for delayed re-paints. Soft-reassert forceReplace only when
	/// ACTIVE — bg `reportNewIncomingCall` fails without PushKit.
	/// Caller must already have sync-armed `busyChromeGuard` before any async.
	/// v41: runs **synchronously on main** (main.sync off-main). v40 QA: entire
	/// body was `main.async`; Call B openURL (`activate=False`) suspended the
	/// process before drain → breadcrumb only had `chrome-revive`, never
	/// `leave-alone-live-arm-zombie-heal` → heal never armed.
	func maybeRescueStickyAfterBusyDecline(reason: String) {
		let run = { [weak self] in
			guard let self else { return }
			self.preserveStickyChromeAfterBusySync(reason: reason)
		}
		if Thread.isMainThread {
			run()
		} else {
			DispatchQueue.main.sync(execute: run)
		}
	}

	/// Cancel CallKit API touchers (CXCallUpdate / soft-reassert / chrome-rescue /
	/// zombie-heal). Does **not** cancel private-suspend resuspend — v46 needs
	/// that after Call B openURL wakes the host.
	private func cancelBusyLiveCallKitApiTouchers(reason: String) {
		cancelBusyDeadChromeRescueFallbacks()
		cancelBusyActiveRestorePoll()
		cancelBusyLiveChromeRescue()
		cancelBusyZombieChromeHealWorkItems()
		clearBusyZombieChromeHeal(reason: "abs-leave-\(reason)")
		pendingSoftReassertWorkItem?.cancel()
		pendingSoftReassertWorkItem = nil
		// v62: tear→poll-ended→report holds softReassertInFlight; do not clear
		// mid-wait or a concurrent Call B leave-alone will strand A'.
		if !busyTearWaitReportInFlight {
			softReassertInFlight = false
			softReassertAttempt = 0
		}
		cancelStickyHealProbes(reason: "abs-leave-\(reason)")
		cancelBusyChromeDeadProbes()
		cancelBusyChromeRevivePulses()
	}

	/// v45 leftover name — API touchers only (resuspend kept for v46).
	private func cancelBusyLiveCallKitTouchers(reason: String) {
		cancelBusyLiveCallKitApiTouchers(reason: reason)
	}

	/// v46–v49: delayed probe after busy leave-alone.
	/// v49: sticky LIVE + chrome-dead → CXCallUpdate revive (not leave-alone).
	/// sticky DEAD → soft-reassert a new UUID clone of A.
	private var busyChromeDeadProbeWorkItems: [DispatchWorkItem] = []
	private var busyChromeReviveWorkItems: [DispatchWorkItem] = []

	private func cancelBusyChromeDeadProbes() {
		for item in busyChromeDeadProbeWorkItems {
			item.cancel()
		}
		busyChromeDeadProbeWorkItems.removeAll()
	}

	private func cancelBusyChromeRevivePulses() {
		for item in busyChromeReviveWorkItems {
			item.cancel()
		}
		busyChromeReviveWorkItems.removeAll()
	}

	/// v49: CXCallUpdate pulses while busy-guard + sticky LIVE + !ACTIVE.
	/// Replaces BG private-suspend (v48 froze timers → no dead-probe breadcrumbs).
	private func scheduleBusyChromeRevivePulses(reason: String) {
		cancelBusyChromeRevivePulses()
		let delays: [TimeInterval] = [0.15, 0.5, 1.2, 2.5, 5.0]
		for (idx, delay) in delays.enumerated() {
			let item = DispatchWorkItem { [weak self] in
				guard let self else { return }
				guard self.isBusyChromeGuardActive() else {
					self.writeBusyQaBreadcrumb(
						"busy-revive-skip-no-guard:\(idx):\(reason)"
					)
					return
				}
				guard self.answeredCallUUIDs.isEmpty else {
					self.writeBusyQaBreadcrumb(
						"busy-revive-skip-answered:\(idx):\(reason)"
					)
					return
				}
				guard self.isStickyPrimaryStillLive() else {
					self.writeBusyQaBreadcrumb(
						"busy-revive-skip-sticky-dead:\(idx):\(reason)"
					)
					return
				}
				let state = UIApplication.shared.applicationState
				if state == .active {
					self.writeBusyQaBreadcrumb(
						"busy-revive-skip-active:\(idx):\(reason)"
					)
					return
				}
				let ok = self.reviveStickyChromeViaCallUpdate(
					reason: "busy-revive-\(idx)-\(reason)"
				)
				self.writeBusyQaBreadcrumb(
					"busy-revive-pulse:\(idx):ok=\(ok):state=\(state.rawValue):\(reason)"
				)
			}
			busyChromeReviveWorkItems.append(item)
			DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
		}
	}

	private func scheduleBusyChromeDeadProbes(reason: String) {
		cancelBusyChromeDeadProbes()
		// After Call B openURL settle (~1–8s). v45 after-b-pre-home was ~16s idle
		// with no system-cxend — catch DEAD early for soft-reassert.
		// v47: every skip path writes breadcrumb (v46 had silent returns → empty log).
		// v49: LIVE → CXCallUpdate revive (chrome-dead-while-LIVE).
		let delays: [TimeInterval] = [0.9, 2.0, 4.0, 8.0, 12.0]
		for (idx, delay) in delays.enumerated() {
			let item = DispatchWorkItem { [weak self] in
				guard let self else { return }
				guard self.isBusyChromeGuardActive() else {
					self.writeBusyQaBreadcrumb(
						"busy-dead-probe-skip-no-guard:\(idx):\(reason)"
					)
					return
				}
				guard self.answeredCallUUIDs.isEmpty else {
					self.writeBusyQaBreadcrumb(
						"busy-dead-probe-skip-answered:\(idx):\(reason)"
					)
					return
				}
				let live = self.isStickyPrimaryStillLive()
				let state = UIApplication.shared.applicationState
				if live {
					// v50: sticky LIVE → leave-alone (no CXCallUpdate).
					// v54: if chrome presumed-dead, openURL rescue / ACTIVE PRE-END.
					if self.busyChromePresumedDead {
						NSLog(
							"[BeamioCallKit] busy dead-probe LIVE+presumedDead rescue idx=%d state=%d reason=%@",
							idx,
							state.rawValue,
							reason
						)
						self.writeBusyQaBreadcrumb(
							"busy-dead-probe-live-presumed-dead:\(idx):state=\(state.rawValue):\(reason)"
						)
						if state == .active {
							self.kickBusyZombieRescueIfNeeded(
								reason: "dead-probe-\(idx)-\(reason)"
							)
						} else {
							self.requestBusyChromeRescue(
								reason: "dead-probe-\(idx)-\(reason)"
							)
						}
						return
					}
					NSLog(
						"[BeamioCallKit] busy dead-probe LIVE leave-alone (v50) idx=%d state=%d reason=%@",
						idx,
						state.rawValue,
						reason
					)
					self.writeBusyQaBreadcrumb(
						"busy-dead-probe-live-leave-alone:\(idx):state=\(state.rawValue):\(reason)"
					)
					return
				}
				guard self.stickyRingingSnapshot != nil || self.stickyPrimaryUUID != nil else {
					self.writeBusyQaBreadcrumb("busy-dead-probe-no-snap:\(idx):\(reason)")
					return
				}
				NSLog(
					"[BeamioCallKit] busy dead-probe sticky DEAD → soft-reassert idx=%d reason=%@",
					idx,
					reason
				)
				self.writeBusyQaBreadcrumb("busy-dead-probe-dead-soft-reassert:\(idx):\(reason)")
				self.beginIdentityBackgroundTaskIfNeeded()
				self.scheduleDeferredSoftReassert(
					reason: "busy-dead-probe-\(idx)-\(reason)",
					delay: 0.05,
					scheduleSuspendOnSuccess: true,
					forceReplaceEvenIfAlive: false
				)
				self.scheduleStickyHealProbes(reason: "busy-dead-probe-\(idx)")
				self.scheduleBusyDeadChromeRescueFallbacks(reason: "busy-dead-probe-\(idx)")
				self.scheduleBusyActiveRestorePoll(reason: "busy-dead-probe-\(idx)")
				self.scheduleBusyChromeResuspend(reason: "busy-dead-probe-\(idx)")
			}
			busyChromeDeadProbeWorkItems.append(item)
			DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
		}
	}

	/// v41–v50: sticky preserve body — must be called on main.
	/// **v49 FAIL:** deeplink skip+revive OK, then becameActive kick forceSuspend
	/// while ACTIVE killed Call A. Also ACTIVE preserve path forceSuspended.
	/// **v50:** sticky LIVE → absolute CallKit noop (no forceSuspend / revive /
	/// CXCallUpdate). Keep dedicated busy BG + identity BG. Dead-probe only
	/// soft-reasserts when sticky DEAD.
	/// **v54–v55 FAIL:** openURL + PRE-END hang / paste.
	/// **v56 FAIL:** CXCallUpdate-only → chrome still gone (Home idle).
	/// **v57 FAIL:** BG only Update + schedule; timers never breadcrumbed;
	/// soft-reassert BG defer missed `zombieRescueLive` → never report-first.
	/// **v58 FAIL:** BG sync kick + report-invoke while A LIVE → Apple never
	/// called completion (no timeout on that path) → softReassertInFlight stuck.
	/// **v59:** tear A chrome via `reportCall(endedAt:)` (no CXEnd wait), then
	/// report A' with 3s timeout.
	func preserveStickyChromeAfterBusySync(reason: String) {
		assert(Thread.isMainThread)
		// Re-arm (idempotent) in case caller forgot sync arm. 30s default.
		armBusyChromeGuard(reason: reason, seconds: 30)
		if isStickyPrimaryStillLive() {
			// v61–v63 FAIL: tear / report / CXCallUpdate “rescue” while A LIVE
			// either hung or killed CallKit chrome (after-b Home / paste).
			// **v64:** absolute CallKit noop while sticky LIVE. Decline B only
			// (rejectSecondaryWhileBusy). Never schedule chrome-dead watchdog.
			// If system CXEnds A → callObserver restores from sticky snap.
			let state = UIApplication.shared.applicationState
			NSLog(
				"[BeamioCallKit] busy absolute leave-alone sticky LIVE (v64) reason=%@ uuid=%@ state=%d",
				reason,
				stickyPrimaryUUID?.uuidString ?? "-",
				state.rawValue
			)
			cancelBusyLiveCallKitApiTouchers(reason: reason)
			cancelBusyChromeResuspend()
			cancelBusyChromeRevivePulses()
			cancelBusyLiveChromeRescue()
			cancelBusyChromeDeadWhileLiveWatchdog()
			// Suppress Universal Clipboard / pasteboard deep-link while busy
			// (openURL wake → becomeActive must not pop “paste from Carol’s iMac”).
			BeamioDeepLink.suppressPasteboardDeferredDeepLink(forSeconds: 30)
			// v66: do not begin BeamioBusyChromeResuspend / identity BG while
			// sticky Incoming is LIVE. v65's begin while Background dropped
			// the banner; the observer stayed LIVE.
			let uuid = stickyPrimaryUUID?.uuidString ?? "-"
			writeBusyQaBreadcrumb(
				"leave-alone-no-bg-v66:\(reason):uuid=\(uuid):state=\(state.rawValue)"
			)
			if stickyRingingSnapshot == nil,
			   let uuid = stickyPrimaryUUID,
			   let id = callIds[uuid] {
				stickyRingingSnapshot = id
				writeBusyQaBreadcrumb("leave-alone-pin-snap:\(id.callId)")
			}
			if busyChromePresumedDead {
				clearBusyChromePresumedDead(reason: "v64-live-clear-\(reason)")
			}
			return
		}
		if hasLiveCallKitCall() {
			NSLog(
				"[BeamioCallKit] busy leave-alone live CallKit (no sticky) reason=%@",
				reason
			)
			writeBusyQaBreadcrumb("leave-alone-live-callkit-no-sticky:\(reason)")
			return
		}
		guard stickyRingingSnapshot != nil || stickyPrimaryUUID != nil else {
			NSLog(
				"[BeamioCallKit] busy sticky DEAD — no snapshot/pointer reason=%@",
				reason
			)
			writeBusyQaBreadcrumb("busy-sticky-dead-no-snap:\(reason)")
			return
		}
		NSLog(
			"[BeamioCallKit] busy sticky DEAD — soft-reassert + chrome-rescue fallback (sync) reason=%@",
			reason
		)
		writeBusyQaBreadcrumb("busy-sticky-dead-soft-reassert:\(reason)")
		beginIdentityBackgroundTaskIfNeeded()
		scheduleDeferredSoftReassert(
			reason: "busy-dead-\(reason)",
			delay: 0.08,
			scheduleSuspendOnSuccess: false,
			forceReplaceEvenIfAlive: false
		)
		scheduleStickyHealProbes(reason: "busy-dead-\(reason)")
		scheduleBusyDeadChromeRescueFallbacks(reason: "busy-dead-\(reason)")
		scheduleBusyActiveRestorePoll(reason: "busy-dead-\(reason)")
		scheduleBusyChromeResuspend(reason: "\(reason)-after-dead-restore")
	}

	/// v41–v48: pulse private-suspend so CallKit A stays as Home banner after busy.
	/// Allowed only while busy-guard is active and reason contains `busy-resuspend`.
	private var busyChromeResuspendWorkItems: [DispatchWorkItem] = []

	private func cancelBusyChromeResuspend() {
		for item in busyChromeResuspendWorkItems {
			item.cancel()
		}
		busyChromeResuspendWorkItems.removeAll()
	}

	/// v50: never forceSuspend / revive while sticky LIVE (v49 ACTIVE
	/// forceSuspend killed Call A). Absolute skip; dead-restore paths still
	/// schedule this after soft-reassert when sticky DEAD.
	private func performBusyChromeResuspendPulse(reason: String) {
		assert(Thread.isMainThread)
		guard isBusyChromeGuardActive() else {
			writeBusyQaBreadcrumb("busy-resuspend-pulse-skip-no-guard:\(reason)")
			return
		}
		if isStickyPrimaryStillLive() {
			writeBusyQaBreadcrumb("busy-resuspend-pulse-skip-sticky-live-v50:\(reason)")
			return
		}
		writeBusyQaBreadcrumb("busy-resuspend-immediate:\(reason)")
		forceSuspendToKeepLiveCallChrome(reason: "busy-resuspend-immediate:\(reason)")
	}

	private func scheduleBusyChromeResuspend(reason: String) {
		cancelBusyChromeResuspend()
		// v50: sticky LIVE → never schedule forceSuspend (v49 killer).
		if isStickyPrimaryStillLive() {
			writeBusyQaBreadcrumb("busy-resuspend-schedule-skip-sticky-live-v50:\(reason)")
			return
		}
		let delays: [TimeInterval] = [0.12, 0.55, 1.2, 2.4, 4.0]
		for (idx, delay) in delays.enumerated() {
			let item = DispatchWorkItem { [weak self] in
				guard let self else { return }
				guard self.isBusyChromeGuardActive() else {
					self.writeBusyQaBreadcrumb(
						"busy-resuspend-skip-no-guard:\(idx):\(reason)"
					)
					return
				}
				if self.isStickyPrimaryStillLive() {
					self.writeBusyQaBreadcrumb(
						"busy-resuspend-skip-sticky-live-v50:\(idx):\(reason)"
					)
					return
				}
				self.forceSuspendToKeepLiveCallChrome(
					reason: "busy-resuspend-\(idx):\(reason)"
				)
			}
			busyChromeResuspendWorkItems.append(item)
			DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
		}
	}

	/// v42: if sync soft-reassert from bg did not clear heal (report still
	/// needs ACTIVE), open `busy-chrome-rescue` even while sticky LIVE so
	/// becameActive can kick forceReplace (v39s success path).
	private var busyLiveChromeRescueWorkItems: [DispatchWorkItem] = []

	private func cancelBusyLiveChromeRescue() {
		for item in busyLiveChromeRescueWorkItems {
			item.cancel()
		}
		busyLiveChromeRescueWorkItems.removeAll()
	}

	private func scheduleBusyLiveChromeRescueIfNeeded(reason: String) {
		cancelBusyLiveChromeRescue()
		let delays: [TimeInterval] = [0.45, 1.1, 2.2]
		for (idx, delay) in delays.enumerated() {
			let item = DispatchWorkItem { [weak self] in
				guard let self else { return }
				guard self.isBusyZombieChromeHealArmed() else {
					NSLog(
						"[BeamioCallKit] live-chrome-rescue skip — heal cleared idx=%d reason=%@",
						idx,
						reason
					)
					return
				}
				guard self.answeredCallUUIDs.isEmpty else {
					self.clearBusyZombieChromeHeal(reason: "answered-live-rescue-\(idx)")
					return
				}
				guard self.isStickyPrimaryStillLive() || self.hasStickyRingingSnapshot() else {
					return
				}
				let state = UIApplication.shared.applicationState
				if state == .active {
					NSLog(
						"[BeamioCallKit] live-chrome-rescue already ACTIVE → kick idx=%d reason=%@",
						idx,
						reason
					)
					self.writeBusyQaBreadcrumb(
						"live-chrome-rescue-active-kick:\(idx):\(reason)"
					)
					self.kickBusyZombieHealIfArmed(
						reason: "live-rescue-active-\(idx)-\(reason)"
					)
					return
				}
				NSLog(
					"[BeamioCallKit] live-chrome-rescue openURL activate idx=%d state=%ld reason=%@",
					idx,
					state.rawValue,
					reason
				)
				self.writeBusyQaBreadcrumb(
					"live-chrome-rescue:\(idx):state=\(state.rawValue):\(reason)"
				)
				self.requestBusyChromeRescue(
					reason: "zombie-heal-live-rescue-\(idx)-\(reason)"
				)
			}
			busyLiveChromeRescueWorkItems.append(item)
			DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
		}
	}

	/// v30/v33: sticky still dead after soft-reassert → activate via
	/// `beamio://busy-chrome-rescue`. Multi delays cover SYSTEM CXEnd lag and
	/// openURL DeepLink miss (v32 single 1.8s fell inside 2.5s coalesce).
	/// Never fires while sticky LIVE (activate collapses CallKit).
	private func scheduleBusyDeadChromeRescueFallbacks(reason: String) {
		cancelBusyDeadChromeRescueFallbacks()
		let delays: [TimeInterval] = [0.45, 1.0, 1.8, 2.8, 4.0]
		for delay in delays {
			let work = DispatchWorkItem { [weak self] in
				guard let self else { return }
				if self.isStickyPrimaryStillLive() {
					NSLog(
						"[BeamioCallKit] chrome-rescue fallback skip — sticky LIVE d=%.1f reason=%@",
						delay,
						reason
					)
					return
				}
				if self.hasLiveCallKitCall() {
					NSLog(
						"[BeamioCallKit] chrome-rescue fallback skip — live CallKit d=%.1f reason=%@",
						delay,
						reason
					)
					return
				}
				guard self.stickyRingingSnapshot != nil || self.stickyPrimaryUUID != nil else {
					NSLog(
						"[BeamioCallKit] chrome-rescue fallback skip — no sticky d=%.1f reason=%@",
						delay,
						reason
					)
					return
				}
				NSLog(
					"[BeamioCallKit] chrome-rescue fallback FIRE sticky DEAD d=%.1f reason=%@",
					delay,
					reason
				)
				// Allow retry past coalesce if a prior openURL never delivered DeepLink.
				self.forceClearBusyChromeRescueCoalesceIfStale(reason: "fallback-\(reason)")
				self.requestBusyChromeRescue(reason: "fallback-\(Int(delay * 10))-\(reason)")
			}
			busyDeadFallbackWorkItems.append(work)
			DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
		}
	}

	private func cancelBusyDeadChromeRescueFallbacks() {
		for item in busyDeadFallbackWorkItems {
			item.cancel()
		}
		busyDeadFallbackWorkItems.removeAll()
	}

	/// v33: Call B `--no-activate` never runs `becameActive`. Poll briefly: if
	/// host somehow becomes `.active` while sticky DEAD + snap → restore.
	private func scheduleBusyActiveRestorePoll(reason: String) {
		cancelBusyActiveRestorePoll()
		let delays: [TimeInterval] = [0.6, 1.4, 2.5, 4.0]
		for delay in delays {
			let work = DispatchWorkItem { [weak self] in
				guard let self else { return }
				guard UIApplication.shared.applicationState == .active else { return }
				guard !self.isStickyPrimaryStillLive() else { return }
				guard !self.hasLiveCallKitCall() else { return }
				guard self.stickyRingingSnapshot != nil || self.stickyPrimaryUUID != nil else {
					return
				}
				NSLog(
					"[BeamioCallKit] busy active-poll restore d=%.1f reason=%@",
					delay,
					reason
				)
				self.restoreStickyCallKitChrome(reason: "active-poll-\(reason)")
			}
			busyActiveRestorePollWorkItems.append(work)
			DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
		}
	}

	private func cancelBusyActiveRestorePoll() {
		for item in busyActiveRestorePollWorkItems {
			item.cancel()
		}
		busyActiveRestorePollWorkItems.removeAll()
	}

	/// v33: if openURL claimed success but DeepLink never cleared inFlight, drop
	/// coalesce so the next fallback can re-open.
	private func forceClearBusyChromeRescueCoalesceIfStale(reason: String) {
		guard busyChromeRescueInFlight else { return }
		let age = CFAbsoluteTimeGetCurrent() - busyChromeRescueOpenedAt
		guard age >= 1.0 else { return }
		NSLog(
			"[BeamioCallKit] busy-chrome-rescue coalesce FORCE-CLEAR age=%.2f reason=%@",
			age,
			reason
		)
		busyChromeRescueWatchdogWorkItem?.cancel()
		busyChromeRescueWatchdogWorkItem = nil
		busyChromeRescueInFlight = false
	}

	func setWebBridge(_ bridge: ((String, String, String) -> Void)?) {
		webBridge = bridge
		guard let bridge, !pendingBridgeActions.isEmpty else { return }
		let queued = pendingBridgeActions
		pendingBridgeActions.removeAll()
		for item in queued {
			bridge(item.action, item.callId, item.sessionId)
		}
	}

	override init() {
		provider = CXProvider(configuration: Self.makeConfiguration())
		super.init()
		provider.setDelegate(self, queue: .main)
		// v51: observe SYSTEM CXEnd that may skip perform(CXEndCallAction)
		// (jetsam / silent drop). Sticky End under busy-guard → soft-reassert.
		controller.callObserver.setDelegate(self, queue: .main)
	}

	/// Drop a stale CXProvider (old icon / dual-handle chrome) and build a
	/// fresh one before the next Incoming. CallKit can keep a previous call's
	/// identity across process death when the UUID is reused.
	///
	/// B35: waits for zombie `CXEndCallAction` to finish (or timeout) before
	/// invalidating, then settles briefly so InCallService releases dual-header
	/// chrome before the next `reportNewIncomingCall`.
	/// True when CallKit still holds a non-ended call (ringing or connected).
	///
	/// **v32:** Do NOT treat `callIds` alone as live. SYSTEM sticky CXEnd keeps
	/// `stickyPrimaryUUID` + snapshot for soft-reassert but must clear `callIds`;
	/// a leftover `callIds` entry made this return true forever → chrome-rescue /
	/// soft-reassert DEFER skipped → after-b Home idle (v27–v31).
	func hasLiveCallKitCall() -> Bool {
		if controller.callObserver.calls.contains(where: { !$0.hasEnded }) { return true }
		// Report in-flight: identity booked before observer lists the UUID.
		if !callIds.isEmpty, controller.callObserver.calls.isEmpty { return true }
		return false
	}

	/// True after the user (or debug) answered — shell in-call UI owns the
	/// foreground. Ringing-only chrome paths (force-suspend / Incoming refresh)
	/// must leave answered calls alone (v87: Accept → brief in-call → suspend
	/// loop via becameActive `scheduleForceSuspendRetries`).
	func hasAnsweredLiveCall() -> Bool {
		if !answeredCallUUIDs.isEmpty { return true }
		if BeamioInCallScreenModel.shared.live { return true }
		return controller.callObserver.calls.contains { call in
			!call.hasEnded && answeredCallUUIDs.contains(call.uuid)
		}
	}

	func recreateProvider(completion: (() -> Void)? = nil) {
		// Busy / multi-account: NEVER wipe a live Incoming/connected call.
		// DeepLink double-delivery used to recreate mid-ring and kill the first banner.
		// Also block on sticky even if observer briefly empty (openURL wake race).
		if hasLiveCallKitCall() || stickyPrimaryUUID != nil || stickyRingingSnapshot != nil {
			NSLog(
				"[BeamioCallKit] recreateProvider BLOCKED — live CallKit (callIds=%d observerLive=%d sticky=%@ snap=%@)",
				callIds.count,
				controller.callObserver.calls.filter { !$0.hasEnded }.count,
				stickyPrimaryUUID?.uuidString ?? "-",
				stickyRingingSnapshot?.callId ?? "-"
			)
			DispatchQueue.main.async { completion?() }
			return
		}
		NSLog("[BeamioCallKit] recreateProvider — end zombies, then invalidate + new CXProvider")
		// End FIRST while the provider is still valid. Invalidating before
		// CXEndCallAction leaves lock-screen dual-header chrome (EOA + @tag)
		// stuck with a piled Speaker/Mute/End grid.
		endZombieCalls(except: nil) { [weak self] in
			guard let self else {
				DispatchQueue.main.async { completion?() }
				return
			}
			if self.hasLiveCallKitCall() {
				NSLog("[BeamioCallKit] recreateProvider ABORT after zombies — live call appeared")
				DispatchQueue.main.async { completion?() }
				return
			}
			self.provider.invalidate()
			self.callIds.removeAll()
			self.answeredCallUUIDs.removeAll()
			self.pendingMediaStartUUID = nil
			self.clearOwnedIncomingTracking()
			self.provider = CXProvider(configuration: Self.makeConfiguration())
			self.provider.setDelegate(self, queue: .main)
			// Extra settle so system CallKit chrome releases before report.
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
				completion?()
			}
		}
	}

	/// Device QA: `beamio://debug-end-all` — tear down every CallKit call the
	/// system still holds (including sticky primary). Must **bypass**
	/// `recreateProvider`'s busy/sticky block — otherwise leftover Incoming
	/// makes end-all a no-op and the next debug-incoming is decline-only.
	func endAllCallsForDebug() {
		NSLog("[BeamioCallKit] debug-end-all (force)")
		pendingSoftReassertWorkItem?.cancel()
		pendingSoftReassertWorkItem = nil
		softReassertInFlight = false
		softReassertAttempt = 0
		cancelStickyHealProbes(reason: "debug-end-all")
		pendingChromeSuspendWorkItem?.cancel()
		pendingChromeSuspendWorkItem = nil
		restoreStickyChromeWorkItem?.cancel()
		restoreStickyChromeWorkItem = nil
		// Hold suspend during teardown so a late tag-applied cannot re-arm
		// CallKit chrome mid-end. finishOnce must clear this — leaving it
		// true permanently blocks every later report-ok suspend
		// (identity-timeout-blocked-v67 consumed=1) and collapses Incoming.
		chromeSuspendConsumed = true
		endIdentityBackgroundTask()

		// Mark every UUID intentional *before* clearing sticky so CXEnd does
		// not schedule soft-reassert / emit callRejected.
		var uuids = Set(callIds.keys)
		for call in controller.callObserver.calls where !call.hasEnded {
			uuids.insert(call.uuid)
		}
		if let sticky = stickyPrimaryUUID {
			uuids.insert(sticky)
		}
		for uuid in uuids {
			markIntentionallyEnding(uuid)
		}

		stickyPrimaryUUID = nil
		stickyPrimaryCallId = ""
		stickyRingingSnapshot = nil

		let group = DispatchGroup()
		for uuid in uuids {
			NSLog("[BeamioCallKit] debug-end-all end uuid=%@", uuid.uuidString)
			group.enter()
			let end = CXEndCallAction(call: uuid)
			controller.request(CXTransaction(action: end)) { [weak self] error in
				if let error {
					NSLog(
						"[BeamioCallKit] debug-end-all CXEnd fail uuid=%@ err=%@",
						uuid.uuidString,
						error.localizedDescription
					)
					self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
				}
				group.leave()
			}
			provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
			answeredCallUUIDs.remove(uuid)
			if pendingMediaStartUUID == uuid {
				pendingMediaStartUUID = nil
			}
			callIds.removeValue(forKey: uuid)
		}

		var finished = false
		let finishOnce: () -> Void = { [weak self] in
			guard !finished else { return }
			finished = true
			guard let self else { return }
			self.provider.invalidate()
			self.callIds.removeAll()
			self.answeredCallUUIDs.removeAll()
			self.pendingMediaStartUUID = nil
			self.clearOwnedIncomingTracking()
			self.intentionallyEndingUUIDs.removeAll()
			self.provider = CXProvider(configuration: Self.makeConfiguration())
			self.provider.setDelegate(self, queue: .main)
			// Re-arm chrome suspend for the next real inbound. Leaving
			// chromeSuspendConsumed=true after QA teardown made report-ok
			// hit identity-timeout-blocked forever (cancel-dismiss QA stuck).
			self.chromeSuspendConsumed = false
			self.clearBusyChromeGuard(reason: "debug-end-all")
			self.writeBusyQaBreadcrumb("debug-end-all-reset-consumed")
			NSLog("[BeamioCallKit] debug-end-all complete — provider recreated")
		}

		if uuids.isEmpty {
			DispatchQueue.main.async(execute: finishOnce)
		} else {
			group.notify(queue: .main, execute: finishOnce)
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: finishOnce)
		}
	}

	/// Audio CallKit chrome; calls are reported with `hasVideo = false`.
	/// `supportsVideo = true` only enables the in-call Video button: tapping it
	/// unlocks, opens Beamio with a start-call intent, and
	/// `BeamioCallKitVideoButton` turns on video in the Beamio call screen.
	/// Icon: `BeamioCallKitIcon` (40pt, pure white RGB + alpha). Masks that are
	/// not true white-alpha templates make FaceTime show "?" and, together
	/// with dual-identity headers, collapse the bottom Speaker/Mute/End grid
	/// into a corner pile on SE — keep the asset white-alpha only.
	private static func makeConfiguration() -> CXProviderConfiguration {
		// iOS 14+: use default init (localizedName initializer is deprecated).
		let configuration = CXProviderConfiguration()
		configuration.supportsVideo = true
		// One answered/ringing call per group. Allow a *second* call group so the
		// busy-reject path can satisfy PushKit (`reportNewIncomingCall`) and
		// instantly `declinedElsewhere` without displacing the live ringing call.
		// With `maximumCallGroups = 1`, a second report was ending the first
		// CallKit banner (jitter / empty SpringBoard after multi-account dial).
		configuration.maximumCallsPerCallGroup = 1
		configuration.maximumCallGroups = 2
		configuration.supportedHandleTypes = [.generic]
		// White-alpha template drawn from the app logo (ring + "B"). Falls back
		// to the system default when the asset is missing.
		configuration.iconTemplateImageData = callKitIconTemplatePNG()
		if #available(iOS 11.0, *) {
			configuration.includesCallsInRecents = false
		}
		return configuration
	}

	/// The asset catalog stores the icon as gray+alpha, and `pngData()` keeps
	/// that encoding. Redraw it into an RGBA bitmap so CallKit gets a plain
	/// white + alpha PNG.
	private static func callKitIconTemplatePNG() -> Data? {
		guard let image = UIImage(named: "BeamioCallKitIcon")?.withRenderingMode(.alwaysOriginal) else {
			NSLog("[BeamioCallKit] icon template missing — system default")
			return nil
		}
		let format = UIGraphicsImageRendererFormat()
		format.opaque = false
		format.scale = image.scale
		format.preferredRange = .standard
		let data = UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in
			image.draw(at: .zero)
		}
		NSLog(
			"[BeamioCallKit] icon template %.0fx%.0f@%.0fx bytes=%d",
			image.size.width,
			image.size.height,
			image.scale,
			data.count
		)
		return data
	}

	/// First PushKit report stays opaque `"Beamio"`. Once a verified `@BeamioTag`
	/// (or short address) is known, soft-reassert / second `reportNewIncomingCall`
	/// must keep that label — blindly returning `"Beamio"` wiped the tag after a
	/// successful `updateVerifiedIdentity` (SE banner stuck on app filler).
	private static func callKitDisplayLabel(_ raw: String) -> String {
		let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		if let tag = BeamioIncomingCallPayload.normalizedBeamioTag(t) {
			return tag
		}
		// Short address / capsule already painted as the CallKit handle.
		if !t.isEmpty, t != "Beamio", looksLikeAddressCapsule(t) {
			return String(t.prefix(64))
		}
		return "Beamio"
	}

	/// Verified identity while ringing: replace opaque first-report `"Beamio"`
	/// with `@BeamioTag` (or short address).
	///
	/// First report only sets `remoteHandle` (see `makeAudioOnlyUpdate`). Compact
	/// CallKit on SE paints that handle as the primary title when
	/// `localizedCallerName` was never set — so the update **must** change
	/// `remoteHandle` only. Setting **both** `remoteHandle` and
	/// `localizedCallerName` (even to the same `@tag`) still allocates two
	/// header columns on SE and can leave the banner stuck on app filler
	/// `"Beamio"` instead of the tag. Never assign `localizedCallerName` /
	/// `nil` here (nil marks “updated to empty” and blocks later refresh).
	private static func makeVerifiedIdentityUpdate(tag: String, shortAddress: String) -> CXCallUpdate {
		let update = CXCallUpdate()
		let short = shortAddress.trimmingCharacters(in: .whitespacesAndNewlines)
		let title: String = {
			if let normalized = BeamioIncomingCallPayload.normalizedBeamioTag(tag) {
				return normalized
			}
			if !short.isEmpty { return short }
			return "Beamio"
		}()
		update.remoteHandle = CXHandle(type: .generic, value: title)
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
		// columns and piles Speaker/Mute/End. Only set the handle; leave
		// localizedCallerName unset (do not assign nil — that marks an
		// “empty name” update and blocks later title refresh).
		update.remoteHandle = CXHandle(type: .generic, value: display)
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
		// Never tear down the sticky primary Incoming/connected call — a busy
		// second report used to false-negative here and kill call A → Home idle.
		if let sticky = stickyPrimaryUUID {
			uuids.remove(sticky)
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
			markIntentionallyEnding(uuid)
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

	/// True when another incoming/outgoing CallKit call is ringing or connected.
	/// Same `callId` re-delivery does **not** count as busy.
	func isBusyExcluding(callId: String, sessionId: String = "") -> Bool {
		for uuid in answeredCallUUIDs {
			if let id = callIds[uuid], matches(id, callId: callId, sessionId: sessionId) {
				continue
			}
			NSLog(
				"[BeamioCallKit] busy — answered uuid=%@ (excluding callId=%@)",
				uuid.uuidString,
				callId
			)
			return true
		}
		for call in controller.callObserver.calls where !call.hasEnded {
			if let id = callIds[call.uuid], matches(id, callId: callId, sessionId: sessionId) {
				continue
			}
			NSLog(
				"[BeamioCallKit] busy — live CXCall uuid=%@ outgoing=%@ (excluding callId=%@)",
				call.uuid.uuidString,
				call.isOutgoing ? "yes" : "no",
				callId
			)
			return true
		}
		for (uuid, id) in callIds {
			if matches(id, callId: callId, sessionId: sessionId) { continue }
			if let call = controller.callObserver.calls.first(where: { $0.uuid == uuid }),
			   call.hasEnded
			{
				continue
			}
			NSLog(
				"[BeamioCallKit] busy — mapped callId=%@ uuid=%@ outgoing=%@ (excluding callId=%@)",
				id.callId,
				uuid.uuidString,
				id.isOutgoing ? "yes" : "no",
				callId
			)
			return true
		}
		return false
	}

	/// Second inbound while ringing/connected: **keep the live CallKit UI**.
	///
	/// Device QA (build 7): `reportNewIncomingCall` + instant `.declinedElsewhere`
	/// still tore down the *first* ringing banner (after-b → Home idle) even with
	/// `maximumCallGroups = 2`. So non-PushKit paths **skip CallKit entirely** —
	/// signaling + `emitToWeb(callRejected)` still run from `reportIncomingCallKit`.
	///
	/// PushKit **must** call `reportNewIncomingCall` before its completion; then
	/// end **only** that new UUID via `CXEndCallAction` (never `endZombieCalls`,
	/// never add to `callIds`).
	func reportIncomingBusyReject(
		callId: String,
		handle: String,
		sessionId: String = "",
		mustReportForPushKit: Bool = false,
		completion: ((Error?) -> Void)? = nil
	) {
		if !mustReportForPushKit {
			NSLog(
				"[BeamioCallKit] busy-reject SKIP CallKit callId=%@ sticky=%@ sessionId=%@ (keep live)",
				callId,
				stickyPrimaryCallId.isEmpty ? "-" : stickyPrimaryCallId,
				sessionId
			)
			// v46: no CXCallUpdate revive while sticky LIVE (v40–v44 killed A).
			// preserveStickyChromeAfterBusySync → resuspend-only + DEAD probe.
			armBusyChromeGuard(reason: "busy-skip-\(callId)", seconds: 30)
			cancelPendingChromeSuspend(reason: "busy-skip")
			preserveStickyChromeAfterBusySync(reason: "busy-skip-\(callId)")
			DispatchQueue.main.async { completion?(nil) }
			return
		}

		let display = Self.callKitDisplayLabel(handle)
		let uuid = UUID()
		let update = Self.makeAudioOnlyUpdate(displayHandle: display)
		NSLog(
			"[BeamioCallKit] busy-reject PushKit report callId=%@ sessionId=%@ uuid=%@ handle=%@",
			callId,
			sessionId,
			uuid.uuidString,
			display
		)
		// Do NOT endZombieCalls — that was ending the first ringing call (jitter).
		// Do NOT add uuid to callIds (would make isBusyExcluding sticky forever).
		provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
			guard let self else {
				DispatchQueue.main.async { completion?(error) }
				return
			}
			if let error {
				NSLog(
					"[BeamioCallKit] busy-reject report FAILED callId=%@ err=%@ (live call kept)",
					callId,
					error.localizedDescription
				)
				self.preserveOrReassertStickyIncoming(
					reason: "busy-pushkit-fail",
					allowForceSuspend: false
				)
				DispatchQueue.main.async { completion?(error) }
				return
			}
			// End only this UUID. Avoid `.declinedElsewhere` — SE build 7 showed it
			// collapsing the first ringing group. Brief delay lets CallKit attach
			// the spare group before CXEndCallAction.
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
				guard let self else {
					completion?(nil)
					return
				}
				self.markIntentionallyEnding(uuid)
				let end = CXEndCallAction(call: uuid)
				self.controller.request(CXTransaction(action: end)) { [weak self] endErr in
					guard let self else {
						completion?(nil)
						return
					}
					if let endErr {
						NSLog(
							"[BeamioCallKit] busy-reject CXEnd FAILED uuid=%@ err=%@ — fallback reportCall",
							uuid.uuidString,
							endErr.localizedDescription
						)
						self.provider.reportCall(
							with: uuid,
							endedAt: Date(),
							reason: .failed
						)
					} else {
						NSLog(
							"[BeamioCallKit] busy-reject CXEnd OK callId=%@ uuid=%@ (kept existing)",
							callId,
							uuid.uuidString
						)
					}
					// v14: no forceSuspend after PushKit flash — same thrash as busy-skip.
					self.preserveOrReassertStickyIncoming(
						reason: "busy-flash",
						allowForceSuspend: false
					)
					completion?(nil)
				}
			}
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
		mustReportForPushKit: Bool = false,
		completion: ((Error?) -> Void)? = nil
	) {
		let display = Self.callKitDisplayLabel(handle)
		if let existing = callIds.first(where: { matches($0.value, callId: callId, sessionId: sessionId) }) {
			let sameCallId = !callId.isEmpty && existing.value.callId == callId
			let observerAlive = controller.callObserver.calls.contains {
				$0.uuid == existing.key && !$0.hasEnded
			}
			let anyLiveSame = hasLiveIncoming(forCallId: callId, sessionId: sessionId)
			// Only short-circuit a true re-delivery of the SAME call while CallKit
			// still shows it. A stale map entry (Decline race) or a new callId that
			// only shared sessionId must not pretend success without a new UI.
			if sameCallId, observerAlive || anyLiveSame {
				rememberOwnedIncoming(uuid: existing.key, callId: callId)
				if BeamioNativeVoiceSignaling.wasRemoteEnded(callId: callId, sessionId: sessionId) {
					NSLog(
						"[BeamioCallKit] same-call re-delivery but remoteEnded callId=%@ — tear",
						callId
					)
					writeBusyQaBreadcrumb("same-call-remote-ended-tear:\(callId)")
					DispatchQueue.main.async { [weak self] in
						self?.end(callId: callId, sessionId: sessionId)
						completion?(nil)
					}
					return
				}
				let locked = existing.value.displayHandle
				// Same-call re-delivery used to SKIP any handle change while
				// CallKit stayed LIVE — that locked the banner on opaque
				// "Beamio" forever after a first opaque report, even when the
				// second delivery already carried `@BeamioTag`.
				if let tag = BeamioIncomingCallPayload.normalizedBeamioTag(display),
				   tag != locked
					|| !existing.value.verifiedBeamioTagApplied
					|| existing.value.chromeTitle != tag
				{
					NSLog(
						"[BeamioCallKit] same-call → paint @BeamioTag callId=%@ uuid=%@ locked=%@ tag=%@",
						callId,
						existing.key.uuidString,
						locked,
						tag
					)
					updateVerifiedIdentityOnMain(
						callId: callId,
						sessionId: sessionId,
						tag: tag,
						shortAddress: ""
					)
				} else if display != locked {
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
				if stickyPrimaryUUID == nil {
					adoptStickyPrimary(uuid: existing.key, callId: callId)
				}
				if !observerAlive, anyLiveSame {
					writeBusyQaBreadcrumb(
						"same-call-keep-inflight:\(callId):uuid=\(existing.key.uuidString)"
					)
				}
				DispatchQueue.main.async { completion?(nil) }
				return
			}
			// v84/v86: same callId map, observer not attached, CallKit not live.
			// Keep-inflight ONLY while reportNewIncomingCall is still pending
			// (true PushKit race: map written before observer attaches).
			// After completion + CallKit dead (flash-hide / system dismiss), soft
			// re-delivery must clear the map and fall through to a fresh report —
			// otherwise soft-recent-dead-rereport crumbs forever with ck=false.
			if sameCallId, !observerAlive, !anyLiveSame {
				let pendingAge = pendingIncomingReportStartedAt[existing.key]
					.map { CFAbsoluteTimeGetCurrent() - $0 }
				if let age = pendingAge, age < 1.5 {
					rememberOwnedIncoming(uuid: existing.key, callId: callId)
					writeBusyQaBreadcrumb(
						"stale-map-keep-inflight:\(callId):uuid=\(existing.key.uuidString):age=\(String(format: "%.2f", age))"
					)
					NSLog(
						"[BeamioCallKit] same-call map keep-inflight (pending report) callId=%@ uuid=%@ age=%.2f",
						callId,
						existing.key.uuidString,
						age
					)
					if stickyPrimaryUUID == nil {
						adoptStickyPrimary(uuid: existing.key, callId: callId)
					}
					DispatchQueue.main.async { completion?(nil) }
					return
				}
				writeBusyQaBreadcrumb(
					"stale-map-dead-rereport:\(callId):uuid=\(existing.key.uuidString)"
				)
				NSLog(
					"[BeamioCallKit] same-call map DEAD — clear and re-report callId=%@ uuid=%@",
					callId,
					existing.key.uuidString
				)
				clearStickyPrimary(uuid: existing.key)
				callIds.removeValue(forKey: existing.key)
				answeredCallUUIDs.remove(existing.key)
				forgetOwnedIncoming(uuid: existing.key)
				pendingIncomingReportStartedAt.removeValue(forKey: existing.key)
				// Fall through to fresh UUID + reportNewIncomingCall.
			} else {
			NSLog(
				"[BeamioCallKit] stale map hit callId=%@ mapCallId=%@ alive=%@ — end then re-report",
				callId,
				existing.value.callId,
				observerAlive ? "yes" : "no"
			)
			clearStickyPrimary(uuid: existing.key)
			callIds.removeValue(forKey: existing.key)
			answeredCallUUIDs.remove(existing.key)
			forgetOwnedIncoming(uuid: existing.key)
			pendingIncomingReportStartedAt.removeValue(forKey: existing.key)
			}
		}
		// v80: tear orphan / remote-ended sticky before busy gate (invisible
		// sticky UUID was auto-declining every FG dial via busy-pushkit).
		_ = clearGhostStickyBlockingNewReport(
			reason: "pre-reportIncoming",
			incomingCallId: callId,
			incomingSessionId: sessionId
		)
		// Sticky primary OR any other live CallKit → busy-reject (keep first call).
		if isStickyOrBusyExcluding(callId: callId, sessionId: sessionId) {
			reportIncomingBusyReject(
				callId: callId,
				handle: handle,
				sessionId: sessionId,
				mustReportForPushKit: mustReportForPushKit,
				completion: completion
			)
			return
		}
		// The map entry is written only after the async zombie sweep below, so
		// a second delivery of the same call (VoIP push + alert push arrive
		// within a millisecond) would pass the map check above and report a
		// second CallKit call. Join it to the report already in flight.
		let inflightKey = callId.isEmpty ? sessionId : callId
		if !inflightKey.isEmpty {
			if let running = inflightIncomingReports[inflightKey],
			   CFAbsoluteTimeGetCurrent() - running.startedAt < 10
			{
				inflightIncomingReports[inflightKey]?.waiters.append(completion)
				NSLog(
					"[BeamioCallKit] reportIncoming joined in-flight report callId=%@ pushKit=%@",
					callId,
					mustReportForPushKit ? "yes" : "no"
				)
				writeBusyQaBreadcrumb("report-join-inflight:\(callId)")
				return
			}
			inflightIncomingReports[inflightKey] = (CFAbsoluteTimeGetCurrent(), [])
		}
		let callerCompletion = completion
		let completion: ((Error?) -> Void)? = { [weak self] error in
			let waiters = inflightKey.isEmpty
				? []
				: (self?.inflightIncomingReports.removeValue(forKey: inflightKey)?.waiters ?? [])
			callerCompletion?(error)
			waiters.forEach { $0?(error) }
		}
		// B35: ALWAYS a fresh UUID. Deterministic uuid(forCallId:) + async zombie
		// end let Answer attach to orphan dual-header chrome (EOA + @tag) with
		// Speaker/Mute/End piled bottom-left.
		let uuid = UUID()
		// When `handle` is already a verified `@BeamioTag` (soft empty-push /
		// applyKnownTag path), first-report with that tag — do not start opaque
		// "Beamio" and hope a later CXCallUpdate wins the race on SE.
		let knownFirstTag = BeamioIncomingCallPayload.normalizedBeamioTag(display)
		let update: CXCallUpdate = {
			if let tag = knownFirstTag {
				return Self.makeVerifiedIdentityUpdate(tag: tag, shortAddress: "")
			}
			return Self.makeAudioOnlyUpdate(displayHandle: display)
		}()
		let doReport: () -> Void = { [weak self] in
			guard let self else {
				DispatchQueue.main.async { completion?(nil) }
				return
			}
			// Race: another call may have become sticky while zombies ended.
			if self.isStickyOrBusyExcluding(callId: callId, sessionId: sessionId) {
				NSLog(
					"[BeamioCallKit] reportIncoming aborted — became busy before report callId=%@",
					callId
				)
				self.reportIncomingBusyReject(
					callId: callId,
					handle: handle,
					sessionId: sessionId,
					mustReportForPushKit: mustReportForPushKit,
					completion: completion
				)
				return
			}
			var firstIdentity = CallIdentity(
				callId: callId,
				sessionId: sessionId,
				displayHandle: display,
				chromeTitle: display
			)
			if knownFirstTag != nil {
				firstIdentity.verifiedIdentityApplied = true
				firstIdentity.verifiedBeamioTagApplied = true
			}
			self.callIds[uuid] = firstIdentity
			self.pendingIncomingReportStartedAt[uuid] = CFAbsoluteTimeGetCurrent()
			// v84: pin ownedIncoming before reportNewIncomingCall so a racing
			// soft clearGhost can heal/protect instead of tearing unmapped LIVE.
			self.rememberOwnedIncoming(uuid: uuid, callId: callId)
			NSLog(
				"[BeamioCallKit] reportIncoming callId=%@ sessionId=%@ uuid=%@ handle=%@",
				callId,
				sessionId,
				uuid.uuidString,
				display
			)
			if knownFirstTag != nil {
				self.writeBusyQaBreadcrumb(
					"callkit-tag-painted:\(display):\(callId):first-report"
				)
			}
			self.provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
				guard let self else {
					completion?(error)
					return
				}
				self.pendingIncomingReportStartedAt.removeValue(forKey: uuid)
				if let error {
					let ns = error as NSError
					NSLog(
						"[BeamioCallKit] reportIncoming FAILED callId=%@ uuid=%@ error=%@ code=%ld — retry after zombies",
						callId,
						uuid.uuidString,
						error.localizedDescription,
						ns.code
					)
					self.callIds.removeValue(forKey: uuid)
					// Only when we are NOT already busy with a live / sticky call.
					if self.isStickyOrBusyExcluding(callId: callId, sessionId: sessionId) {
						NSLog(
							"[BeamioCallKit] reportIncoming FAILED while busy — skip zombie retry callId=%@",
							callId
						)
						completion?(error)
						return
					}
					self.endZombieCalls(except: nil) { [weak self] in
						guard let self else {
							completion?(error)
							return
						}
						if self.isStickyOrBusyExcluding(callId: callId, sessionId: sessionId) {
							completion?(error)
							return
						}
						let retryUuid = UUID()
						var retryIdentity = CallIdentity(
							callId: callId,
							sessionId: sessionId,
							displayHandle: display,
							chromeTitle: display
						)
						if knownFirstTag != nil {
							retryIdentity.verifiedIdentityApplied = true
							retryIdentity.verifiedBeamioTagApplied = true
						}
						self.callIds[retryUuid] = retryIdentity
						self.pendingIncomingReportStartedAt[retryUuid] = CFAbsoluteTimeGetCurrent()
						self.rememberOwnedIncoming(uuid: retryUuid, callId: callId)
						self.provider.reportNewIncomingCall(
							with: retryUuid,
							update: update
						) { [weak self] retryError in
							guard let self else {
								completion?(retryError)
								return
							}
							self.pendingIncomingReportStartedAt.removeValue(forKey: retryUuid)
							if let retryError {
								NSLog(
									"[BeamioCallKit] reportIncoming RETRY FAILED callId=%@ err=%@",
									callId,
									retryError.localizedDescription
								)
								self.callIds.removeValue(forKey: retryUuid)
								completion?(retryError)
								return
							}
							self.rememberOwnedIncoming(uuid: retryUuid, callId: callId)
							NSLog(
								"[BeamioCallKit] reportIncoming RETRY OK callId=%@ uuid=%@",
								callId,
								retryUuid.uuidString
							)
							let remoteEnded = BeamioNativeVoiceSignaling.wasRemoteEnded(
								callId: callId,
								sessionId: sessionId
							)
							if remoteEnded {
								NSLog(
									"[BeamioCallKit] RETRY OK but remoteEnded callId=%@ — tear without sticky/suspend",
									callId
								)
								self.writeBusyQaBreadcrumb("retry-ok-remote-ended-tear:\(callId)")
								self.end(callId: callId, sessionId: sessionId)
								completion?(nil)
								return
							}
							self.adoptStickyPrimary(uuid: retryUuid, callId: callId)
							if !self.isBusyChromeGuardActive() {
								self.chromeSuspendConsumed = false
							}
							self.scheduleSuspendAfterIdentityOrTimeout(reason: "retry-ok")
							completion?(nil)
						}
					}
					return
				}
				self.rememberOwnedIncoming(uuid: uuid, callId: callId)
				NSLog("[BeamioCallKit] reportIncoming OK callId=%@ uuid=%@", callId, uuid.uuidString)
				// iOS makes a VoIP push report a call at once, so the caller can
				// cancel before this report exists. The cancel was recorded when it
				// arrived; clear the call that has just been shown.
				//
				// Cancel linger / flash: when remoteEnded is already true (chat
				// voice_end raced ahead of PushKit action=end orphan report), do
				// NOT adopt sticky and do NOT scheduleSuspend — those kept
				// full-screen CallKit chrome after the browser Hang Up.
				// A PushKit re-delivery of a call this device already declined or
				// hung up must be reported (Apple rule) but is over: tear it too.
				let remoteEnded = BeamioNativeVoiceSignaling.wasRemoteEnded(
					callId: callId,
					sessionId: sessionId
				) || BeamioNativeVoiceSignaling.wasLocallyEnded(callId: callId, sessionId: sessionId)
				BeamioNativeVoiceSignaling.qaTrail(
					"call reported callId=\(callId.prefix(8)) remoteEnded=\(remoteEnded)"
				)
				if remoteEnded {
					NSLog(
						"[BeamioCallKit] caller already ended callId=%@ — tear just-reported without sticky/suspend",
						callId
					)
					self.writeBusyQaBreadcrumb("report-ok-remote-ended-tear:\(callId)")
					let tear = { [weak self] in
						self?.end(callId: callId, sessionId: sessionId)
						completion?(nil)
					}
					if Thread.isMainThread {
						tear()
					} else {
						DispatchQueue.main.async(execute: tear)
					}
					return
				}
				self.adoptStickyPrimary(uuid: uuid, callId: callId)
				// New primary report needs a fresh chrome suspend. Busy-cancel
				// and debug-end-all set chromeSuspendConsumed=true; without a
				// reset here scheduleSuspendAfterIdentityOrTimeout permanently
				// early-returns (identity-timeout-blocked consumed=1) and the
				// Incoming UI stays a collapsed strip / fails cancel QA.
				if !self.isBusyChromeGuardActive() {
					self.chromeSuspendConsumed = false
				}
				self.scheduleSuspendAfterIdentityOrTimeout(reason: "report-ok")
				completion?(nil)
			}
		}
		// Wait for zombie CXEndCallAction before report — fire-and-forget left
		// dual-identity chrome alive for the next Answer. sticky is protected.
		endZombieCalls(except: uuid, completion: doReport)
	}

	/// After opaque first report: `reportCall(updated:)` with BeamioTag as the
	/// sole CallKit title (system ringtone already playing from first report).
	/// Short-address updates may run first; a later real `@BeamioTag` still
	/// upgrades CallKit once.
	///
	/// Must run on the main queue — `reportNewIncomingCall` / resolve completions
	/// often arrive off-main; CallKit silently drops off-main `reportCall(updated:)`.
	func updateVerifiedIdentity(callId: String, sessionId: String, tag: String, shortAddress: String) {
		if !Thread.isMainThread {
			DispatchQueue.main.async { [weak self] in
				self?.updateVerifiedIdentity(
					callId: callId,
					sessionId: sessionId,
					tag: tag,
					shortAddress: shortAddress
				)
			}
			return
		}
		updateVerifiedIdentityOnMain(
			callId: callId,
			sessionId: sessionId,
			tag: tag,
			shortAddress: shortAddress
		)
	}

	private func updateVerifiedIdentityOnMain(
		callId: String,
		sessionId: String,
		tag: String,
		shortAddress: String
	) {
		var existing = callIds.first(where: { matches($0.value, callId: callId, sessionId: sessionId) })
		// Offer JSON callId can differ from PushKit registration keys. If the
		// map miss, paint the sole still-ringing Incoming so @BeamioTag is not
		// dropped by a key mismatch.
		if existing == nil {
			let ringing = callIds.filter { entry in
				!entry.value.isOutgoing
					&& controller.callObserver.calls.contains {
						$0.uuid == entry.key && !$0.hasEnded && !$0.hasConnected
					}
			}
			if ringing.count == 1, let only = ringing.first {
				existing = only
				NSLog(
					"[BeamioCallKit] updateVerifiedIdentity — map miss callId=%@, using sole ringing uuid=%@",
					callId,
					only.key.uuidString
				)
			}
		}
		let rawTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
		let short = shortAddress.trimmingCharacters(in: .whitespacesAndNewlines)
		let normalizedTag = BeamioIncomingCallPayload.normalizedBeamioTag(rawTag)
		let hasRealTag = normalizedTag != nil
		guard hasRealTag || !short.isEmpty else {
			NSLog("[BeamioCallKit] updateVerifiedIdentity skip — empty tag/short %@", callId)
			return
		}
		let paintedPreview = hasRealTag ? (normalizedTag ?? rawTag) : short
		// Even with no live CallKit UUID (system CXEnd cleared callIds), stash
		// @BeamioTag onto sticky snap so the next soft-reassert paints it.
		if existing == nil {
			if var snap = stickyRingingSnapshot,
			   matches(snap, callId: callId, sessionId: sessionId)
				|| (!sessionId.isEmpty && snap.sessionId == sessionId)
			{
				if !snap.verifiedBeamioTagApplied || snap.chromeTitle != paintedPreview {
					snap.chromeTitle = paintedPreview
					snap.verifiedIdentityApplied = true
					if hasRealTag { snap.verifiedBeamioTagApplied = true }
					stickyRingingSnapshot = snap
					NSLog(
						"[BeamioCallKit] updateVerifiedIdentity — no live uuid; sticky snap tagged %@",
						paintedPreview
					)
				}
			} else {
				NSLog("[BeamioCallKit] updateVerifiedIdentity — no active call for %@", callId)
			}
			return
		}
		guard let existing else { return }
		// Soft-reassert / busy wake can wipe the visual CallKit title while the
		// map still has verifiedBeamioTagApplied. Always re-issue CXCallUpdate
		// when we have a real @BeamioTag and chrome/display is not already that
		// tag — never hard-skip just because the flag is set.
		if existing.value.verifiedBeamioTagApplied, hasRealTag {
			let already = existing.value.chromeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
			let locked = existing.value.displayHandle.trimmingCharacters(in: .whitespacesAndNewlines)
			if already == paintedPreview, locked == paintedPreview {
				NSLog(
					"[BeamioCallKit] updateVerifiedIdentity — @BeamioTag already painted %@",
					callId
				)
				return
			}
			NSLog(
				"[BeamioCallKit] updateVerifiedIdentity — re-paint @BeamioTag (chrome mismatch) callId=%@ chrome=%@ locked=%@ want=%@",
				callId,
				already.isEmpty ? "-" : already,
				locked.isEmpty ? "-" : locked,
				paintedPreview
			)
		} else if existing.value.verifiedIdentityApplied, !hasRealTag {
			NSLog("[BeamioCallKit] updateVerifiedIdentity skip — already applied (awaiting tag) %@", callId)
			return
		}
		let update = Self.makeVerifiedIdentityUpdate(
			tag: normalizedTag ?? rawTag,
			shortAddress: short
		)
		let paintedTitle = update.remoteHandle?.value
			?? (hasRealTag ? (normalizedTag ?? rawTag) : short)
		callIds[existing.key]?.verifiedIdentityApplied = true
		callIds[existing.key]?.chromeTitle = paintedTitle
		if hasRealTag {
			callIds[existing.key]?.verifiedBeamioTagApplied = true
			callIds[existing.key]?.displayHandle = paintedTitle
		}
		// Keep sticky snap in sync so soft-reassert / CXEnd revive keep @BeamioTag
		// instead of re-painting opaque "Beamio".
		if var snap = stickyRingingSnapshot,
		   matches(snap, callId: callId, sessionId: sessionId)
			|| matches(snap, callId: existing.value.callId, sessionId: existing.value.sessionId)
			|| stickyPrimaryUUID == existing.key
		{
			snap.chromeTitle = paintedTitle
			snap.verifiedIdentityApplied = true
			if hasRealTag {
				snap.verifiedBeamioTagApplied = true
				snap.displayHandle = paintedTitle
			}
			stickyRingingSnapshot = snap
		} else if stickyRingingSnapshot == nil,
		          let painted = callIds[existing.key]
		{
			stickyRingingSnapshot = painted
		}
		provider.reportCall(with: existing.key, updated: update)
		NSLog(
			"[BeamioCallKit] reportCall(updated:) uuid=%@ handle=%@ localized=%@ tag=%@ short=%@",
			existing.key.uuidString,
			update.remoteHandle?.value ?? "-",
			update.localizedCallerName ?? "-",
			normalizedTag ?? (rawTag.isEmpty ? "-" : rawTag),
			short.isEmpty ? "-" : short
		)
		if hasRealTag {
			writeBusyQaBreadcrumb(
				"callkit-tag-painted:\(paintedTitle):\(callId)"
			)
			// Tag is on CallKit — suspend for full-screen chrome after a brief settle.
			noteVerifiedIdentityApplied(callId: callId)
		}
	}

	/// Keep the process awake long enough for Keychain + mailbox offer resolve,
	/// then suspend once for full CallKit chrome. Immediate suspend after the
	/// opaque first report was racing ahead of `updateVerifiedIdentity`.
	/// Cancel deferred / tag-applied private suspend. Busy second inbound must
	/// call this — otherwise report-ok/`tag-applied` suspend races openURL wake
	/// and tears down CallKit A → Home idle (v14 after-b).
	///
	/// v20: **do not** cancel `pendingSoftReassertWorkItem`. Busy openURL often
	/// kills sticky A via system CXEnd; soft-reassert is the only path back.
	/// Cancelling it left after-b as a white foreground shell with no CallKit.
	func cancelPendingChromeSuspend(reason: String) {
		// v48: while busy-guard is active, do **not** end identity/busy BG —
		// rejectSecondaryWhileBusy calls this then preserveStickyChrome…; ending
		// BG in the old main.async raced after begin and froze resuspend timers.
		let run: () -> Void = { [weak self] in
			guard let self else { return }
			let had = self.pendingChromeSuspendWorkItem != nil
			self.pendingChromeSuspendWorkItem?.cancel()
			self.pendingChromeSuspendWorkItem = nil
			let busyGuard = self.isBusyChromeGuardActive()
			if busyGuard {
				self.writeBusyQaBreadcrumb("cancel-pending-suspend-keep-bg:\(reason)")
			} else {
				self.endIdentityBackgroundTask()
				self.endBusyChromeBackgroundTask(reason: "cancel-pending-\(reason)")
			}
			// Mark consumed so a late tag-applied work item cannot re-suspend.
			// forceSuspend / scheduleForceSuspendRetries bypass this flag.
			self.chromeSuspendConsumed = true
			NSLog(
				"[BeamioCallKit] cancel pending chrome suspend reason=%@ hadPending=%@ busyGuard=%@ (soft-reassert kept)",
				reason,
				had ? "yes" : "no",
				busyGuard ? "yes" : "no"
			)
		}
		if Thread.isMainThread {
			run()
		} else {
			DispatchQueue.main.async(execute: run)
		}
	}

	/// After system CXEnd of sticky A, wait for CallKit to finish the End
	/// transaction before `reportNewIncomingCall` (v17 immediate race → Home).
	/// v21: `forceReplaceEvenIfAlive` — busy path replaces zombie sticky UUID
	/// even when callObserver still lists A as !hasEnded.
	private func scheduleDeferredSoftReassert(
		reason: String,
		delay: TimeInterval = 0.35,
		scheduleSuspendOnSuccess: Bool = true,
		forceReplaceEvenIfAlive: Bool = false
	) {
		pendingSoftReassertWorkItem?.cancel()
		let work = DispatchWorkItem { [weak self] in
			guard let self else { return }
			self.pendingSoftReassertWorkItem = nil
			self.writeBusyQaBreadcrumb("soft-reassert-deferred-fire:\(reason)")
			self.softReassertStickyKeepingProtection(
				reason: reason,
				scheduleSuspendOnSuccess: scheduleSuspendOnSuccess,
				forceReplaceEvenIfAlive: forceReplaceEvenIfAlive
			)
		}
		pendingSoftReassertWorkItem = work
		NSLog(
			"[BeamioCallKit] soft-reassert deferred %.2fs force=%@ reason=%@",
			delay,
			forceReplaceEvenIfAlive ? "yes" : "no",
			reason
		)
		writeBusyQaBreadcrumb(
			"soft-reassert-deferred-arm:\(String(format: "%.2f", delay)):\(reason)"
		)
		DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
	}

	private func cancelStickyHealProbes(reason: String) {
		guard !pendingStickyHealWorkItems.isEmpty else { return }
		let n = pendingStickyHealWorkItems.count
		pendingStickyHealWorkItems.forEach { $0.cancel() }
		pendingStickyHealWorkItems.removeAll()
		NSLog("[BeamioCallKit] cancel sticky heal probes n=%d reason=%@", n, reason)
	}

	/// v24/v25: busy openURL / soft-reassert skip-when-live leave a race where
	/// callObserver still lists sticky A as !hasEnded, then system CXEnd
	/// clears A with no follow-up → after-b Home idle. Probe across the busy
	/// window; dead sticky → soft-reassert (keep remaining probes); alive →
	/// one light suspend only.
	private func scheduleStickyHealProbes(reason: String) {
		cancelStickyHealProbes(reason: "rearm-\(reason)")
		// Cover QA wait after B (~8s) and late system CXEnd after openURL wake.
		let delays: [TimeInterval] = [0.35, 0.8, 1.5, 2.5, 4.0, 6.0, 8.5]
		NSLog(
			"[BeamioCallKit] sticky heal probes scheduled delays=%@ reason=%@",
			delays.map { String(format: "%.2f", $0) }.joined(separator: ","),
			reason
		)
		for (idx, delay) in delays.enumerated() {
			let work = DispatchWorkItem { [weak self] in
				guard let self else { return }
				self.runStickyHealProbe(reason: "\(reason)-h\(idx)", index: idx)
			}
			pendingStickyHealWorkItems.append(work)
			DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
		}
	}

	private func runStickyHealProbe(reason: String, index: Int) {
		_ = index
		let sticky = stickyPrimaryUUID
		let stickyAlive = sticky.map { uuid in
			controller.callObserver.calls.contains { $0.uuid == uuid && !$0.hasEnded }
		} ?? false
		let anyLive = hasLiveCallKitCall()
		NSLog(
			"[BeamioCallKit] sticky heal probe reason=%@ stickyAlive=%@ anyLive=%@ softInFlight=%@ attempt=%d",
			reason,
			stickyAlive ? "yes" : "no",
			anyLive ? "yes" : "no",
			softReassertInFlight ? "yes" : "no",
			softReassertAttempt
		)
		if stickyAlive {
			// v29: never force-suspend from heal — that collapses CallKit while
			// App is active (after-b). Leave sticky ringing alone.
			NSLog(
				"[BeamioCallKit] sticky heal leave-alone sticky LIVE reason=%@",
				reason
			)
			return
		}
		if softReassertInFlight || pendingSoftReassertWorkItem != nil {
			NSLog("[BeamioCallKit] sticky heal — soft-reassert already pending reason=%@", reason)
			return
		}
		guard stickyRingingSnapshot != nil || stickyPrimaryUUID != nil else {
			if !anyLive {
				NSLog("[BeamioCallKit] sticky heal — no snapshot/pointer, idle reason=%@", reason)
			}
			return
		}
		// v25/v29: keep probes; soft-reassert without suspend-on-success so
		// banner stays visible after report (busy after-b).
		NSLog("[BeamioCallKit] sticky heal — dead sticky → soft-reassert (no suspend) reason=%@", reason)
		scheduleDeferredSoftReassert(
			reason: "heal-\(reason)",
			delay: 0.05,
			scheduleSuspendOnSuccess: false,
			forceReplaceEvenIfAlive: false
		)
	}

	private func scheduleSuspendAfterIdentityOrTimeout(reason: String) {
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			// v67: this async used to force chromeSuspendConsumed=false and
			// re-arm an 18s private suspend after busy cancel. That lands in
			// the after-b window and drops the live Incoming banner (v66).
			if self.debugSelfProbeSuspendHold
				|| self.isBusyChromeGuardActive()
				|| self.chromeSuspendConsumed
			{
				self.pendingChromeSuspendWorkItem?.cancel()
				self.pendingChromeSuspendWorkItem = nil
				self.writeBusyQaBreadcrumb(
					"identity-timeout-blocked-v67:\(reason):hold=\(self.debugSelfProbeSuspendHold ? 1 : 0):guard=\(self.isBusyChromeGuardActive() ? 1 : 0):consumed=\(self.chromeSuspendConsumed ? 1 : 0):live=\(self.isStickyPrimaryStillLive() ? 1 : 0)"
				)
				return
			}
			self.chromeSuspendConsumed = false
			self.pendingChromeSuspendWorkItem?.cancel()
			self.beginIdentityBackgroundTaskIfNeeded()
			NSLog("[BeamioCallKit] defer suspend until tag/timeout reason=%@", reason)
			let work = DispatchWorkItem { [weak self] in
				self?.suspendForFullCallKitChrome(reason: "timeout-\(reason)")
			}
			self.pendingChromeSuspendWorkItem = work
			// voice_offer_fetch uses SiPost (≤3×~5s) + decrypt + tag lookup.
			// Ending the identity bg-task at 3.5s cancelled URLSession mid-POST
			// (status=0) so CallKit never left opaque "Beamio". Keep awake until
			// resolve finishes or this safety timeout.
			DispatchQueue.main.asyncAfter(deadline: .now() + 18.0, execute: work)
		}
	}

	private func noteVerifiedIdentityApplied(callId: String) {
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			if self.debugSelfProbeSuspendHold || self.isBusyChromeGuardActive() {
				self.pendingChromeSuspendWorkItem?.cancel()
				self.pendingChromeSuspendWorkItem = nil
				self.writeBusyQaBreadcrumb("tag-suspend-blocked-v67:\(callId)")
				return
			}
			// Busy second inbound may have cancelled chrome suspend — do not
			// re-arm tag-applied private suspend (would thrash CallKit A).
			guard !self.chromeSuspendConsumed else {
				self.writeBusyQaBreadcrumb("tag-suspend-skip-consumed:\(callId)")
				NSLog(
					"[BeamioCallKit] tag applied — skip suspend (already consumed) callId=%@",
					callId
				)
				return
			}
			self.pendingChromeSuspendWorkItem?.cancel()
			self.pendingChromeSuspendWorkItem = nil
			NSLog("[BeamioCallKit] tag applied — suspend soon callId=%@", callId)
			let work = DispatchWorkItem { [weak self] in
				self?.suspendForFullCallKitChrome(reason: "tag-applied")
			}
			self.pendingChromeSuspendWorkItem = work
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
		}
	}

	/// Resolve finished (hit or miss) — stop waiting on the 18s safety timeout
	/// and suspend for full CallKit chrome so the banner can show the update.
	func noteIdentityResolveFinished(callId: String, appliedTag: Bool) {
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			if self.debugSelfProbeSuspendHold || self.isBusyChromeGuardActive() || self.chromeSuspendConsumed {
				self.pendingChromeSuspendWorkItem?.cancel()
				self.pendingChromeSuspendWorkItem = nil
				self.writeBusyQaBreadcrumb(
					"resolve-suspend-blocked-v67:\(callId):tag=\(appliedTag ? 1 : 0):hold=\(self.debugSelfProbeSuspendHold ? 1 : 0):consumed=\(self.chromeSuspendConsumed ? 1 : 0)"
				)
				return
			}
			if appliedTag {
				self.noteVerifiedIdentityApplied(callId: callId)
				return
			}
			self.pendingChromeSuspendWorkItem?.cancel()
			self.pendingChromeSuspendWorkItem = nil
			NSLog("[BeamioCallKit] identity resolve done (no tag) — suspend soon callId=%@", callId)
			let work = DispatchWorkItem { [weak self] in
				self?.suspendForFullCallKitChrome(reason: "resolve-done")
			}
			self.pendingChromeSuspendWorkItem = work
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
		}
	}

	private func beginIdentityBackgroundTaskIfNeeded() {
		guard identityBackgroundTask == .invalid else { return }
		identityBackgroundTask = UIApplication.shared.beginBackgroundTask(
			withName: "BeamioCallKitIdentity"
		) { [weak self] in
			self?.endIdentityBackgroundTask()
		}
	}

	private func endIdentityBackgroundTask() {
		guard identityBackgroundTask != .invalid else { return }
		writeBusyQaBreadcrumb(
			"identity-bg-end:state=\(UIApplication.shared.applicationState.rawValue):hold=\(debugSelfProbeSuspendHold ? 1 : 0)"
		)
		UIApplication.shared.endBackgroundTask(identityBackgroundTask)
		identityBackgroundTask = .invalid
	}

	/// Suspend so system CallKit Incoming paints full-screen (not a collapsed
	/// banner). Soft-seed + VoIP must both do this — otherwise SE shows a tiny
	/// NC strip and Answer never reaches CXProvider.
	/// Call only after BeamioTag update **or** the identity timeout.
	private func suspendForFullCallKitChrome(reason: String) {
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			if self.debugSelfProbeSuspendHold {
				self.writeBusyQaBreadcrumb("suspend-held-self-probe:\(reason)")
				NSLog("[BeamioCallKit] suspend held for self-probe reason=%@", reason)
				return
			}
			// v88: Accept → in-call must not be private-suspended by late
			// tag-applied / resolve-done / identity-timeout (those bypass
			// forceSuspendToKeepLiveCallChrome and collapsed the shell UI).
			if self.hasAnsweredLiveCall() {
				self.writeBusyQaBreadcrumb("suspend-skip-answered:\(reason)")
				NSLog("[BeamioCallKit] suspend skipped answered (v88) reason=%@", reason)
				return
			}
			guard !self.chromeSuspendConsumed else {
				self.writeBusyQaBreadcrumb("suspend-skip-consumed:\(reason)")
				NSLog("[BeamioCallKit] suspend skipped (already) reason=%@", reason)
				return
			}
			self.chromeSuspendConsumed = true
			self.performChromeSuspendNow(reason: reason)
		}
	}

	/// Debug-only. Arms a RunLoop timer (not `asyncAfter` — that froze after
	/// private suspend in v62) and calls the PWA busy path in-process.
	func armDebugSelfProbePwa(primaryCallId: String) {
		assert(Thread.isMainThread)
		debugSelfProbeSuspendHold = true
		writeBusyQaBreadcrumb("self-probe-armed:\(primaryCallId)")
		if debugSelfProbeBgTask == .invalid {
			debugSelfProbeBgTask = UIApplication.shared.beginBackgroundTask(withName: "BeamioDebugSelfProbe") { [weak self] in
				self?.writeBusyQaBreadcrumb("self-probe-bg-expire")
			}
		}
		for timer in debugSelfProbeTimers {
			timer.invalidate()
		}
		debugSelfProbeTimers.removeAll()
		// v68: v67 died inside the busy early-return while the observer stayed
		// LIVE and no suspend/CXEnd ran. Split that body so one QA shows which
		// step drops the banner. Delays are from arm (report-ok).
		let stages: [(TimeInterval, String)] = [
			(12, "crumb"),
			(24, "paste"),
			(36, "preserve"),
			(48, "decline"),
			(60, "emit"),
		]
		for (delay, name) in stages {
			let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
				self?.runDebugProbeStage(name)
			}
			RunLoop.main.add(timer, forMode: .common)
			debugSelfProbeTimers.append(timer)
		}
	}

	/// One isolated slice of the busy early-return. Does not call
	/// `reportIncomingCallKit` (that bundled every slice in v65–v67).
	private func runDebugProbeStage(_ stage: String) {
		let live = hasLiveCallKitCall() ? 1 : 0
		let state = UIApplication.shared.applicationState.rawValue
		writeBusyQaBreadcrumb("probe-stage-v69-begin:\(stage):live=\(live):state=\(state)")
		let stamp = Int(Date().timeIntervalSince1970)
		let callId = "self-probe-b-\(stamp)"
		let sessionId = "self-probe-s-\(stamp)"
		switch stage {
		case "crumb":
			break
		case "paste":
			BeamioDeepLink.suppressPasteboardDeferredDeepLink(forSeconds: 30)
		case "preserve":
			armBusyChromeGuard(reason: "v68-preserve-\(callId)", seconds: 30)
			cancelPendingChromeSuspend(reason: "v68-preserve")
			preserveStickyChromeAfterBusySync(reason: "v68-preserve-\(callId)")
		case "decline":
			noteBusyDeclineProtectsChrome(callId: callId)
			BeamioNativeVoiceSignaling.sendDecline(
				callId: callId,
				sessionId: sessionId,
				reason: "busy",
				protectStickyChrome: true
			)
		case "emit":
			emitToWebWhenForeground("callRejected", callId: callId, sessionId: sessionId)
		default:
			break
		}
		writeBusyQaBreadcrumb(
			"probe-stage-v69-end:\(stage):live=\(hasLiveCallKitCall() ? 1 : 0):state=\(UIApplication.shared.applicationState.rawValue):bg=\(debugSelfProbeBgTask != .invalid ? 1 : 0):hold=\(debugSelfProbeSuspendHold ? 1 : 0)"
		)
	}

	/// While CallKit Incoming is on screen in the background, posting into
	/// WKWebView can wake the scene. Queue until the app is active.
	func emitToWebWhenForeground(_ action: String, callId: String, sessionId: String) {
		assert(Thread.isMainThread)
		let state = UIApplication.shared.applicationState
		if state == .active {
			emitToWeb(action, callId: callId, sessionId: sessionId)
			writeBusyQaBreadcrumb("emit-now:\(action):\(callId)")
			return
		}
		deferredForegroundWebEmits.append((action, callId, sessionId))
		writeBusyQaBreadcrumb("emit-deferred-bg:\(action):\(callId):state=\(state.rawValue)")
	}

	func noteBusyDeclineProtectsChrome(callId: String) {
		writeBusyQaBreadcrumb("decline-no-new-bg-v66:\(callId)")
	}

	func noteBusyDeclineDeferredNoWebView(callId: String) {
		writeBusyQaBreadcrumb("decline-deferred-no-webview-v69:\(callId)")
	}

	func flushDeferredForegroundWebEmits(reason: String) {
		assert(Thread.isMainThread)
		guard !deferredForegroundWebEmits.isEmpty else { return }
		let pending = deferredForegroundWebEmits
		deferredForegroundWebEmits.removeAll()
		for item in pending {
			emitToWeb(item.action, callId: item.callId, sessionId: item.sessionId)
			writeBusyQaBreadcrumb("emit-flush:\(reason):\(item.action):\(item.callId)")
		}
	}

	/// v26/v30/v33: self-wake `beamio://busy-chrome-rescue` so background
	/// `reportNewIncomingCall` can succeed after system CXEnd.
	///
	/// **v30:** Block ONLY while sticky A is LIVE (activate collapses CallKit).
	/// Sticky DEAD + snap → ALLOW activate even under busy-guard / with snap
	/// (v29 banned this → after-b Home idle).
	/// **v33:** openURL ok≠DeepLink delivered — arm 1.2s watchdog; if
	/// `handleBusyChromeRescue` never runs, clear inFlight and retry (≤3).
	func requestBusyChromeRescue(reason: String) {
		// v43: Call B openURL ends → process suspends before main.async fires.
		// When already on main (preserveStickyChromeAfterBusySync), run sync.
		let run: () -> Void = { [weak self] in
			guard let self else { return }
			if self.isStickyPrimaryStillLive() {
				// v44: NEVER activate while sticky LIVE (collapsed Incoming).
				// v54: chrome presumed-dead after Call B → ALLOW openURL so we
				// can reach ACTIVE and PRE-END+report A' (not CXCallUpdate).
				if self.busyChromePresumedDead {
					NSLog(
						"[BeamioCallKit] busy-chrome-rescue ALLOW sticky LIVE+presumedDead (v54) reason=%@",
						reason
					)
					self.writeBusyQaBreadcrumb("rescue-allow-live-presumed-dead:\(reason)")
					if UIApplication.shared.applicationState == .active {
						self.cancelBusyChromeRescueWatchdog()
						self.busyChromeRescueInFlight = false
						self.busyChromeRescueOpenAttempts = 0
						self.kickBusyZombieRescueIfNeeded(reason: "rescue-active-\(reason)")
						return
					}
					// fall through to openURL below
				} else {
					NSLog(
						"[BeamioCallKit] busy-chrome-rescue BLOCKED sticky LIVE absolute-noop (v44) reason=%@",
						reason
					)
					self.writeBusyQaBreadcrumb("rescue-blocked-live-noop:\(reason)")
					return
				}
			} else if self.hasLiveCallKitCall() {
				NSLog(
					"[BeamioCallKit] busy-chrome-rescue skip — live CallKit reason=%@",
					reason
				)
				return
			}
			guard self.stickyRingingSnapshot != nil || self.stickyPrimaryUUID != nil else {
				NSLog(
					"[BeamioCallKit] busy-chrome-rescue skip — no sticky snap reason=%@",
					reason
				)
				return
			}
			if UIApplication.shared.applicationState == .active {
				NSLog(
					"[BeamioCallKit] busy-chrome-rescue already active — restore reason=%@",
					reason
				)
				self.cancelBusyChromeRescueWatchdog()
				self.busyChromeRescueInFlight = false
				self.busyChromeRescueOpenAttempts = 0
				if self.busyChromePresumedDead, self.isStickyPrimaryStillLive() {
					self.kickBusyZombieRescueIfNeeded(reason: "rescue-active-\(reason)")
				} else {
					self.restoreStickyCallKitChrome(reason: "rescue-active-\(reason)")
				}
				return
			}
			let now = CFAbsoluteTimeGetCurrent()
			if self.busyChromeRescueInFlight, now - self.busyChromeRescueOpenedAt < 2.5 {
				NSLog(
					"[BeamioCallKit] busy-chrome-rescue coalesce reason=%@",
					reason
				)
				return
			}
			guard let url = URL(string: "beamio://busy-chrome-rescue") else {
				NSLog("[BeamioCallKit] busy-chrome-rescue URL build fail reason=%@", reason)
				self.restoreStickyCallKitChrome(reason: "rescue-urlfail-\(reason)")
				return
			}
			if self.busyChromeRescueOpenAttempts >= Self.busyChromeRescueMaxAttempts {
				NSLog(
					"[BeamioCallKit] busy-chrome-rescue CAP hit attempt=%d reason=%@ — abort storm",
					self.busyChromeRescueOpenAttempts,
					reason
				)
				self.abortSoftReassertStorm(
					reason: "rescue-cap-\(reason)",
					callId: self.stickyRingingSnapshot?.callId ?? ""
				)
				return
			}
			self.busyChromeRescueInFlight = true
			self.busyChromeRescueOpenedAt = now
			self.busyChromeRescueOpenAttempts += 1
			let attempt = self.busyChromeRescueOpenAttempts
			self.beginIdentityBackgroundTaskIfNeeded()
			// v57: openURL → becomeActive can fire pasteboard deferred deep-link
			// ("paste from Carol’s iMac"). Suppress until rescue settles.
			BeamioDeepLink.suppressPasteboardDeferredDeepLink(forSeconds: 8)
			NSLog(
				"[BeamioCallKit] busy-chrome-rescue openURL (activate) sticky=%@ attempt=%d reason=%@",
				self.isStickyPrimaryStillLive() ? "LIVE+heal" : "DEAD",
				attempt,
				reason
			)
			self.writeBusyQaBreadcrumb("rescue-openURL:\(reason):attempt=\(attempt)")
			self.armBusyChromeRescueWatchdog(attempt: attempt, reason: reason)
			UIApplication.shared.open(url, options: [:]) { [weak self] ok in
				guard let self else { return }
				if !ok {
					NSLog(
						"[BeamioCallKit] busy-chrome-rescue openURL refused attempt=%d reason=%@",
						attempt,
						reason
					)
					self.cancelBusyChromeRescueWatchdog()
					self.busyChromeRescueInFlight = false
					if attempt < Self.busyChromeRescueMaxAttempts {
						DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
							self?.requestBusyChromeRescue(reason: "open-fail-retry-\(attempt)-\(reason)")
						}
					} else {
						self.abortSoftReassertStorm(
							reason: "rescue-open-fail-\(reason)",
							callId: self.stickyRingingSnapshot?.callId ?? ""
						)
					}
				}
			}
		}
		if Thread.isMainThread {
			run()
		} else {
			DispatchQueue.main.async(execute: run)
		}
	}

	/// v33: if DeepLink never arrives ~1.2s after openURL ok, clear inFlight + retry.
	private func armBusyChromeRescueWatchdog(attempt: Int, reason: String) {
		cancelBusyChromeRescueWatchdog()
		let work = DispatchWorkItem { [weak self] in
			guard let self else { return }
			guard self.busyChromeRescueInFlight else { return }
			NSLog(
				"[BeamioCallKit] busy-chrome-rescue watchdog FIRE attempt=%d reason=%@ — DeepLink miss",
				attempt,
				reason
			)
			self.busyChromeRescueInFlight = false
			self.busyChromeRescueWatchdogWorkItem = nil
			if self.isStickyPrimaryStillLive() || self.hasLiveCallKitCall() {
				NSLog(
					"[BeamioCallKit] busy-chrome-rescue watchdog skip — CallKit live attempt=%d",
					attempt
				)
				self.busyChromeRescueOpenAttempts = 0
				return
			}
			guard self.stickyRingingSnapshot != nil || self.stickyPrimaryUUID != nil else {
				self.busyChromeRescueOpenAttempts = 0
				return
			}
			if UIApplication.shared.applicationState == .active {
				self.busyChromeRescueOpenAttempts = 0
				self.restoreStickyCallKitChrome(reason: "watchdog-active-\(reason)")
				return
			}
			if attempt < 3 {
				self.requestBusyChromeRescue(reason: "watchdog-retry-\(attempt)-\(reason)")
			} else {
				NSLog(
					"[BeamioCallKit] busy-chrome-rescue watchdog exhausted attempt=%d reason=%@",
					attempt,
					reason
				)
				self.busyChromeRescueOpenAttempts = 0
			}
		}
		busyChromeRescueWatchdogWorkItem = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
	}

	private func cancelBusyChromeRescueWatchdog() {
		busyChromeRescueWatchdogWorkItem?.cancel()
		busyChromeRescueWatchdogWorkItem = nil
	}

	/// DeepLink host `busy-chrome-rescue` — host is activating; restore sticky A.
	func handleBusyChromeRescue() {
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			self.cancelBusyChromeRescueWatchdog()
			self.busyChromeRescueInFlight = false
			self.busyChromeRescueOpenAttempts = 0
			self.cancelBusyDeadChromeRescueFallbacks()
			self.cancelBusyActiveRestorePoll()
			NSLog("[BeamioCallKit] busy-chrome-rescue handle — restore sticky")
			self.restoreStickyCallKitChrome(reason: "busy-chrome-rescue")
		}
	}

	/// After busy second inbound / openURL wake: keep sticky A visible.
	///
	/// v27: if sticky UUID is **still live** → **leave alone** (no forceSuspend,
	/// no heal, no soft-reassert). Suspend/activate after busy was collapsing
	/// CallKit A to Home idle (v20–v26 after-b). Soft-reassert **only** when
	/// sticky is dead/missing but snapshot/pointer still owns ringing A.
	/// **v35:** sticky LIVE never forceReplace (v34 killed A); refresh only.
	/// **v36:** busy restore soft-reassert **never** `scheduleSuspendOnSuccess`
	/// (v35 fromRescue→private-suspend killed freshly reported A' → after-b idle).
	/// Banner comes from QA/user HOME after CallKit Incoming is live again.
	func restoreStickyCallKitChrome(reason: String) {
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			self.restoreStickyChromeWorkItem?.cancel()
			let work = DispatchWorkItem { [weak self] in
				guard let self else { return }
				let stickyAlive = self.isStickyPrimaryStillLive()
				// Sticky still ringing — do not soft-reassert / activate (v27/v35).
				// v37: absolute noop — no CXCallUpdate (collapses A after busy openURL).
				// v42: LIVE + zombie-heal armed → kick forceReplace (chrome-rescue
				// activate after Call B; same as becameActive-zombie-heal).
				if stickyAlive {
					if self.busyChromePresumedDead {
						NSLog(
							"[BeamioCallKit] restore sticky chrome — LIVE+presumedDead → zombie-rescue (v54) reason=%@",
							reason
						)
						self.writeBusyQaBreadcrumb("restore-live-presumed-dead-kick:\(reason)")
						self.kickBusyZombieRescueIfNeeded(
							reason: "restore-live-zombie-\(reason)"
						)
						return
					}
					if self.isBusyZombieChromeHealArmed() {
						NSLog(
							"[BeamioCallKit] restore sticky chrome — LIVE+zombie-heal → kick reason=%@",
							reason
						)
						self.writeBusyQaBreadcrumb("restore-live-heal-kick:\(reason)")
						self.kickBusyZombieHealIfArmed(
							reason: "restore-live-heal-\(reason)"
						)
						return
					}
					NSLog(
						"[BeamioCallKit] restore sticky chrome — alive LEAVE-ALONE absolute-noop reason=%@",
						reason
					)
					self.writeBusyQaBreadcrumb("restore-live-noop:\(reason)")
					return
				}
				if self.hasLiveCallKitCall() {
					NSLog(
						"[BeamioCallKit] restore sticky chrome — live orphan LEAVE-ALONE reason=%@",
						reason
					)
					return
				}
				// System CXEnd may have cleared A while openURL B woke us.
				// Coalesce with CXEnd deferred soft-reassert (v18 single-flight).
				if self.softReassertInFlight || self.pendingSoftReassertWorkItem != nil {
					NSLog(
						"[BeamioCallKit] restore sticky chrome — soft-reassert already pending — heal reason=%@",
						reason
					)
					self.scheduleStickyHealProbes(reason: "restore-pending-\(reason)")
					return
				}
				if self.stickyRingingSnapshot != nil || self.stickyPrimaryUUID != nil {
					// v70: stop restore→soft-reassert when already capped (storm killer).
					if self.softReassertAttempt >= Self.softReassertMaxAttempts {
						NSLog(
							"[BeamioCallKit] restore sticky chrome — CAP hit attempt=%d — abort reason=%@",
							self.softReassertAttempt,
							reason
						)
						self.abortSoftReassertStorm(
							reason: "restore-cap-\(reason)",
							callId: self.stickyRingingSnapshot?.callId ?? ""
						)
						return
					}
					// v36: NEVER suspend after busy soft-reassert (was fromRescue=true).
					NSLog(
						"[BeamioCallKit] restore sticky chrome — soft-reassert dead sticky suspend=0 reason=%@",
						reason
					)
					self.writeBusyQaBreadcrumb("restore-dead-no-suspend:\(reason)")
					self.scheduleDeferredSoftReassert(
						reason: "restore-\(reason)",
						delay: 0.05,
						scheduleSuspendOnSuccess: false,
						forceReplaceEvenIfAlive: false
					)
					self.scheduleStickyHealProbes(reason: "restore-dead-\(reason)")
					return
				}
				NSLog(
					"[BeamioCallKit] restore sticky chrome skip reason=%@ sticky=%@ live=%@ snap=%@",
					reason,
					self.stickyPrimaryUUID?.uuidString ?? "-",
					self.hasLiveCallKitCall() ? "yes" : "no",
					self.stickyRingingSnapshot?.callId ?? "-"
				)
			}
			self.restoreStickyChromeWorkItem = work
			// Settle openURL / becameActive transition before soft-reassert.
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
		}
	}

	/// After a busy second inbound: keep sticky A visible without thrashing.
	///
	/// v17 busy-skip (`allowForceSuspend == false`):
	/// - Cancel pending chrome suspend.
	/// - Sticky !alive / snapshot only → **soft-reassert A**.
	/// - Never endZombie sticky / never report B into CallKit.
	///
	/// v21 busy (`allowForceSuspend == false`) + sticky "alive":
	/// - **Force soft-reassert** (replace UUID). v20 left zombie A alone → Home idle.
	///
	/// PushKit flash recovery may set `allowForceSuspend: true` (legacy suspend).
	func preserveOrReassertStickyIncoming(reason: String, allowForceSuspend: Bool = true) {
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			if !allowForceSuspend {
				// v20: cancel tag-applied suspend only — keep soft-reassert;
				// do not mark chromeSuspendConsumed (busy restore needs force-suspend).
				self.pendingChromeSuspendWorkItem?.cancel()
				self.pendingChromeSuspendWorkItem = nil
				self.endIdentityBackgroundTask()
			}
			guard let sticky = self.stickyPrimaryUUID else {
				if let snap = self.stickyRingingSnapshot, !allowForceSuspend {
					NSLog(
						"[BeamioCallKit] preserve/reassert — no sticky UUID, soft-reassert from snap callId=%@ reason=%@",
						snap.callId,
						reason
					)
					self.scheduleDeferredSoftReassert(
						reason: reason + "-snap",
						scheduleSuspendOnSuccess: false,
						forceReplaceEvenIfAlive: false
					)
					return
				}
				if self.hasLiveCallKitCall(), allowForceSuspend {
					self.scheduleForceSuspendRetries(reason: reason + "-nosticky-live")
				} else {
					NSLog(
						"[BeamioCallKit] preserve/reassert skip reason=%@ (no sticky, live=%@ allowSuspend=%@)",
						reason,
						self.hasLiveCallKitCall() ? "yes" : "no",
						allowForceSuspend ? "yes" : "no"
					)
				}
				return
			}
			let alive = self.controller.callObserver.calls.contains {
				$0.uuid == sticky && !$0.hasEnded
			}
			if alive {
				// v28: alive sticky → leave alone (force-suspend collapsed after-b).
				NSLog(
					"[BeamioCallKit] sticky alive — LEAVE-ALONE reason=%@ allowSuspend=%@",
					reason,
					allowForceSuspend ? "yes" : "no"
				)
				return
			}
			guard let id = self.callIds[sticky] ?? self.stickyRingingSnapshot else {
				// Keep orphan sticky pointer so the next openURL still hits wasBusy.
				if !allowForceSuspend {
					NSLog(
						"[BeamioCallKit] sticky orphan — keep pointer for busy gate reason=%@",
						reason
					)
					return
				}
				NSLog(
					"[BeamioCallKit] sticky orphan no identity — clear reason=%@",
					reason
				)
				self.stickyPrimaryUUID = nil
				self.stickyPrimaryCallId = ""
				if self.hasLiveCallKitCall() {
					self.scheduleForceSuspendRetries(reason: reason + "-orphan-live")
				}
				return
			}
			if !allowForceSuspend {
				// Sticky dead — soft-reassert A' (report-first). v28: no suspend.
				NSLog(
					"[BeamioCallKit] sticky !alive — soft-reassert deferred callId=%@ reason=%@",
					id.callId,
					reason
				)
				self.scheduleDeferredSoftReassert(
					reason: reason + "-dead",
					scheduleSuspendOnSuccess: false,
					forceReplaceEvenIfAlive: false
				)
				return
			}
			let callId = id.callId
			let sessionId = id.sessionId
			NSLog(
				"[BeamioCallKit] reassert sticky (legacy clear) callId=%@ sessionId=%@ reason=%@",
				callId,
				sessionId,
				reason
			)
			// Prefer soft path even when allowForceSuspend — same protection.
			self.softReassertStickyKeepingProtection(
				oldSticky: sticky,
				identity: id,
				reason: reason,
				scheduleSuspendOnSuccess: true
			)
		}
	}

	/// Resolve sticky identity (live map or v17 ringing snapshot) and soft-reassert.
	private func softReassertStickyKeepingProtection(
		reason: String,
		scheduleSuspendOnSuccess: Bool = false,
		forceReplaceEvenIfAlive: Bool = false
	) {
		let oldSticky = stickyPrimaryUUID
		let identity: CallIdentity? = {
			if let uuid = oldSticky, let id = callIds[uuid] { return id }
			return stickyRingingSnapshot
		}()
		guard let identity else {
			NSLog("[BeamioCallKit] soft-reassert skip — no identity reason=%@", reason)
			// v55: was NSLog-only → blind when kick fired with empty snap/callIds.
			writeBusyQaBreadcrumb(
				"soft-reassert-no-identity:\(reason):sticky=\(oldSticky?.uuidString ?? "-"):snap=\(stickyRingingSnapshot?.callId ?? "-")"
			)
			return
		}
		softReassertStickyKeepingProtection(
			oldSticky: oldSticky,
			identity: identity,
			reason: reason,
			scheduleSuspendOnSuccess: scheduleSuspendOnSuccess,
			forceReplaceEvenIfAlive: forceReplaceEvenIfAlive
		)
	}

	/// Re-report sticky Incoming as a **new** UUID (soft-reassert).
	///
	/// **v22 report-first (fixes v18–v21 after-b Home idle):**
	/// Never CXEnd sticky A before `reportNewIncomingCall(A')` succeeds.
	/// End-then-report left zero CallKit calls when report failed from
	/// background / `--no-activate` openURL. Keep sticky protection until A'
	/// is accepted (`maximumCallGroups=2` allows A + A' briefly).
	///
	/// v21: `forceReplaceEvenIfAlive` still replaces when observer lists
	/// sticky as !hasEnded (zombie chrome after busy openURL) — but only
	/// after A' reports OK.
	private func softReassertStickyKeepingProtection(
		oldSticky: UUID?,
		identity: CallIdentity,
		reason: String,
		scheduleSuspendOnSuccess: Bool = false,
		forceReplaceEvenIfAlive: Bool = false
	) {
		// Caller already cancelled (chat voice_end / remoteEnded) — never re-report.
		if BeamioNativeVoiceSignaling.wasRemoteEnded(
			callId: identity.callId,
			sessionId: identity.sessionId
		) {
			NSLog(
				"[BeamioCallKit] soft-reassert SKIP remoteEnded callId=%@ reason=%@",
				identity.callId,
				reason
			)
			writeBusyQaBreadcrumb(
				"soft-reassert-skip-remote-ended:\(identity.callId):\(reason)"
			)
			softReassertInFlight = false
			stickyRingingSnapshot = nil
			var tear = Set<UUID>()
			if let sticky = stickyPrimaryUUID { tear.insert(sticky) }
			if let old = oldSticky { tear.insert(old) }
			if let last = lastReportedUUID { tear.insert(last) }
			for (uuid, ownedCid) in ownedIncomingCallIds where ownedCid == identity.callId {
				tear.insert(uuid)
			}
			for uuid in tear {
				markIntentionallyEnding(uuid)
				provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
				callIds.removeValue(forKey: uuid)
				answeredCallUUIDs.remove(uuid)
				forgetOwnedIncoming(uuid: uuid)
				controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
			}
			if let sticky = stickyPrimaryUUID {
				clearStickyPrimary(uuid: sticky)
			} else {
				stickyPrimaryUUID = nil
				stickyPrimaryCallId = ""
			}
			if lastReportedCallId == identity.callId {
				lastReportedCallId = ""
				lastReportedUUID = nil
			}
			return
		}
		if softReassertInFlight {
			NSLog(
				"[BeamioCallKit] soft-reassert coalesce in-flight reason=%@",
				reason
			)
			writeBusyQaBreadcrumb("soft-reassert-coalesce:\(identity.callId):\(reason)")
			return
		}
		let stickyStillLive: Bool = {
			guard let old = oldSticky else { return false }
			return controller.callObserver.calls.contains(where: { $0.uuid == old && !$0.hasEnded })
		}()
		// v53: busy-guard + sticky LIVE → never soft-reassert (incl. ring-keepalive).
		// v52 keepalive bypassed this → PRE-END A → report hang → Home idle.
		// v54–v55: zombie-rescue PRE-END (CXEnd wait) hung. v56: Update-only idle.
		// v57 FAIL: BG defer blocked zombieRescueLive before report-first.
		// v58 FAIL: report A' while A LIVE → Apple never called completion
		// (naked report path had no 3s timeout) → inFlight stuck → coalesce.
		// v59: zombie-rescue tears A via reportCall(endedAt) immediately
		// (no CXEnd wait), then reportNewIncomingAPrime WITH timeout.
		let zombieRescueLive =
			isBusyZombieRescueReason(reason)
			&& forceReplaceEvenIfAlive
			&& (stickyStillLive || isStickyPrimaryStillLive() || hasStickyRingingSnapshot())
			&& busyChromePresumedDead
		if zombieRescueLive {
			NSLog(
				"[BeamioCallKit] soft-reassert zombie-rescue LIVE → report-first path (v58) uuid=%@ reason=%@",
				oldSticky?.uuidString ?? "-",
				reason
			)
			writeBusyQaBreadcrumb(
				"soft-reassert-zombie-report-first:\(identity.callId):\(reason)"
			)
			// fall through — do NOT CXCallUpdate-only / PRE-END / busy-live SKIP
		} else if isBusyChromeGuardActive(),
		   stickyStillLive || isStickyPrimaryStillLive() {
			NSLog(
				"[BeamioCallKit] soft-reassert SKIP busy-guard+LIVE absolute (v53) uuid=%@ force=%@ reason=%@",
				oldSticky?.uuidString ?? "-",
				forceReplaceEvenIfAlive ? "yes" : "no",
				reason
			)
			writeBusyQaBreadcrumb(
				"soft-reassert-skip-busy-live:\(identity.callId):force=\(forceReplaceEvenIfAlive):\(reason)"
			)
			return
		}
		// Live sticky still ringing — skip unless busy forces replace.
		if stickyStillLive, !forceReplaceEvenIfAlive {
			if busyChromePresumedDead {
				NSLog(
					"[BeamioCallKit] soft-reassert LIVE+presumedDead → kick zombie-rescue (v54) uuid=%@ reason=%@",
					oldSticky?.uuidString ?? "-",
					reason
				)
				writeBusyQaBreadcrumb(
					"soft-reassert-live-presumed-dead:\(identity.callId):\(reason)"
				)
				kickBusyZombieRescueIfNeeded(reason: "soft-reassert-live-\(reason)")
				return
			}
			NSLog(
				"[BeamioCallKit] soft-reassert skip — sticky still live uuid=%@ reason=%@ — schedule heal",
				oldSticky?.uuidString ?? "-",
				reason
			)
			writeBusyQaBreadcrumb(
				"soft-reassert-skip-live:\(identity.callId):\(reason)"
			)
			// v29: never suspend while sticky live / busy-guard (after-b killer).
			if scheduleSuspendOnSuccess,
			   !isBusyChromeGuardActive(),
			   !isStickyPrimaryStillLive()
			{
				performChromeSuspendNow(reason: reason + "-sticky-live", attempt: 0)
			}
			// v24/v29: heal probes catch dead gap; heal itself never suspends.
			// v38: under busy-guard do not re-arm heal (leave-alone cancelled it).
			if !isBusyChromeGuardActive() {
				scheduleStickyHealProbes(reason: "skip-live-\(reason)")
			}
			return
		}
		if forceReplaceEvenIfAlive, stickyStillLive {
			NSLog(
				"[BeamioCallKit] soft-reassert FORCE replace live sticky uuid=%@ reason=%@",
				oldSticky?.uuidString ?? "-",
				reason
			)
		}

		// v31: reportNewIncomingCall from background / .inactive almost always
		// fails without a PushKit wake. Activate via chrome-rescue first when
		// sticky is DEAD.
		// v39: zombie-heal while sticky LIVE must NOT chrome-rescue (openURL
		// activate collapses A again). Try report from bg with BG task; if it
		// fails, later probes / becameActive kick forceReplace again.
		// v57 FAIL: zombieRescueLive was NOT exempt → BG kick deferred to
		// openURL chrome-rescue; crumb never showed report-start.
		// v58: zombieRescueLive (defined above) falls through BG defer →
		// report-first under BG task (endZombie+report; NO PRE-END / paste).
		let appState = UIApplication.shared.applicationState
		let zombieHealLive =
			isBusyZombieHealReason(reason)
			&& forceReplaceEvenIfAlive
			&& (stickyStillLive || isStickyPrimaryStillLive())
		let ringKeepalive = isBusyRingKeepaliveReason(reason)
		if appState != .active, !zombieHealLive, !zombieRescueLive, !ringKeepalive {
			NSLog(
				"[BeamioCallKit] soft-reassert DEFER chrome-rescue state=%d sticky=%@ callId=%@ reason=%@",
				appState.rawValue,
				oldSticky?.uuidString ?? "-",
				identity.callId,
				reason
			)
			// v70: count BG defer toward the soft-reassert cap (report path never
			// runs from BG, so without this the breaker never fires).
			if softReassertAttempt >= Self.softReassertMaxAttempts {
				abortSoftReassertStorm(
					reason: "soft-reassert-bg-cap-\(reason)",
					callId: identity.callId
				)
				return
			}
			softReassertAttempt += 1
			writeBusyQaBreadcrumb(
				"soft-reassert-defer-bg:\(identity.callId):state=\(appState.rawValue):attempt=\(softReassertAttempt):\(reason)"
			)
			softReassertInFlight = false
			// v70: NEVER reset softReassertAttempt here — that erased the circuit
			// breaker and let rescue/restore loop forever (attempt 86+).
			stickyRingingSnapshot = identity
			requestBusyChromeRescue(reason: "soft-reassert-bg-\(reason)")
			scheduleBusyDeadChromeRescueFallbacks(reason: "soft-reassert-bg-\(reason)")
			scheduleBusyActiveRestorePoll(reason: "soft-reassert-bg-\(reason)")
			return
		}
		if zombieRescueLive, appState != .active {
			NSLog(
				"[BeamioCallKit] soft-reassert BG zombie-rescue → report-first (v58) callId=%@ reason=%@",
				identity.callId,
				reason
			)
			writeBusyQaBreadcrumb(
				"soft-reassert-bg-zombie-rescue-report:\(identity.callId):\(reason)"
			)
			beginBusyChromeBackgroundTaskIfNeeded(reason: "soft-bg-zombie-\(reason)")
			beginIdentityBackgroundTaskIfNeeded()
		}
		if ringKeepalive, appState != .active {
			// Ring-keepalive requires ACTIVE report; defer until foreground.
			NSLog(
				"[BeamioCallKit] soft-reassert ring-keepalive defer BG state=%d callId=%@ reason=%@",
				appState.rawValue,
				identity.callId,
				reason
			)
			writeBusyQaBreadcrumb(
				"soft-reassert-ring-keepalive-defer-bg:\(identity.callId):state=\(appState.rawValue)"
			)
			softReassertInFlight = false
			scheduleBusyChromeDeadProbes(reason: "ring-keepalive-bg-\(reason)")
			return
		}
		// v53: sticky LIVE → CXCallUpdate leave-alone (never PRE-END / report).
		// v57: zombie-rescue MUST NOT leave-alone — fall through to else report-first.
		if !zombieRescueLive,
		   zombieHealLive || (forceReplaceEvenIfAlive && stickyStillLive) || ringKeepalive
		{
			let revived = reviveStickyChromeViaCallUpdate(
				reason: "soft-skip-live-revive-\(reason)"
			)
			NSLog(
				"[BeamioCallKit] soft-reassert LIVE absolute leave-alone (v53) revive=%@ state=%d callId=%@ reason=%@",
				revived ? "yes" : "no",
				appState.rawValue,
				identity.callId,
				reason
			)
			writeBusyQaBreadcrumb(
				"soft-reassert-live-leave-alone:\(identity.callId):ok=\(revived ? "yes" : "no"):state=\(appState.rawValue):\(reason)"
			)
			// Leave-alone used to freeze opaque "Beamio" forever. If identity
			// already has a verified @BeamioTag (or chrome still opaque while
			// displayHandle is a tag), paint CallKit without a second report.
			let chrome = identity.chromeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
			let locked = identity.displayHandle.trimmingCharacters(in: .whitespacesAndNewlines)
			let tagCandidate =
				BeamioIncomingCallPayload.normalizedBeamioTag(chrome)
				?? BeamioIncomingCallPayload.normalizedBeamioTag(locked)
			let chromeOpaque =
				chrome.isEmpty
				|| chrome.caseInsensitiveCompare("Beamio") == .orderedSame
				|| chrome.lowercased() == "incoming call"
			if let tag = tagCandidate, chromeOpaque || !identity.verifiedBeamioTagApplied {
				updateVerifiedIdentityOnMain(
					callId: identity.callId,
					sessionId: identity.sessionId,
					tag: tag,
					shortAddress: ""
				)
				writeBusyQaBreadcrumb(
					"soft-reassert-leave-alone-tag-heal:\(tag):\(identity.callId)"
				)
			}
			return
		}

		// v70: hard-cap soft-reassert storm (SE: attempt 86+ after natural CXEnd).
		// Cap checked here — after early skip returns — so busy-live / coalesce
		// do not burn attempts.
		if softReassertAttempt >= Self.softReassertMaxAttempts {
			NSLog(
				"[BeamioCallKit] soft-reassert CAP hit attempt=%d callId=%@ reason=%@ — abort storm",
				softReassertAttempt,
				identity.callId,
				reason
			)
			abortSoftReassertStorm(
				reason: "soft-reassert-cap-\(reason)",
				callId: identity.callId
			)
			return
		}
		softReassertInFlight = true
		softReassertAttempt += 1
		let attempt = softReassertAttempt
		// Keep process awake for reportNewIncomingCall (active path + brief inactive).
		beginIdentityBackgroundTaskIfNeeded()
		let callId = identity.callId
		let sessionId = identity.sessionId
		// Preserve verified @BeamioTag chrome for soft-reassert A' report.
		let display: String = {
			if identity.verifiedBeamioTagApplied {
				let chrome = identity.chromeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
				if !chrome.isEmpty, chrome != "Beamio" { return chrome }
			}
			let chrome = identity.chromeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
			if !chrome.isEmpty, chrome != "Beamio" { return chrome }
			let handle = identity.displayHandle.trimmingCharacters(in: .whitespacesAndNewlines)
			if !handle.isEmpty, handle != "Beamio", handle.hasPrefix("@") { return handle }
			return Self.callKitDisplayLabel(handle.isEmpty ? "Beamio" : handle)
		}()
		let newUuid = UUID()
		stickyRingingSnapshot = identity

		NSLog(
			"[BeamioCallKit] soft-reassert report-first sticky=%@ → new=%@ callId=%@ force=%@ live=%@ attempt=%d reason=%@",
			oldSticky?.uuidString ?? "-",
			newUuid.uuidString,
			callId,
			forceReplaceEvenIfAlive ? "yes" : "no",
			stickyStillLive ? "yes" : "no",
			attempt,
			reason
		)
		writeBusyQaBreadcrumb(
			"soft-reassert-report-start:\(callId):attempt=\(attempt):force=\(forceReplaceEvenIfAlive):\(reason)"
		)

		func finishFail(_ msg: String) {
			self.softReassertInFlight = false
			NSLog(
				"[BeamioCallKit] soft-reassert FAIL %@ attempt=%d reason=%@",
				msg,
				attempt,
				reason
			)
			self.writeBusyQaBreadcrumb(
				"soft-reassert-fail:\(attempt):\(msg):\(reason)"
			)
			// v40/v57: zombie-heal/rescue LIVE + report fail → CXCallUpdate
			// fallback only (never PRE-END). Then still allow retry/chrome-rescue.
			let stickyStillLiveAfterFail = self.isStickyPrimaryStillLive()
			if stickyStillLiveAfterFail,
			   self.isBusyZombieHealReason(reason) || self.isBusyZombieRescueReason(reason)
			{
				let revived = self.reviveStickyChromeViaCallUpdate(
					reason: "soft-fail-revive-\(attempt)-\(reason)"
				)
				NSLog(
					"[BeamioCallKit] soft-reassert FAIL LIVE zombie → CXCallUpdate revive=%@ attempt=%d",
					revived ? "yes" : "no",
					attempt
				)
				self.writeBusyQaBreadcrumb(
					"soft-fail-live-revive:\(attempt):ok=\(revived ? "yes" : "no"):\(reason)"
				)
				// v57: still fall through to retry/chrome-rescue — Update alone
				// was insufficient in v56 (ok=true, chrome still gone).
			}
			let canRetry =
				attempt < 5
				&& (self.stickyRingingSnapshot != nil || self.stickyPrimaryUUID != nil)
			if canRetry {
				self.scheduleDeferredSoftReassert(
					reason: reason.contains("-retry") ? reason : reason + "-retry",
					delay: 0.55 + Double(attempt) * 0.35,
					scheduleSuspendOnSuccess: scheduleSuspendOnSuccess,
					forceReplaceEvenIfAlive: forceReplaceEvenIfAlive || attempt >= 2
				)
				self.scheduleStickyHealProbes(reason: "reassert-fail-\(reason)")
				// v30: after 2 background fails, activate (don't wait for 5).
				if attempt >= 2,
				   UIApplication.shared.applicationState != .active,
				   !self.isStickyPrimaryStillLive()
				{
					NSLog(
						"[BeamioCallKit] soft-reassert FAIL×%d background — chrome-rescue reason=%@",
						attempt,
						reason
					)
					self.writeBusyQaBreadcrumb("soft-reassert-fail-chrome-rescue:\(attempt):\(reason)")
					self.requestBusyChromeRescue(reason: "reassert-bg-\(reason)")
				}
				return
			}
			// v30: exhausted → chrome-rescue ONLY when sticky DEAD.
			NSLog(
				"[BeamioCallKit] soft-reassert FAIL exhausted — chrome-rescue if DEAD reason=%@",
				reason
			)
			self.writeBusyQaBreadcrumb("soft-reassert-fail-exhausted:\(reason)")
			self.requestBusyChromeRescue(reason: "reassert-exhausted-\(reason)")
			self.scheduleBusyDeadChromeRescueFallbacks(reason: "reassert-exhausted-\(reason)")
			self.scheduleBusyActiveRestorePoll(reason: "reassert-exhausted-\(reason)")
			self.scheduleStickyHealProbes(reason: "reassert-exhausted-\(reason)")
		}

		func markSoftReassertSuccess(endedOld: String?) {
			self.softReassertAttempt = 0
			self.softReassertInFlight = false
			self.cancelStickyHealProbes(reason: "soft-reassert-ok")
			self.cancelBusyDeadChromeRescueFallbacks()
			self.cancelBusyActiveRestorePoll()
			self.cancelBusyLiveChromeRescue()
			self.clearBusyZombieChromeHeal(reason: "soft-reassert-ok-\(reason)")
			self.clearBusyChromePresumedDead(reason: "soft-reassert-ok-\(reason)")
			self.cancelBusyPresumedDeadChromeRescue()
			// v36: keep busy-guard ~8s so becameActive / openURL cannot
			// force-suspend the freshly reported sticky. Banner = user/QA HOME.
			// v42: after busy-live soft-reassert, pulse busy-resuspend so Home
			// banner appears without requiring QA HOME (Call B --no-activate).
			self.armBusyChromeGuard(reason: "soft-reassert-ok-\(reason)", seconds: 30)
			NSLog(
				"[BeamioCallKit] soft-reassert OK callId=%@ uuid=%@ endedOld=%@ scheduleSuspend=%@ (v42 busy-resuspend)",
				callId,
				newUuid.uuidString,
				endedOld ?? "-",
				scheduleSuspendOnSuccess ? "requested-ignored" : "0"
			)
			self.writeBusyQaBreadcrumb(
				"soft-reassert-ok:\(callId):uuid=\(newUuid.uuidString):suspendIgnored=\(scheduleSuspendOnSuccess)"
			)
			// v51: ring-keepalive just re-reported Incoming — never forceSuspend
			// (v49 ACTIVE forceSuspend killed A; reason may still contain "busy").
			// v54: zombie-rescue PRE-END just painted A' — never forceSuspend.
			if self.isBusyRingKeepaliveReason(reason)
				|| self.isBusyZombieRescueReason(reason)
			{
				NSLog(
					"[BeamioCallKit] soft-reassert OK zombie/keepalive — NO resuspend reason=%@",
					reason
				)
				self.writeBusyQaBreadcrumb("soft-reassert-ok-no-resuspend:\(reason)")
			} else if self.isBusyZombieHealReason(reason) || reason.contains("busy") {
				self.scheduleBusyChromeResuspend(reason: "after-soft-ok-\(reason)")
			} else if scheduleSuspendOnSuccess {
				NSLog(
					"[BeamioCallKit] soft-reassert OK — IGNORE private-suspend (v36) reason=%@",
					reason
				)
			}
		}

		func endOldStickyThenAdopt() {
			guard let old = oldSticky else {
				self.adoptStickyPrimary(uuid: newUuid, callId: callId)
				self.rememberOwnedIncoming(uuid: newUuid, callId: callId)
				markSoftReassertSuccess(endedOld: nil)
				return
			}
			// v38: busy-guard must never intentional-end sticky A (even after A'
			// report). Keep both briefly under maximumCallGroups=2; adopt A'.
			// v39: zombie-heal MUST end old after A' OK — otherwise zombie A UUID
			// stays "LIVE" while chrome is gone and CallKit shows nothing.
			let oldStillLive = self.controller.callObserver.calls.contains {
				$0.uuid == old && !$0.hasEnded
			}
			// v51: ring-keepalive MUST end old A after A' report succeeds
			// (otherwise two LIVE UUIDs / chrome may stay on dead A).
			if self.isBusyChromeGuardActive(),
			   oldStillLive,
			   !self.isBusyZombieHealReason(reason),
			   !self.isBusyRingKeepaliveReason(reason),
			   !self.isBusyZombieRescueReason(reason)
			{
				NSLog(
					"[BeamioCallKit] soft-reassert SKIP end-old busy-guard+LIVE old=%@ new=%@",
					old.uuidString,
					newUuid.uuidString
				)
				self.writeBusyQaBreadcrumb(
					"soft-reassert-skip-end-old-busy-live:\(callId):old=\(old.uuidString)"
				)
				self.adoptStickyPrimary(uuid: newUuid, callId: callId)
				self.rememberOwnedIncoming(uuid: newUuid, callId: callId)
				markSoftReassertSuccess(endedOld: "skipped-busy-live")
				return
			}
			if self.isBusyZombieHealReason(reason)
				|| self.isBusyRingKeepaliveReason(reason)
				|| self.isBusyZombieRescueReason(reason),
			   oldStillLive
			{
				NSLog(
					"[BeamioCallKit] soft-reassert END-old (heal/keepalive/zombie-rescue) old=%@ new=%@ reason=%@",
					old.uuidString,
					newUuid.uuidString,
					reason
				)
				self.writeBusyQaBreadcrumb(
					"soft-reassert-end-old:\(callId):old=\(old.uuidString):\(reason)"
				)
			}
			self.markIntentionallyEnding(old)
			// reportCall tears SpringBoard chrome immediately; CXEnd alone can leave
			// Incoming visible after callIds.remove while browser Cancel races in.
			self.provider.reportCall(with: old, endedAt: Date(), reason: .remoteEnded)
			self.forgetOwnedIncoming(uuid: old)
			let end = CXEndCallAction(call: old)
			let tx = CXTransaction(action: end)
			self.controller.request(tx) { [weak self] (endErr: Error?) in
				guard let self else { return }
				if let endErr {
					NSLog(
						"[BeamioCallKit] soft-reassert old-end (ok if already ended) err=%@",
						endErr.localizedDescription
					)
				}
				self.clearStickyPrimary(uuid: old)
				self.callIds.removeValue(forKey: old)
				self.answeredCallUUIDs.remove(old)
				self.intentionallyEndingUUIDs.remove(old)
				self.adoptStickyPrimary(uuid: newUuid, callId: callId)
				self.rememberOwnedIncoming(uuid: newUuid, callId: callId)
				markSoftReassertSuccess(endedOld: old.uuidString)
			}
		}

		var adopted = CallIdentity(
			callId: callId,
			sessionId: sessionId,
			displayHandle: display,
			chromeTitle: identity.chromeTitle.isEmpty ? display : identity.chromeTitle
		)
		adopted.verifiedIdentityApplied = identity.verifiedIdentityApplied
		adopted.verifiedBeamioTagApplied = identity.verifiedBeamioTagApplied
		callIds[newUuid] = adopted

		/// v52: ring-keepalive / zombie-heal must END sticky A *before*
		/// `reportNewIncomingCall(A')`. v51 reported while A still LIVE →
		/// Apple never invoked the completion (breadcrumb stop at report-start)
		/// → after-b Home idle.
		func reportNewIncomingAPrime(afterEndingOld: String?) {
			self.writeBusyQaBreadcrumb(
				"soft-reassert-report-invoke:\(callId):afterEnd=\(afterEndingOld ?? "-"):\(reason)"
			)
			var reportFinished = false
			let finishReportOnce: (Error?) -> Void = { error in
				guard !reportFinished else { return }
				reportFinished = true
				if let error {
					self.callIds.removeValue(forKey: newUuid)
					self.writeBusyQaBreadcrumb(
						"soft-reassert-report-completion-err:\(callId):\(error.localizedDescription):\(reason)"
					)
					finishFail(error.localizedDescription)
					return
				}
				// Cancel arrived while report was in flight — tear A' and any
				// orphan owned UUIDs for this callId (old A may already be off map).
				if BeamioNativeVoiceSignaling.wasRemoteEnded(
					callId: callId,
					sessionId: sessionId
				) {
					self.writeBusyQaBreadcrumb(
						"soft-reassert-abort-remote-ended:\(callId):uuid=\(newUuid.uuidString):\(reason)"
					)
					var tear = Set<UUID>([newUuid])
					if let sticky = self.stickyPrimaryUUID { tear.insert(sticky) }
					if let last = self.lastReportedUUID { tear.insert(last) }
					for (uuid, ownedCid) in self.ownedIncomingCallIds where ownedCid == callId {
						tear.insert(uuid)
					}
					for uuid in tear {
						self.markIntentionallyEnding(uuid)
						self.provider.reportCall(
							with: uuid,
							endedAt: Date(),
							reason: .remoteEnded
						)
						self.callIds.removeValue(forKey: uuid)
						self.answeredCallUUIDs.remove(uuid)
						self.forgetOwnedIncoming(uuid: uuid)
						self.controller.request(
							CXTransaction(action: CXEndCallAction(call: uuid))
						) { _ in }
					}
					self.stickyRingingSnapshot = nil
					if let sticky = self.stickyPrimaryUUID {
						self.clearStickyPrimary(uuid: sticky)
					} else {
						self.stickyPrimaryUUID = nil
						self.stickyPrimaryCallId = ""
					}
					if self.lastReportedCallId == callId {
						self.lastReportedCallId = ""
						self.lastReportedUUID = nil
					}
					self.softReassertInFlight = false
					return
				}
				self.writeBusyQaBreadcrumb(
					"soft-reassert-report-completion-ok:\(callId):uuid=\(newUuid.uuidString):\(reason)"
				)
				let title = identity.chromeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
				if !title.isEmpty, title != "Beamio" {
					self.provider.reportCall(
						with: newUuid,
						updated: Self.makeVerifiedIdentityUpdate(tag: title, shortAddress: "")
					)
				}
				// Old already torn on keepalive / heal / zombie-rescue (v59) path.
				if self.isBusyRingKeepaliveReason(reason)
					|| self.isBusyZombieHealReason(reason)
					|| self.isBusyZombieRescueReason(reason)
				{
					self.adoptStickyPrimary(uuid: newUuid, callId: callId)
					self.rememberOwnedIncoming(uuid: newUuid, callId: callId)
					markSoftReassertSuccess(endedOld: afterEndingOld ?? "pre-ended")
				} else {
					endOldStickyThenAdopt()
				}
			}
			// Prefer verified-identity update when soft-reassert already has
			// @BeamioTag — makeAudioOnlyUpdate historically forced "Beamio"
			// via callKitDisplayLabel and wiped the painted tag.
			let aPrimeUpdate: CXCallUpdate = {
				if let tag = BeamioIncomingCallPayload.normalizedBeamioTag(display) {
					return Self.makeVerifiedIdentityUpdate(tag: tag, shortAddress: "")
				}
				return Self.makeAudioOnlyUpdate(displayHandle: display)
			}()
			self.provider.reportNewIncomingCall(
				with: newUuid,
				update: aPrimeUpdate
			) { error in
				finishReportOnce(error)
			}
			// v52: if Apple never calls completion (hung while dual-ring), fail out.
			// v62: zombie-rescue after wait-ended needs longer window (~8s) —
			// BG + CallKit bookkeeping after tear can exceed 3s.
			let reportTimeoutSec: TimeInterval =
				self.isBusyZombieRescueReason(reason) ? 8.0 : 3.0
			DispatchQueue.main.asyncAfter(deadline: .now() + reportTimeoutSec) {
				guard !reportFinished else { return }
				self.writeBusyQaBreadcrumb(
					"soft-reassert-report-timeout:\(callId):uuid=\(newUuid.uuidString):\(reason)"
				)
				finishReportOnce(
					NSError(
						domain: "BeamioCallKit",
						code: -52,
						userInfo: [
							NSLocalizedDescriptionKey: "reportNewIncomingCall completion timeout"
						]
					)
				)
			}
		}

		func endStickyOldThenReport() {
			guard let old = oldSticky else {
				self.writeBusyQaBreadcrumb(
					"soft-reassert-pre-end-skip-no-old:\(callId):\(reason)"
				)
				reportNewIncomingAPrime(afterEndingOld: nil)
				return
			}
			let oldStillLive = self.controller.callObserver.calls.contains {
				$0.uuid == old && !$0.hasEnded
			}
			guard oldStillLive else {
				self.writeBusyQaBreadcrumb(
					"soft-reassert-pre-end-already-dead:\(callId):old=\(old.uuidString):\(reason)"
				)
				self.clearStickyPrimary(uuid: old)
				self.callIds.removeValue(forKey: old)
				self.forgetOwnedIncoming(uuid: old)
				reportNewIncomingAPrime(afterEndingOld: old.uuidString)
				return
			}
			NSLog(
				"[BeamioCallKit] soft-reassert PRE-END sticky (v52) old=%@ → then report new=%@ reason=%@",
				old.uuidString,
				newUuid.uuidString,
				reason
			)
			self.writeBusyQaBreadcrumb(
				"soft-reassert-pre-end-start:\(callId):old=\(old.uuidString):\(reason)"
			)
			self.markIntentionallyEnding(old)
			var endFinished = false
			let finishEndOnce: () -> Void = {
				guard !endFinished else { return }
				endFinished = true
				self.clearStickyPrimary(uuid: old)
				self.callIds.removeValue(forKey: old)
				self.answeredCallUUIDs.remove(old)
				self.intentionallyEndingUUIDs.remove(old)
				self.forgetOwnedIncoming(uuid: old)
				self.writeBusyQaBreadcrumb(
					"soft-reassert-pre-end-done:\(callId):old=\(old.uuidString):\(reason)"
				)
				reportNewIncomingAPrime(afterEndingOld: old.uuidString)
			}
			let end = CXEndCallAction(call: old)
			self.controller.request(CXTransaction(action: end)) { endErr in
				if let endErr {
					NSLog(
						"[BeamioCallKit] soft-reassert pre-end CXEnd err=%@ — reportCall fallback",
						endErr.localizedDescription
					)
					self.provider.reportCall(
						with: old,
						endedAt: Date(),
						reason: .failed
					)
				}
				finishEndOnce()
			}
			// Also tear chrome immediately (same as endZombie).
			self.provider.reportCall(with: old, endedAt: Date(), reason: .remoteEnded)
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { finishEndOnce() }
		}

		if isBusyZombieHealReason(reason), !isStickyPrimaryStillLive() {
			// v53: heal only when sticky already DEAD (never PRE-END LIVE A).
			endStickyOldThenReport()
		} else if isBusyRingKeepaliveReason(reason) {
			// v53: ring-keepalive must not PRE-END; treat as leave-alone fail-closed.
			writeBusyQaBreadcrumb(
				"soft-reassert-ring-keepalive-aborted-no-pre-end:\(identity.callId):\(reason)"
			)
			softReassertInFlight = false
			return
		} else if zombieRescueLive {
			// v62: tear A → poll observer until ended (≤1.5s, RunLoop spin
			// so CallKit callbacks drain even in BG) → THEN report A'.
			// v60 sync tear+report hung (A still LIVE). v59 asyncAfter never
			// fired in BG. Keep presumedDead until A' succeeds.
			func tearZombieStickyThenReportAPrime() {
				guard let old = oldSticky else {
					self.writeBusyQaBreadcrumb(
						"soft-reassert-zombie-tear-no-old:\(callId):\(reason)"
					)
					reportNewIncomingAPrime(afterEndingOld: nil)
					return
				}
				NSLog(
					"[BeamioCallKit] soft-reassert zombie-tear (v62) old=%@ → wait-ended → report new=%@ reason=%@",
					old.uuidString,
					newUuid.uuidString,
					reason
				)
				self.writeBusyQaBreadcrumb(
					"soft-reassert-zombie-tear:\(callId):old=\(old.uuidString):\(reason)"
				)
				self.beginBusyChromeBackgroundTaskIfNeeded(
					reason: "zombie-tear-report-\(callId)"
				)
				self.markIntentionallyEnding(old)
				self.provider.reportCall(
					with: old,
					endedAt: Date(),
					reason: .remoteEnded
				)
				self.clearStickyPrimary(uuid: old, keepPresumedDead: true)
				self.callIds.removeValue(forKey: old)
				self.answeredCallUUIDs.remove(old)
				self.forgetOwnedIncoming(uuid: old)
				let end = CXEndCallAction(call: old)
				self.controller.request(CXTransaction(action: end)) { [weak self] _ in
					self?.intentionallyEndingUUIDs.remove(old)
				}
				self.busyTearWaitReportInFlight = true
				self.writeBusyQaBreadcrumb(
					"soft-reassert-zombie-tear-wait-ended:\(callId):old=\(old.uuidString):\(reason)"
				)
				// Spin main RunLoop ≤1.5s so CXCallObserver can mark ended
				// without hanging forever on dual-LIVE report (v58/v60).
				let waitDeadline = Date().addingTimeInterval(1.5)
				while Date() < waitDeadline {
					let stillLive = self.controller.callObserver.calls.contains {
						$0.uuid == old && !$0.hasEnded
					}
					if !stillLive { break }
					RunLoop.current.run(
						mode: .default,
						before: Date().addingTimeInterval(0.05)
					)
				}
				let stillLiveAfterWait = self.controller.callObserver.calls.contains {
					$0.uuid == old && !$0.hasEnded
				}
				self.busyTearWaitReportInFlight = false
				self.writeBusyQaBreadcrumb(
					"soft-reassert-zombie-wait-ended-done:live=\(stillLiveAfterWait ? "yes" : "no"):\(callId):old=\(old.uuidString):\(reason)"
				)
				reportNewIncomingAPrime(afterEndingOld: old.uuidString)
			}
			tearZombieStickyThenReportAPrime()
		} else {
			// Sticky already DEAD (or force-replace cleared). endZombie then
			// report A' via timeout-protected path (v59: never naked report).
			endZombieCalls(except: newUuid) { [weak self] in
				guard self != nil else { return }
				reportNewIncomingAPrime(afterEndingOld: nil)
			}
		}
	}

	/// call flash (openURL may wake host; system may drop the @tag row).
	/// Must use `makeVerifiedIdentityUpdate` — `makeAudioOnlyUpdate` →
	/// `callKitDisplayLabel` always returns opaque `"Beamio"` and wiped @tag.
	func refreshLiveIncomingChrome(reason: String) {
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			// v37: busy-guard + sticky LIVE → skip CXCallUpdate (openURL wake
			// + reportCall collapsed A). v40: allow zombie-heal / chrome-revive
			// — chrome is already dead; CXCallUpdate is the only recovery
			// without PushKit.
			if self.isBusyChromeGuardActive(),
			   self.isStickyPrimaryStillLive(),
			   !self.isBusyZombieHealReason(reason)
			{
				NSLog(
					"[BeamioCallKit] refresh SKIP busy-guard+LIVE reason=%@",
					reason
				)
				self.writeBusyQaBreadcrumb("refresh-skip-busy-live:\(reason)")
				return
			}
			// v87: never CXCallUpdate a connected/answered call — races in-call
			// chrome the same way mid-Answer reportCall(updated:) does.
			if self.hasAnsweredLiveCall() {
				NSLog(
					"[BeamioCallKit] refresh SKIP answered (v87) reason=%@",
					reason
				)
				self.writeBusyQaBreadcrumb("refresh-skip-answered:\(reason)")
				return
			}
			var refreshed = 0
			let sticky = self.stickyPrimaryUUID
			for call in self.controller.callObserver.calls where !call.hasEnded {
				guard let id = self.callIds[call.uuid], !id.isOutgoing else { continue }
				if self.answeredCallUUIDs.contains(call.uuid) { continue }
				let title: String = {
					let chrome = id.chromeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
					if !chrome.isEmpty { return chrome }
					let locked = id.displayHandle.trimmingCharacters(in: .whitespacesAndNewlines)
					if !locked.isEmpty { return locked }
					return "Beamio"
				}()
				let update = Self.makeVerifiedIdentityUpdate(tag: title, shortAddress: "")
				self.provider.reportCall(with: call.uuid, updated: update)
				refreshed += 1
				NSLog(
					"[BeamioCallKit] refresh live chrome uuid=%@ title=%@ sticky=%@ reason=%@",
					call.uuid.uuidString,
					title,
					sticky == call.uuid ? "yes" : "no",
					reason
				)
			}
			if refreshed == 0 {
				NSLog("[BeamioCallKit] refresh live chrome — none reason=%@", reason)
			}
		}
	}

	/// Busy second-call path: DeepLink / PushKit flash wakes the host and
	/// collapses the first Incoming chrome.
	///
	/// v28: **never** private-suspend while sticky primary is still live, or
	/// while the busy-chrome guard is armed.
	/// v41 allowBusyResuspend exception **removed in v50** — ACTIVE
	/// forceSuspend after Call B openURL killed CallKit A (v49 crumb).
	func forceSuspendToKeepLiveCallChrome(reason: String) {
		let run: () -> Void = { [weak self] in
			guard let self else { return }
			// v87: answered / shell in-call must stay foreground. becameActive used
			// to scheduleForceSuspendRetries on any live CallKit UUID — after Accept
			// that collapsed the in-call screen; green-bar wake → same suspend again.
			if self.hasAnsweredLiveCall() {
				NSLog(
					"[BeamioCallKit] force-suspend LEAVE-ALONE answered (v87) reason=%@",
					reason
				)
				self.writeBusyQaBreadcrumb("force-suspend-leave-alone-answered:\(reason)")
				return
			}
			if self.isStickyPrimaryStillLive() {
				NSLog(
					"[BeamioCallKit] force-suspend LEAVE-ALONE sticky LIVE (v50) reason=%@",
					reason
				)
				self.writeBusyQaBreadcrumb("force-suspend-leave-alone-live:\(reason)")
				return
			}
			if self.isBusyChromeGuardActive() {
				NSLog(
					"[BeamioCallKit] force-suspend LEAVE-ALONE busy-guard (v50) reason=%@",
					reason
				)
				self.writeBusyQaBreadcrumb("force-suspend-leave-alone-busy:\(reason)")
				return
			}
			guard self.hasLiveCallKitCall() else {
				NSLog(
					"[BeamioCallKit] force-suspend skip reason=%@ (no live CallKit)",
					reason
				)
				return
			}
			NSLog("[BeamioCallKit] force-suspend reason=%@", reason)
			self.performChromeSuspendNow(reason: reason, attempt: 0)
		}
		if Thread.isMainThread {
			run()
		} else {
			DispatchQueue.main.async(execute: run)
		}
	}

	/// openURL often leaves `applicationState == .inactive` for hundreds of ms;
	/// a single suspend then no-ops and CallKit stays collapsed / white foreground.
	/// v20: longer retry window so busy-after openURL still lands on Home + banner.
	func scheduleForceSuspendRetries(reason: String) {
		let delays: [TimeInterval] = [0.05, 0.25, 0.6, 1.2, 2.0, 3.5]
		for (idx, delay) in delays.enumerated() {
			DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
				self?.forceSuspendToKeepLiveCallChrome(reason: "\(reason)-r\(idx)")
			}
		}
	}

	private func performChromeSuspendNow(reason: String, attempt: Int = 0) {
		pendingChromeSuspendWorkItem?.cancel()
		pendingChromeSuspendWorkItem = nil
		let allowBusyResuspend =
			reason.contains("busy-resuspend") && isBusyChromeGuardActive()
		let state = UIApplication.shared.applicationState
		// v88: answered / shell in-call — never private-suspend (Accept flash /
		// green-bar re-collapse). tag-applied path hits here directly.
		if hasAnsweredLiveCall() {
			writeBusyQaBreadcrumb(
				"suspend-perform-leave-alone-answered:\(reason):state=\(state.rawValue):attempt=\(attempt)"
			)
			NSLog(
				"[BeamioCallKit] suspend-perform LEAVE-ALONE answered (v88) reason=%@",
				reason
			)
			return
		}
		// The call this suspend was armed for is over (declined, ended, timed
		// out). Suspending now only sends the user to the home screen while
		// they are using Beamio.
		if !hasLiveCallKitCall() {
			writeBusyQaBreadcrumb(
				"suspend-perform-skip-no-call:\(reason):state=\(state.rawValue):attempt=\(attempt)"
			)
			NSLog(
				"[BeamioCallKit] suspend-perform SKIP — no live CallKit call reason=%@",
				reason
			)
			if !softReassertInFlight {
				endIdentityBackgroundTask()
			}
			return
		}
		// v67: sticky Incoming + busy / self-probe must not end the identity
		// background task or call private suspend. Those drop the banner
		// while CXCallObserver still reports the call as live.
		if debugSelfProbeSuspendHold
			|| (isBusyChromeGuardActive() && isStickyPrimaryStillLive() && !allowBusyResuspend)
		{
			writeBusyQaBreadcrumb(
				"suspend-perform-blocked-v67:\(reason):state=\(state.rawValue):attempt=\(attempt):hold=\(debugSelfProbeSuspendHold ? 1 : 0)"
			)
			return
		}
		writeBusyQaBreadcrumb("suspend-perform:\(reason):state=\(state.rawValue):attempt=\(attempt)")
		// v25: soft-reassert may still be awaiting reportNewIncomingCall from
		// background — do not tear down its identity bg-task mid-flight.
		// v47: under busy-guard, keep identity BG so delayed resuspend / dead-
		// probe timers still run after Call B openURL (v46 ended BG → timers
		// never breadcrumbed).
		if !softReassertInFlight, !allowBusyResuspend {
			endIdentityBackgroundTask()
		}
		NSLog(
			"[BeamioCallKit] suspend for full CallKit chrome reason=%@ state=%d attempt=%d keepBg=%@",
			reason,
			state.rawValue,
			attempt,
			(softReassertInFlight || allowBusyResuspend) ? "yes" : "no"
		)
		if state == .active {
			beamioPerformPrivateAppSuspend()
			return
		}
		// v82: already `.background` (Safari FG + PushKit wake finished) — CallKit
		// Incoming is the system banner. Private suspend cannot run without Beamio
		// becoming `.active` first. Retrying 10× then tearGhostSticky (v80/v81)
		// killed the ringing call (`busy-resuspend-give-up:…:tag-applied` /
		// `resolve-done` crumbs 01:14 / 01:22). Treat bg+live as success.
		if state == .background,
			hasLiveCallKitCall() || isStickyPrimaryStillLive()
		{
			writeBusyQaBreadcrumb(
				"suspend-already-bg-ok:\(reason):state=\(state.rawValue):attempt=\(attempt)"
			)
			NSLog(
				"[BeamioCallKit] suspend already-bg OK (v82) reason=%@ — keep live CallKit",
				reason
			)
			return
		}
		// .inactive (or bg with no live call) during openURL transition — retry briefly.
		guard attempt < 10 else {
			NSLog("[BeamioCallKit] suspend GIVE UP reason=%@ state=%d", reason, state.rawValue)
			writeBusyQaBreadcrumb(
				"busy-resuspend-give-up:state=\(state.rawValue):attempt=\(attempt):\(reason)"
			)
			// v82: never tear a LIVE sticky Incoming just because private suspend
			// failed (another app stays FG → Beamio stays .background). Only tear
			// orphan / invisible sticky that would busy-block the next dial.
			if isStickyPrimaryStillLive() || hasLiveCallKitCall() {
				writeBusyQaBreadcrumb(
					"busy-resuspend-give-up-keep-live:state=\(state.rawValue):attempt=\(attempt):\(reason)"
				)
				return
			}
			if let sticky = stickyPrimaryUUID {
				tearGhostStickyUUID(
					sticky,
					reason: "busy-resuspend-give-up:\(reason)"
				)
			} else {
				_ = clearGhostStickyBlockingNewReport(
					reason: "busy-resuspend-give-up:\(reason)"
				)
			}
			return
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
			guard let self else { return }
			let stillOk =
				self.hasLiveCallKitCall()
				|| (allowBusyResuspend && self.isStickyPrimaryStillLive())
			guard stillOk else {
				self.writeBusyQaBreadcrumb(
					"busy-resuspend-retry-skip-dead:attempt=\(attempt):\(reason)"
				)
				return
			}
			self.performChromeSuspendNow(reason: reason, attempt: attempt + 1)
		}
	}

	func startOutgoing(callId: String, handle: String, sessionId: String = "") {
		// B35: fresh UUID + opaque "Beamio" (ignore peer/tag from bridge).
		let uuid = UUID()
		let display = Self.callKitDisplayLabel(handle)
		endZombieCalls(except: uuid) { [weak self] in
			guard let self else { return }
			self.callIds[uuid] = CallIdentity(
				callId: callId,
				sessionId: sessionId,
				displayHandle: display,
				chromeTitle: display,
				isOutgoing: true
			)
			self.rememberOwnedIncoming(uuid: uuid, callId: callId)
			// Same short display for CXStartCallAction handle — never follow with a
			// reportCall(updated:) that swaps EOA↔@tag (that collapses bottom chrome).
			let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: display))
			action.isVideo = false
			BeamioCallTiming.mark("callkit-request")
			self.controller.request(CXTransaction(action: action)) { [weak self] error in
				BeamioCallTiming.mark("callkit-request-done", error == nil ? "ok" : "error")
				if error != nil {
					self?.callIds.removeValue(forKey: uuid)
				}
			}
		}
	}

	/// Dialer: remote accepted — move CallKit from connecting → connected.
	func markOutgoingConnected(callId: String, sessionId: String = "") {
		guard let uuid = callIds.first(where: {
			matches($0.value, callId: callId, sessionId: sessionId) && $0.value.isOutgoing
		})?.key else {
			NSLog(
				"[BeamioCallKit] markOutgoingConnected skip — no outgoing uuid callId=%@ sessionId=%@",
				callId,
				sessionId
			)
			return
		}
		answeredCallUUIDs.insert(uuid)
		provider.reportOutgoingCall(with: uuid, connectedAt: Date())
		NSLog(
			"[BeamioCallKit] markOutgoingConnected callId=%@ sessionId=%@ uuid=%@",
			callId,
			sessionId,
			uuid.uuidString
		)
	}

	/// Shell → PWA event (callAnswered / callRejected / …) without a CX action.
	func emitToWeb(_ action: String, callId: String, sessionId: String) {
		guard !action.isEmpty, !callId.isEmpty else { return }
		if let webBridge {
			webBridge(action, callId, sessionId)
			return
		}
		pendingBridgeActions.append((action, callId, sessionId))
	}

	/// Whether cancel/end for `callId`/`sessionId` is the SAME live ring as
	/// `lastReportedCallId` (PushKit alias ↔ chat offer callId). History-replayed
	/// `voice_end` for an older callId must return false so we do not tear the
	/// current Incoming chrome (flash-then-hide after dial).
	func cancelAliasesLastReported(callId: String, sessionId: String) -> Bool {
		let cid = callId.trimmingCharacters(in: .whitespacesAndNewlines)
		let sid = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
		let pushAlias = lastReportedCallId.trimmingCharacters(in: .whitespacesAndNewlines)
		if pushAlias.isEmpty { return false }
		if cid.isEmpty { return true }
		if cid == pushAlias { return true }
		if !sid.isEmpty {
			if let lastUuid = lastReportedUUID, let id = callIds[lastUuid],
			   !id.sessionId.isEmpty, id.sessionId == sid
			{
				return true
			}
			if let snap = stickyRingingSnapshot,
			   !snap.sessionId.isEmpty, snap.sessionId == sid,
			   snap.callId == pushAlias || stickyPrimaryCallId == pushAlias
			{
				return true
			}
		}
		if let underAlias = BeamioNativeVoiceSignaling.cachedOffer(
			callId: pushAlias,
			sessionId: sid
		) {
			if underAlias.callId == cid { return true }
			if !sid.isEmpty, !underAlias.sessionId.isEmpty, underAlias.sessionId == sid,
			   underAlias.callId == cid || cid.isEmpty
			{
				return true
			}
		}
		if let endingOffer = BeamioNativeVoiceSignaling.cachedOffer(callId: cid, sessionId: sid),
		   let underAlias = BeamioNativeVoiceSignaling.cachedOffer(callId: pushAlias, sessionId: "")
		{
			if endingOffer.callId == underAlias.callId { return true }
			if !endingOffer.sessionId.isEmpty, endingOffer.sessionId == underAlias.sessionId {
				return true
			}
		}
		return false
	}

	func end(callId: String, sessionId: String = "") {
		// Cancel any deferred soft-reassert that would revive the ring after remote end.
		// v70: also tear rescue/heal/dead-fallback storm so Cancel while BACKGROUND
		// cannot keep openURL-looping after voice_end.
		let cid = callId.trimmingCharacters(in: .whitespacesAndNewlines)
		let sid = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
		let pushAlias = lastReportedCallId.trimmingCharacters(in: .whitespacesAndNewlines)
		// v83: only treat pushAlias as this cancel when it is the same live call.
		let usePushAlias = cancelAliasesLastReported(callId: cid, sessionId: sid)
		abortSoftReassertStorm(reason: "end-remote-preclear", callId: cid)

		/// Soft-reassert can leave A + A' briefly under maximumCallGroups=2.
		/// Tear every owned UUID that matches this cancel — one miss leaves chrome ringing.
		/// Soft-reassert / system CXEnd may clear `callIds` while SpringBoard still
		/// shows Incoming — fall back to lastReportedUUID + ownedIncomingCallIds.
		func resolveUuids() -> [UUID] {
			func ownedMatches(_ ownedCid: String) -> Bool {
				(!cid.isEmpty && ownedCid == cid)
					|| (usePushAlias && !pushAlias.isEmpty && ownedCid == pushAlias)
			}
			var found = Set<UUID>()
			for (uuid, id) in callIds {
				if matches(id, callId: cid, sessionId: sid) { found.insert(uuid) }
			}
			if !sid.isEmpty {
				for (uuid, id) in callIds where !id.sessionId.isEmpty && id.sessionId == sid {
					found.insert(uuid)
				}
			}
			if usePushAlias, !pushAlias.isEmpty {
				for (uuid, id) in callIds where id.callId == pushAlias {
					found.insert(uuid)
				}
			}
			if let sticky = stickyPrimaryUUID {
				let stickyIdMatches =
					(!cid.isEmpty && stickyPrimaryCallId == cid)
					|| (usePushAlias && !pushAlias.isEmpty && stickyPrimaryCallId == pushAlias)
					|| stickyRingingSnapshot.map { matches($0, callId: cid, sessionId: sid) } == true
					|| callIds[sticky].map { matches($0, callId: cid, sessionId: sid) } == true
				if stickyIdMatches {
					found.insert(sticky)
				}
			}
			// Survives map clears: every Incoming UUID we reported for this callId.
			for (uuid, ownedCid) in ownedIncomingCallIds where ownedMatches(ownedCid) {
				found.insert(uuid)
			}
			if let lastUuid = lastReportedUUID,
			   (!cid.isEmpty && lastReportedCallId == cid)
				|| (usePushAlias && !pushAlias.isEmpty && lastReportedCallId == pushAlias)
			{
				found.insert(lastUuid)
			}
			// Last resort: our still-ringing map entries when cancel identity
			// matches the last PushKit / sticky ring (map remapped mid-cancel).
			if found.isEmpty {
				let cancelMatchesLastRing =
					(!cid.isEmpty && (cid == pushAlias || stickyPrimaryCallId == cid))
					|| (usePushAlias && !pushAlias.isEmpty && stickyPrimaryCallId == pushAlias)
					|| stickyRingingSnapshot.map { matches($0, callId: cid, sessionId: sid) } == true
				if cancelMatchesLastRing {
					for uuid in callIds.keys {
						guard controller.callObserver.calls.contains(where: {
							$0.uuid == uuid && !$0.hasEnded && !$0.hasConnected && !$0.isOutgoing
						}) else { continue }
						found.insert(uuid)
					}
					if found.isEmpty, let sticky = stickyPrimaryUUID {
						found.insert(sticky)
					}
					if found.isEmpty, let lastUuid = lastReportedUUID {
						found.insert(lastUuid)
					}
				}
			}
			return Array(found)
		}

		let uuids = resolveUuids()
		// Snapshot before map clear — CXEnd's emit() looks up callIds[uuid] and
		// becomes a no-op once we remove entries below. Answered InCall then stayed
		// open after browser Hang Up (v71).
		let snappedIdentity = uuids.compactMap { callIds[$0] }.first
		let inCallLiveNow = BeamioInCallScreenModel.shared.live
		let wasAnswered = uuids.contains(where: { answeredCallUUIDs.contains($0) }) || inCallLiveNow
		let endCallId: String = {
			if !cid.isEmpty { return cid }
			if let id = snappedIdentity?.callId, !id.isEmpty { return id }
			if inCallLiveNow {
				let liveId = BeamioInCallScreenModel.shared.callId
				if !liveId.isEmpty { return liveId }
			}
			return pushAlias
		}()
		let endSessionId: String = {
			if !sid.isEmpty { return sid }
			if let id = snappedIdentity?.sessionId, !id.isEmpty { return id }
			if inCallLiveNow {
				return BeamioInCallScreenModel.shared.sessionId
			}
			return ""
		}()

		/// Close shell InCall + media even when CallKit UUID is already gone.
		func tearDownShellInCall(reason: String) {
			let run = {
				let inCallLive = BeamioInCallScreenModel.shared.live
				guard wasAnswered || inCallLive else { return }
				NSLog(
					"[BeamioCallKit] end tear InCall reason=%@ callId=%@ answered=%@ live=%@",
					reason,
					endCallId,
					wasAnswered ? "yes" : "no",
					inCallLive ? "yes" : "no"
				)
				BeamioNativeVoiceSignaling.qaTrail(
					"end tear InCall reason=\(reason) callId=\(endCallId.prefix(8))"
				)
				// Prefer the normal callEnded path (hangup uplink when local, skip when
				// remoteEnded already marked). Always force-close InCall afterward —
				// callId may be PushKit alias vs offer callId.
				if !endCallId.isEmpty {
					self.onAction?("callEnded", endCallId, endSessionId)
				}
				BeamioNativeVoiceChannel.shared.stop()
				BeamioNativeVoiceSignaling.clearActiveCall()
				BeamioInCallScreenModel.shared.end(callId: "")
			}
			if Thread.isMainThread {
				run()
			} else {
				DispatchQueue.main.async(execute: run)
			}
		}

		guard !uuids.isEmpty else {
			// Still clear sticky snap so a later soft-reassert cannot revive a cancelled call.
			// v83: do not clear sticky for an unrelated history voice_end via pushAlias alone.
			if let snap = stickyRingingSnapshot,
			   (!cid.isEmpty && snap.callId == cid)
				|| (!sid.isEmpty && !snap.sessionId.isEmpty && snap.sessionId == sid)
				|| (usePushAlias && !pushAlias.isEmpty && snap.callId == pushAlias)
			{
				NSLog(
					"[BeamioCallKit] end clear sticky snap (no live uuid) callId=%@ sessionId=%@",
					cid,
					sid
				)
				stickyRingingSnapshot = nil
				stickyPrimaryUUID = nil
				stickyPrimaryCallId = ""
			} else {
				NSLog(
					"[BeamioCallKit] end skip — no uuid for callId=%@ sessionId=%@ last=%@ lastUUID=%@",
					cid,
					sid,
					pushAlias,
					lastReportedUUID?.uuidString ?? "-"
				)
				BeamioNativeVoiceSignaling.qaTrail(
					"end skip — no uuid callId=\(cid.prefix(8)) last=\(pushAlias.prefix(8))"
				)
			}
			// Drop owned tracking for this cancel so soft-reassert cannot revive.
			let dropCid = cid.isEmpty ? pushAlias : cid
			if !dropCid.isEmpty {
				for (uuid, ownedCid) in ownedIncomingCallIds where ownedCid == dropCid {
					forgetOwnedIncoming(uuid: uuid)
				}
			}
			tearDownShellInCall(reason: "no-uuid")
			return
		}

		NSLog(
			"[BeamioCallKit] end remote callId=%@ sessionId=%@ uuids=%@ sticky=%@ answered=%@",
			cid,
			sid,
			uuids.map(\.uuidString).joined(separator: ","),
			stickyPrimaryUUID?.uuidString ?? "-",
			wasAnswered ? "yes" : "no"
		)
		writeBusyQaBreadcrumb(
			"end-remote:\(cid.isEmpty ? "-" : cid):sid=\(sid.isEmpty ? "-" : sid):n=\(uuids.count):answered=\(wasAnswered ? "1" : "0")"
		)
		BeamioNativeVoiceSignaling.qaTrail(
			"end remote callId=\(cid.prefix(8)) n=\(uuids.count) answered=\(wasAnswered) sticky=\(stickyPrimaryUUID?.uuidString.prefix(8) ?? "-")"
		)

		tearDownShellInCall(reason: "with-uuid")

		stickyRingingSnapshot = nil
		if let sticky = stickyPrimaryUUID {
			clearStickyPrimary(uuid: sticky)
		} else {
			stickyPrimaryUUID = nil
			stickyPrimaryCallId = ""
		}

		for uuid in uuids {
			markIntentionallyEnding(uuid)
			// Prefer provider.reportCall(endedAt:) — CXEnd while busy/openURL often races
			// with soft-reassert and leaves chrome ringing. reportCall tears immediately.
			provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
			callIds.removeValue(forKey: uuid)
			answeredCallUUIDs.remove(uuid)
			forgetOwnedIncoming(uuid: uuid)
			if pendingMediaStartUUID == uuid {
				pendingMediaStartUUID = nil
			}
			// Also request CXEnd so CallKit controller bookkeeping stays consistent.
			controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { error in
				if let error {
					NSLog("[BeamioCallKit] end CXEnd (post reportCall) %@", error.localizedDescription)
				}
			}
		}
		if lastReportedCallId == endCallId || lastReportedCallId == cid || lastReportedCallId == pushAlias {
			lastReportedCallId = ""
			lastReportedUUID = nil
		}
	}

	/// Device QA: programmatically Answer the ringing CallKit call
	/// (`beamio://debug-answer`).
	///
	/// - `stay == false` (default): suspend first, Answer while backgrounded,
	///   then re-suspend — CallKit Speaker/Mute/End chrome screenshots.
	/// - `stay == true` (`?stay=1`): Answer only, **no** private suspend —
	///   mirrors user Accept on CallKit. Use this to verify Accept → in-call
	///   UI stays (v87/v88 leave-alone gates). Do **not** use default mode to
	///   claim Accept-stay PASS (re-suspend deliberately collapses the shell).
	func answer(callId: String, sessionId: String = "", stay: Bool = false) {
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
		NSLog(
			"[BeamioCallKit] answer request callId=%@ uuid=%@ stay=%@",
			resolvedCallId,
			uuid.uuidString,
			stay ? "1" : "0"
		)
		if stay {
			// Accept-stay QA: same path as user tapping Accept — CXAnswer only.
			DispatchQueue.main.async { [weak self] in
				guard let self else { return }
				guard !self.answeredCallUUIDs.contains(uuid) else { return }
				self.controller.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { error in
					if let error {
						NSLog("[BeamioCallKit] answer-stay request FAILED %@", error.localizedDescription)
					} else {
						NSLog("[BeamioCallKit] answer-stay request OK — no private suspend (v89)")
						self.writeBusyQaBreadcrumb("answer-stay-ok:\(resolvedCallId)")
					}
				}
			}
			return
		}
		DispatchQueue.main.async {
			beamioPerformPrivateAppSuspend()
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
				beamioPerformPrivateAppSuspend()
				NSLog("[BeamioCallKit] re-suspend after answer")
			}
		}
	}

	private func matches(_ identity: CallIdentity, callId: String, sessionId: String) -> Bool {
		// Prefer callId. Do not let sessionId-alone match a different callId — that
		// swallowed redial CallKit after Decline when a stale map row remained.
		if !callId.isEmpty, !identity.callId.isEmpty {
			return identity.callId == callId
		}
		if callId.isEmpty, !sessionId.isEmpty, !identity.sessionId.isEmpty {
			return identity.sessionId == sessionId
		}
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
		let hadSticky = stickyPrimaryUUID != nil || stickyRingingSnapshot != nil
		NSLog(
			"[BeamioCallKit] providerDidReset — clearing %d call(s) sticky=%@",
			callIds.count,
			hadSticky ? "yes" : "no"
		)
		writeBusyQaBreadcrumb(
			"provider-did-reset:calls=\(callIds.count):sticky=\(hadSticky ? "yes" : "no")"
		)
		callIds.removeAll()
		answeredCallUUIDs.removeAll()
		pendingMediaStartUUID = nil
		stickyPrimaryUUID = nil
		stickyPrimaryCallId = ""
		stickyRingingSnapshot = nil
		softReassertAttempt = 0
		softReassertInFlight = false
		pendingSoftReassertWorkItem?.cancel()
		pendingSoftReassertWorkItem = nil
		cancelStickyHealProbes(reason: "provider-reset")
		intentionallyEndingUUIDs.removeAll()
		restoreAudioSession()
	}

	func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
		guard callIds[action.callUUID] != nil else {
			NSLog("[BeamioCallKit] Answer REFUSE unknown uuid=%@", action.callUUID.uuidString)
			action.fail()
			return
		}
		NSLog("[BeamioCallKit] Answer uuid=%@", action.callUUID.uuidString)
		BeamioQALog.write(
			"callkit answer callId=\(callIds[action.callUUID]?.callId.prefix(8) ?? "-") appState=\(UIApplication.shared.applicationState.rawValue)"
		)
		answeredCallUUIDs.insert(action.callUUID)
		pendingMediaStartUUID = action.callUUID
		softReassertAttempt = 0
		softReassertInFlight = false
		pendingSoftReassertWorkItem?.cancel()
		pendingSoftReassertWorkItem = nil
		cancelStickyHealProbes(reason: "answer-\(action.callUUID.uuidString)")
		clearBusyZombieChromeHeal(reason: "answer-\(action.callUUID.uuidString)")
		clearBusyChromePresumedDead(reason: "answer-\(action.callUUID.uuidString)")
		clearBusyChromeGuard(reason: "answer-\(action.callUUID.uuidString)")
		// Answered — ringing snapshot no longer needed for soft-reassert.
		if let id = callIds[action.callUUID] {
			clearStickyRingingSnapshot(callId: id.callId)
		}
		// Must configure AVAudioSession *before* fulfill — otherwise CallKit
		// presents the connected UI without a ready audio session and the
		// system button grid collapses (Speaker / Mute / End piled left).
		configureAudioSessionForCall()
		// Show the shell in-call UI *before* fulfill / bringAppForward.
		// Waiting for didActivate → sendAccept (network) left a gap where
		// waking the app showed CallKit's full-screen Accept/Decline again.
		// Identity for the screen comes from callIds; accept uplink stays async.
		let answeredIdentity = callIds[action.callUUID]
		let beginBlock = {
			guard let identity = answeredIdentity else { return }
			let chrome = identity.chromeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
			let tag = BeamioIncomingCallPayload.normalizedBeamioTag(chrome) ?? ""
			let handle = identity.displayHandle.trimmingCharacters(in: .whitespacesAndNewlines)
			let address: String = {
				if handle.lowercased().hasPrefix("0x"), handle.count >= 10 { return handle }
				if chrome.lowercased().hasPrefix("0x"), chrome.count >= 10 { return chrome }
				return ""
			}()
			BeamioInCallScreenModel.shared.begin(
				callId: identity.callId,
				sessionId: identity.sessionId,
				tag: tag,
				address: address
			)
		}
		if Thread.isMainThread {
			beginBlock()
		} else {
			DispatchQueue.main.sync(execute: beginBlock)
		}
		let answeredCallId = answeredIdentity?.callId ?? ""
		writeBusyQaBreadcrumb(
			"lock-answer-shell-begin:cxAnswer:uuid=\(action.callUUID.uuidString.prefix(8)):callId=\(answeredCallId.prefix(8)):appState=\(UIApplication.shared.applicationState.rawValue)"
		)
		// Do NOT reportCall(updated:) here — mid-Answer CXCallUpdate races the
		// system connected-call layout. Do NOT emit callAnswered yet — native
		// accept uplink waits until didActivate.
		action.fulfill()
	}

	func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
		// v69: busy reject was queued so OpenPGP's WKWebView would not drop
		// the live banner. Flush only once this end has cleared the call.
		DispatchQueue.main.async { [weak self] in
			guard let self, !self.hasLiveCallKitCall() else { return }
			BeamioNativeVoiceSignaling.flushDeferredStickyDeclines()
		}
		let uuid = action.callUUID
		let intentional = intentionallyEndingUUIDs.remove(uuid) != nil
		let identity = callIds[uuid]
		let wasAnswered = answeredCallUUIDs.contains(uuid)
		let isSticky = stickyPrimaryUUID == uuid
		// v38: resolve identity from stickyRingingSnapshot when callIds already
		// cleared (ghost clear / race) — otherwise sticky SYSTEM End fell through
		// to normal End with no system-cxend breadcrumb (v37 after-b).
		let resolvedStickyIdentity: CallIdentity? = {
			if let identity, identity.isOutgoing != true { return identity }
			if let snap = stickyRingingSnapshot, snap.isOutgoing != true { return snap }
			return nil
		}()
		let isStickyRinging = isSticky && !wasAnswered && resolvedStickyIdentity != nil

		// v18: system killed sticky ringing A (openURL B wake) → deferred soft-reassert.
		// Do NOT emit callRejected (would sendDecline to peer A). Snapshot keeps busy
		// gate; soft-reassert intentionally ends old UUID then reports A'.
		// v38: under busy-guard prefer heal-only (soft-reassert/chrome-rescue can
		// intentional-End A); soft-reassert already no-ops via busy-live skip.
		if !intentional, isStickyRinging, let stickyIdentity = resolvedStickyIdentity {
			// Peer already cancelled (chat voice_end) — tear sticky; never soft-reassert.
			if BeamioNativeVoiceSignaling.wasRemoteEnded(
				callId: stickyIdentity.callId,
				sessionId: stickyIdentity.sessionId
			) {
				NSLog(
					"[BeamioCallKit] End SYSTEM sticky SKIP soft-reassert — remoteEnded callId=%@",
					stickyIdentity.callId
				)
				writeBusyQaBreadcrumb(
					"system-cxend-sticky-remote-ended:\(stickyIdentity.callId):uuid=\(uuid.uuidString)"
				)
				if pendingMediaStartUUID == uuid {
					pendingMediaStartUUID = nil
				}
				answeredCallUUIDs.remove(uuid)
				callIds.removeValue(forKey: uuid)
				abortSoftReassertStorm(
					reason: "system-cxend-remote-ended",
					callId: stickyIdentity.callId
				)
				action.fulfill()
				return
			}
			// v70: gate soft-reassert on busy ALREADY active BEFORE this End.
			// Natural Decline / iOS ~60s unanswered timeout arrives with busy=no.
			// Old path armed busy then ALWAYS soft-reasserted → rescue storm → jetsam
			// → peer Cancel never delivered. Only openURL-collision Ends had busy=yes.
			let wasBusyBefore = isBusyChromeGuardActive()
			NSLog(
				"[BeamioCallKit] End SYSTEM sticky ringing uuid=%@ callId=%@ wasBusy=%@ — %@",
				uuid.uuidString,
				stickyIdentity.callId,
				wasBusyBefore ? "yes" : "no",
				wasBusyBefore ? "soft-reassert deferred, no emit" : "natural clear + Decline"
			)
			writeBusyQaBreadcrumb(
				"system-cxend-sticky:\(stickyIdentity.callId):uuid=\(uuid.uuidString):busy=\(wasBusyBefore ? "yes" : "no")"
			)
			if pendingMediaStartUUID == uuid {
				pendingMediaStartUUID = nil
			}
			answeredCallUUIDs.remove(uuid)
			callIds.removeValue(forKey: uuid)
			action.fulfill()

			if !wasBusyBefore {
				// User Decline or system timeout — clear sticky; emit Decline so
				// shell sendDecline stops peer ring. Never soft-reassert / rescue.
				writeBusyQaBreadcrumb(
					"system-cxend-sticky-natural-clear:\(stickyIdentity.callId)"
				)
				abortSoftReassertStorm(
					reason: "system-cxend-natural",
					callId: stickyIdentity.callId
				)
				// Same route as a normal Decline: the shell sends the reject
				// uplink now. Deferring to the WebView left the caller ringing
				// while Beamio stayed in the background.
				onAction?("callRejected", stickyIdentity.callId, stickyIdentity.sessionId)
				return
			}

			// True busy collision (openURL B woke host while A still sticky).
			stickyRingingSnapshot = stickyIdentity
			stickyPrimaryUUID = nil
			stickyPrimaryCallId = ""
			armBusyChromeGuard(reason: "system-cxend", seconds: 30)
			beginIdentityBackgroundTaskIfNeeded()
			writeBusyQaBreadcrumb(
				"system-cxend-sticky-busy-soft-reassert:\(stickyIdentity.callId)"
			)
			scheduleDeferredSoftReassert(
				reason: "system-cxend-busy",
				delay: 0.08,
				scheduleSuspendOnSuccess: true,
				forceReplaceEvenIfAlive: false
			)
			scheduleStickyHealProbes(reason: "system-cxend-busy")
			scheduleBusyChromeResuspend(reason: "system-cxend-busy")
			return
		}

		// Snapshot-only: sticky UUID already cleared but ringing snap still ours.
		// Match End to snap via callIds identity, OR identity-nil End when snap's
		// callId is no longer in callIds (ghost clear). Never treat secondary B
		// End as snap soft-reassert.
		if !intentional,
		   !wasAnswered,
		   stickyPrimaryUUID == nil,
		   let snap = stickyRingingSnapshot,
		   snap.isOutgoing != true,
		   (identity?.callId == snap.callId
			|| (identity == nil
				&& !callIds.values.contains(where: { $0.callId == snap.callId })))
		{
			if BeamioNativeVoiceSignaling.wasRemoteEnded(
				callId: snap.callId,
				sessionId: snap.sessionId
			) {
				NSLog(
					"[BeamioCallKit] End SYSTEM snap-only SKIP soft-reassert — remoteEnded callId=%@",
					snap.callId
				)
				writeBusyQaBreadcrumb(
					"system-cxend-snap-remote-ended:\(snap.callId):uuid=\(uuid.uuidString)"
				)
				if pendingMediaStartUUID == uuid {
					pendingMediaStartUUID = nil
				}
				answeredCallUUIDs.remove(uuid)
				callIds.removeValue(forKey: uuid)
				abortSoftReassertStorm(
					reason: "system-cxend-snap-remote-ended",
					callId: snap.callId
				)
				action.fulfill()
				return
			}
			// v70: same natural vs busy gate as sticky UUID path.
			let wasBusyBefore = isBusyChromeGuardActive()
			NSLog(
				"[BeamioCallKit] End SYSTEM snap-only ringing uuid=%@ callId=%@ wasBusy=%@",
				uuid.uuidString,
				snap.callId,
				wasBusyBefore ? "yes" : "no"
			)
			writeBusyQaBreadcrumb(
				"system-cxend-snap:\(snap.callId):uuid=\(uuid.uuidString):busy=\(wasBusyBefore ? "yes" : "no")"
			)
			if pendingMediaStartUUID == uuid {
				pendingMediaStartUUID = nil
			}
			answeredCallUUIDs.remove(uuid)
			callIds.removeValue(forKey: uuid)
			action.fulfill()
			if !wasBusyBefore {
				writeBusyQaBreadcrumb(
					"system-cxend-snap-natural-clear:\(snap.callId)"
				)
				abortSoftReassertStorm(
					reason: "system-cxend-snap-natural",
					callId: snap.callId
				)
				// Same route as a normal Decline: the shell sends the reject now.
				onAction?("callRejected", snap.callId, snap.sessionId)
				return
			}
			stickyRingingSnapshot = snap
			armBusyChromeGuard(reason: "system-cxend-snap")
			beginIdentityBackgroundTaskIfNeeded()
			scheduleStickyHealProbes(reason: "system-cxend-snap-busy")
			return
		}

		// Incoming unanswered End = Decline (`callRejected` → shell sendDecline).
		// Outgoing unanswered End = local hangup only (native dialer stop; no Decline).
		// After Answer: Hang Up → `callEnded`.
		let bridgeAction: String
		if identity?.isOutgoing == true {
			bridgeAction = "callEnded"
		} else {
			bridgeAction = wasAnswered ? "callEnded" : "callRejected"
		}
		writeBusyQaBreadcrumb(
			"cxend-normal:\(identity?.callId ?? "-"):uuid=\(uuid.uuidString):intentional=\(intentional ? "yes" : "no"):sticky=\(isSticky ? "yes" : "no"):answered=\(wasAnswered ? "yes" : "no"):→\(bridgeAction)"
		)
		NSLog(
			"[BeamioCallKit] End uuid=%@ callId=%@ sessionId=%@ answered=%@ outgoing=%@ intentional=%@ sticky=%@ → %@",
			uuid.uuidString,
			identity?.callId ?? "",
			identity?.sessionId ?? "",
			wasAnswered ? "yes" : "no",
			identity?.isOutgoing == true ? "yes" : "no",
			intentional ? "yes" : "no",
			isSticky ? "yes" : "no",
			bridgeAction
		)
		if pendingMediaStartUUID == uuid {
			pendingMediaStartUUID = nil
		}
		clearStickyPrimary(uuid: uuid)
		clearStickyRingingSnapshot(callId: identity?.callId ?? "")
		emit(bridgeAction, uuid)
		answeredCallUUIDs.remove(uuid)
		callIds.removeValue(forKey: uuid)
		action.fulfill()
	}

	func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
		BeamioCallTiming.mark("callkit-perform-start")
		configureAudioSessionForCall()
		provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
		emit("callStarted", action.callUUID)
		action.fulfill()
	}

	func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
		// Mute is owned here, not by the audio session: the shell sends the
		// microphone itself, so nothing changed when the system Mute button (lock
		// screen, Dynamic Island) or the in-call screen was pressed.
		BeamioNativeVoiceChannel.shared.setMuted(action.isMuted)
		DispatchQueue.main.async {
			BeamioInCallScreenModel.shared.syncMuted(action.isMuted)
		}
		action.fulfill()
	}

	/// In-call screen Mute button → CallKit, so the system UI and ours agree.
	func requestMuted(callId: String, sessionId: String = "", muted: Bool) {
		guard let uuid = callIds.first(where: {
			matches($0.value, callId: callId, sessionId: sessionId)
		})?.key else {
			NSLog("[BeamioCallKit] mute skip — no uuid for callId=%@", callId)
			return
		}
		controller.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted))) { error in
			if let error {
				NSLog("[BeamioCallKit] mute request FAILED %@", error.localizedDescription)
			}
		}
	}

	func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
		NSLog("[BeamioCallKit] timedOutPerforming %@", String(describing: type(of: action)))
		action.fulfill()
	}

	/// v53: SYSTEM Ended sticky A under busy-guard → restoreStickyCallKitChrome
	/// (DEAD only). Never ring-keepalive / PRE-END (v52 self-destruct).
	func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
		guard call.hasEnded else { return }
		let uuid = call.uuid
		let isSticky = stickyPrimaryUUID == uuid
		let wasAnswered = answeredCallUUIDs.contains(uuid)
		guard isSticky, !wasAnswered else { return }
		guard isBusyChromeGuardActive() else { return }
		// Intentional End (Decline / busy-flash) — CXEndCallAction path owns it.
		if intentionallyEndingUUIDs.contains(uuid) { return }

		let snap = stickyRingingSnapshot
			?? callIds[uuid].flatMap { $0.isOutgoing ? nil : $0 }
		guard let identity = snap, !identity.isOutgoing else {
			writeBusyQaBreadcrumb(
				"call-observer-sticky-ended-no-snap:\(uuid.uuidString)"
			)
			return
		}

		NSLog(
			"[BeamioCallKit] CXCallObserver sticky Ended uuid=%@ callId=%@ — restoreSticky (v53)",
			uuid.uuidString,
			identity.callId
		)
		writeBusyQaBreadcrumb(
			"call-observer-sticky-ended:\(identity.callId):uuid=\(uuid.uuidString)"
		)
		stickyRingingSnapshot = identity
		callIds.removeValue(forKey: uuid)
		stickyPrimaryUUID = nil
		stickyPrimaryCallId = ""
		answeredCallUUIDs.remove(uuid)
		armBusyChromeGuard(reason: "call-observer-ended", seconds: 30)
		beginIdentityBackgroundTaskIfNeeded()
		restoreStickyCallKitChrome(reason: "call-observer-sticky-ended")
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
		// Dialer: ringback plays from here until Accept / end (no-op otherwise).
		BeamioCallTonePlayer.shared.callAudioDidActivate()
		// After lock-screen Answer, re-assert shell in-call presentation so unlock
		// lands on BeamioInCallScreen (aligned layout), not only CallKit chrome.
		// Must not early-return when presented is already true — wake + retries.
		DispatchQueue.main.async { [weak self] in
			let model = BeamioInCallScreenModel.shared
			guard model.live else { return }
			NSLog("[BeamioCallKit] didActivate → reassert shell in-call surface")
			self?.writeBusyQaBreadcrumb(
				"lock-answer-reassert:didActivate:callId=\(model.callId.prefix(8)):appState=\(UIApplication.shared.applicationState.rawValue)"
			)
			model.reassertAfterCallKitActivate()
		}
		// Native Accept + voice channel after CallKit owns the audio session.
		// Do not wait for PWA / getUserMedia.
		guard let uuid = pendingMediaStartUUID else { return }
		pendingMediaStartUUID = nil
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
			guard let self else { return }
			guard self.answeredCallUUIDs.contains(uuid),
			      let identity = self.callIds[uuid]
			else { return }
			NSLog(
				"[BeamioCallKit] native accept after didActivate uuid=%@ callId=%@",
				uuid.uuidString,
				identity.callId
			)
			BeamioNativeVoiceSignaling.sendAccept(
				callId: identity.callId,
				sessionId: identity.sessionId
			)
		}
	}

	func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
		BeamioCallTonePlayer.shared.callAudioDidDeactivate()
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
		callKit.setWebBridge(bridge)
		guard let bridge, !pendingBridgeActions.isEmpty else { return }
		let queued = pendingBridgeActions
		pendingBridgeActions.removeAll()
		for item in queued {
			bridge(item.action, item.callId, item.sessionId)
		}
	}

	/// Shell dialer → PWA UI status (callAnswered / callRejected) without CX action.
	func emitToWeb(_ action: String, callId: String, sessionId: String) {
		callKit.emitToWeb(action, callId: callId, sessionId: sessionId)
	}

	/// Alert APNs / debug-incoming / PWA soft-seed → system CallKit only.
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

	/// System CallKit Incoming only (no Beamio glass overlay). Plays the system
	/// ringtone; after report, `reportCall(updated:)` fills `@BeamioTag`.
	/// `requiresCallKit` is retained for API compatibility (always CallKit).
	///
	/// **Single-call gate:** while another call is ringing or connected:
	/// - DeepLink / Alert APNs: **skip** second CallKit report (keeps first banner)
	/// - PushKit: still `reportNewIncomingCall` (Apple) then CXEnd only that UUID
	/// DeepLink / Alert second inbound while sticky/busy: **decline B only**.
	/// Never `reportCallKit` / recreate — that wakes openURL and system-CXEnds A.
	func rejectSecondaryWhileBusy(
		callId: String,
		sessionId: String,
		completion: ((Error?) -> Void)? = nil
	) {
		NSLog(
			"[BeamioVoip] rejectSecondaryWhileBusy callId=%@ sessionId=%@",
			callId,
			sessionId
		)
		// v64: arm busy-guard + preserve absolute CallKit noop while A LIVE;
		// decline B only (reason=busy). Never tear / report / CXCallUpdate A.
		BeamioDeepLink.suppressPasteboardDeferredDeepLink(forSeconds: 30)
		callKit.armBusyChromeGuard(reason: "deeplink-busy-\(callId)", seconds: 30)
		callKit.cancelPendingChromeSuspend(reason: "deeplink-busy")
		callKit.preserveStickyChromeAfterBusySync(reason: "deeplink-busy-\(callId)")
		callKit.noteBusyDeclineProtectsChrome(callId: callId)
		BeamioNativeVoiceSignaling.sendDecline(
			callId: callId,
			sessionId: sessionId,
			reason: "busy",
			protectStickyChrome: true
		)
		callKit.emitToWebWhenForeground("callRejected", callId: callId, sessionId: sessionId)
		DispatchQueue.main.async { completion?(nil) }
	}

	/// Always `sendDecline(busy)` + `emitToWeb(callRejected)` for chat leave-behind.
	func reportIncomingCallKit(
		callId: String,
		sessionId: String,
		peerAddress: String,
		displayName: String,
		claimedTag: String = "",
		claimedAddress: String = "",
		identityWarning: String = "",
		requiresCallKit: Bool = true,
		mustReportForPushKit: Bool = false,
		completion: ((Error?) -> Void)? = nil
	) {
		_ = requiresCallKit
		_ = identityWarning
		dismissGlassIncomingIfPresent()
		let payload = BeamioIncomingCallPayload(
			callId: callId,
			sessionId: sessionId,
			peerAddress: peerAddress,
			displayName: displayName,
			claimedTag: claimedTag,
			claimedAddress: claimedAddress,
			identityWarning: identityWarning
		)
		// Prefer already-known `@BeamioTag` for the first CallKit report so SE
		// never locks the banner on opaque "Beamio" while resolve races.
		// Push without identity still reports opaque; applyKnownTag / resolve
		// paints later. Never put wallet/tag into push plaintext.
		let firstReportHandle: String = {
			let known = payload.titleTag.trimmingCharacters(in: .whitespacesAndNewlines)
			if !known.isEmpty { return known }
			return payload.callKitHandle
		}()
		// This device already declined or hung up this call. A soft report (PWA
		// bridge, replayed chat offer) must not ring it again. PushKit still
		// takes the normal path (Apple requires a report for every VoIP push).
		if !mustReportForPushKit,
		   BeamioNativeVoiceSignaling.wasLocallyEnded(callId: callId, sessionId: sessionId)
		{
			NSLog("[BeamioVoip] soft report SKIP — already ended on this device callId=%@", callId)
			callKit.writeBusyQaBreadcrumb("soft-skip-locally-ended:\(callId)")
			DispatchQueue.main.async { completion?(nil) }
			return
		}
		let now = Date()
		let softRecentSame =
			callId == lastReportedCallId && now.timeIntervalSince(lastReportedAt) < 2
		let callKitLiveSame = callKit.hasLiveIncoming(forCallId: callId, sessionId: sessionId)
		// Soft short-circuit ONLY when CallKit still shows this incoming.
		// v84 used `softRecentSame || callKitLiveSame` — after an early CXEnd /
		// ghost tear, softRecentSame stayed true for 2s with ck=false and
		// blocked re-report → flash-hide (crumb soft-shortcut-live:…:ck=false).
		// v85: never short-circuit on softRecent alone; fall through to
		// remote-ended / clearGhost / report so CallKit can be restored.
		// PushKit must NEVER take this shortcut (Apple VoIP completion rule).
		if !mustReportForPushKit, callKitLiveSame {
			NSLog(
				"[BeamioVoip] soft short-circuit callId=%@ softRecent=%@ callKitLive=yes — refresh BeamioTag only",
				callId,
				softRecentSame ? "yes" : "no"
			)
			callKit.writeBusyQaBreadcrumb(
				"soft-shortcut-live:\(callId):soft=\(softRecentSame):ck=true"
			)
			applyKnownTagThenScheduleVerify(payload: payload)
			DispatchQueue.main.async { completion?(nil) }
			return
		}
		if !mustReportForPushKit, softRecentSame, !callKitLiveSame {
			callKit.writeBusyQaBreadcrumb(
				"soft-recent-dead-rereport:\(callId):soft=true:ck=false"
			)
		}

		// Soft FG + remoteEnded:
		// - Already owned/live CallKit → always soft-skip (no re-open).
		// - Never owned: only soft-allow when end was stamped very recently
		//   (close end-before-offer race, ~3s). Older stamps are history dumps —
		//   soft-skip so we do not flash CallKit then tear for every past offer.
		// PushKit action=end still reports (Apple VoIP rule) via mustReportForPushKit.
		if !mustReportForPushKit,
		   let endedAge = BeamioNativeVoiceSignaling.remoteEndedAgeSeconds(
				callId: callId, sessionId: sessionId
		   )
		{
			let ownedOrLive =
				callKit.hasOwnedIncoming(forCallId: callId)
				|| callKit.hasLiveIncoming(forCallId: callId, sessionId: sessionId)
			let closeRaceSeconds: TimeInterval = 3
			if ownedOrLive || endedAge >= closeRaceSeconds {
				let crumb = ownedOrLive
					? "soft-skip-remote-ended:\(callId)"
					: "soft-skip-remote-ended-stale:\(callId):age=\(Int(endedAge))s"
				NSLog(
					"[BeamioVoip] soft report SKIP — remoteEnded age=%.2fs owned=%@ callId=%@",
					endedAge,
					ownedOrLive ? "yes" : "no",
					callId
				)
				callKit.writeBusyQaBreadcrumb(crumb)
				DispatchQueue.main.async { completion?(nil) }
				return
			}
			callKit.writeBusyQaBreadcrumb(
				"soft-allow-end-before-offer:\(callId):age=\(Int(endedAge * 1000))ms"
			)
			NSLog(
				"[BeamioVoip] soft report ALLOW end-before-offer race age=%.2fs callId=%@",
				endedAge,
				callId
			)
		}

		// Soft path while Beamio is behind YouTube (or any other app) must still
		// attempt CallKit. DEFERing to PushKit alone left a silent gap whenever
		// chat SSE arrived first and ios_voip wake was late/missed. Stamp
		// lastReported only after success (below) so a failed soft report never
		// blocks a subsequent PushKit report within 2s.
		NSLog(
			"[BeamioVoip] soft/push report attempt state=%d pushKit=%@ callId=%@",
			UIApplication.shared.applicationState.rawValue,
			mustReportForPushKit ? "yes" : "no",
			callId
		)

		// v80: tear orphan / remote-ended sticky before wasBusy (FG dial was
		// busy-pushkit declining while invisible sticky UUID stayed LIVE).
		// v84: skip when CallKit already owns this incoming (PushKit race).
		if callKit.hasLiveIncoming(forCallId: callId, sessionId: sessionId) {
			callKit.writeBusyQaBreadcrumb("soft-skip-clearGhost-live:\(callId)")
		} else {
			_ = callKit.clearGhostStickyBlockingNewReport(
				reason: "pre-reportIncomingCallKit",
				incomingCallId: callId,
				incomingSessionId: sessionId
			)
		}
		// Must match reportIncoming busy gate (sticky OR live). Sticky-only
		// misses used to set lastReported=B and paint @tag onto A (v12).
		let wasBusy = callKit.isStickyOrBusyExcluding(callId: callId, sessionId: sessionId)

		NSLog(
			"[BeamioVoip] CallKit report callId=%@ sessionId=%@ handle=%@ knownTag=%@ busy=%@ pushKit=%@",
			callId,
			sessionId,
			firstReportHandle,
			payload.titleTag,
			wasBusy ? "yes" : "no",
			mustReportForPushKit ? "yes" : "no"
		)

		// v17: non-PushKit busy → NEVER reportIncoming / endZombie for B.
		// Decline B + callRejected for chat; v27 rescue only if sticky A already dead.
		if wasBusy, !mustReportForPushKit {
			NSLog(
				"[BeamioVoip] busy EARLY-RETURN callId=%@ — decline-only absolute-noop (v64)",
				callId
			)
			// v64: arm + preserve absolute CallKit noop while A LIVE; decline B.
			BeamioDeepLink.suppressPasteboardDeferredDeepLink(forSeconds: 30)
			callKit.armBusyChromeGuard(reason: "busy-early-\(callId)", seconds: 30)
			callKit.cancelPendingChromeSuspend(reason: "busy-early")
			callKit.preserveStickyChromeAfterBusySync(reason: "busy-early-\(callId)")
			callKit.noteBusyDeclineProtectsChrome(callId: callId)
			BeamioNativeVoiceSignaling.sendDecline(
				callId: callId,
				sessionId: sessionId,
				reason: "busy",
				protectStickyChrome: true
			)
			callKit.emitToWebWhenForeground("callRejected", callId: callId, sessionId: sessionId)
			DispatchQueue.main.async { completion?(nil) }
			return
		}

		callKit.reportIncoming(
			callId: callId,
			handle: firstReportHandle,
			sessionId: sessionId,
			mustReportForPushKit: mustReportForPushKit
		) { [weak self] error in
			guard let self else {
				completion?(error)
				return
			}
			if wasBusy {
				// PushKit busy: Apple required reportNewIncomingCall; only that
				// UUID was CXEnd'd inside busyReject. Still sendDecline + chat.
				NSLog(
					"[BeamioVoip] busy PushKit auto-reject callId=%@ reportErr=%@ — sendDecline(busy)+emitToWeb",
					callId,
					error?.localizedDescription ?? "nil"
				)
				// v45: arm + absolute CallKit noop (no revive after PushKit CXEnd B).
				self.callKit.armBusyChromeGuard(reason: "busy-pushkit-\(callId)", seconds: 30)
				self.callKit.cancelPendingChromeSuspend(reason: "busy-pushkit")
				self.callKit.preserveStickyChromeAfterBusySync(
					reason: "busy-pushkit-\(callId)"
				)
				self.callKit.noteBusyDeclineProtectsChrome(callId: callId)
				BeamioNativeVoiceSignaling.sendDecline(
					callId: callId,
					sessionId: sessionId,
					reason: "busy",
					protectStickyChrome: true
				)
				self.callKit.emitToWebWhenForeground(
					"callRejected",
					callId: callId,
					sessionId: sessionId
				)
				completion?(nil)
				return
			}
			// Stamp lastReported only after a real report attempt that can show
			// chrome (success), or after PushKit (Apple already consumed the wake).
			if error == nil || mustReportForPushKit {
				self.lastReportedCallId = callId
				self.lastReportedAt = Date()
			}
			if error == nil {
				self.applyKnownTagThenScheduleVerify(payload: payload)
			}
			completion?(error)
		}
	}

	/// Prefer payload / prefetch `@tag` immediately; then decrypt offer again
	/// for a verified BeamioTag via `reportCall(updated:)`.
	private func applyKnownTagThenScheduleVerify(payload: BeamioIncomingCallPayload) {
		var known = payload.titleTag.trimmingCharacters(in: .whitespacesAndNewlines)
		var short = ""
		if known.isEmpty,
		   let cached = BeamioNativeVoiceSignaling.cachedOffer(
			callId: payload.callId,
			sessionId: payload.sessionId
		   )
		{
			if let tag = BeamioIncomingCallPayload.normalizedBeamioTag(cached.beamioTag) {
				known = tag
			}
			short = cached.shortAddress.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		if !known.isEmpty || !short.isEmpty {
			callKit.updateVerifiedIdentity(
				callId: payload.callId,
				sessionId: payload.sessionId,
				tag: known,
				shortAddress: short
			)
		}
		scheduleVerifiedIdentityUpdate(callId: payload.callId, sessionId: payload.sessionId)
	}

	/// Legacy no-ops — glass Incoming was removed; CallKit is the only UI.
	func acceptGlassIncoming() {
		NSLog("[BeamioVoip] acceptGlassIncoming ignored — use CallKit Answer")
	}

	func declineGlassIncoming() {
		NSLog("[BeamioVoip] declineGlassIncoming ignored — use CallKit Decline")
	}

	func dismissGlassIncomingIfPresent() {
		BeamioIncomingCallGlassHost.dismiss()
	}

	var isGlassIncomingPresented: Bool { false }

	/// Send a call action to the PWA only (no CallKit or uplink side effects).
	/// Queued until the WebView bridge is ready. Main thread.
	func emitCallActionToWeb(_ action: String, callId: String, sessionId: String) {
		if let webBridge {
			webBridge(action, callId, sessionId)
		} else {
			pendingBridgeActions.append((action, callId, sessionId))
		}
	}

	private func forwardCallKitAction(_ action: String, callId: String, sessionId: String) {
		// Decline / Answer / End: native entry path — do not wait for PWA.
		if action == "callRejected" || action == "callEnded" {
			// A later soft report of this call (PWA, replayed offer) must not ring again.
			BeamioNativeVoiceSignaling.markLocallyEnded(callId: callId, sessionId: sessionId)
		}
		if action == "callRejected" {
			if BeamioNativeVoiceSignaling.wasRemoteEnded(callId: callId, sessionId: sessionId) {
				// The caller cancelled: nothing to decline, and no uplink is needed.
				lastReportedCallId = ""
				lastReportedAt = .distantPast
				NSLog("[BeamioVoip] caller cancelled callId=%@ — no decline sent", callId)
				return
			}
			BeamioNativeVoiceSignaling.sendDecline(callId: callId, sessionId: sessionId)
			// Allow a new VoIP push for the same peer to report CallKit again.
			lastReportedCallId = ""
			lastReportedAt = .distantPast
			NSLog(
				"[BeamioVoip] native decline uplink queued callId=%@ (skip PWA)",
				callId
			)
			return
		}
		if action == "callAnswered" {
			BeamioNativeVoiceSignaling.sendAccept(callId: callId, sessionId: sessionId)
			NSLog(
				"[BeamioVoip] native accept uplink queued callId=%@ (skip PWA)",
				callId
			)
			return
		}
		if action == "callEnded" {
			// Tell the peer before the channel and the call record are torn down.
			if !BeamioNativeVoiceSignaling.wasRemoteEnded(callId: callId, sessionId: sessionId) {
				BeamioNativeVoiceSignaling.sendHangup(callId: callId)
			}
			BeamioNativeVoiceChannel.shared.stop()
			BeamioNativeVoiceSignaling.clearActiveCall()
			// PushKit alias vs offer callId can diverge — force-close if still live.
			BeamioInCallScreenModel.shared.end(callId: callId)
			if BeamioInCallScreenModel.shared.live {
				BeamioInCallScreenModel.shared.end(callId: "")
			}
			lastReportedCallId = ""
			lastReportedAt = .distantPast
			NSLog("[BeamioVoip] native voice channel stopped callId=%@; emit PWA UI", callId)
			// Dialer Hang Up / remote end: keep native media ownership, still sync PWA UI.
			if let webBridge {
				webBridge(action, callId, sessionId)
			} else {
				pendingBridgeActions.append((action, callId, sessionId))
			}
			return
		}
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
		let action = ((body["action"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		BeamioNativeVoiceSignaling.qaTrail(
			"pushkit incoming action=\(action.isEmpty ? "ring" : action) callId=\(callId.prefix(8))"
		)
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
			"[BeamioVoip] PushKit incoming type=%@ action=%@ callId=%@ sessionId=%@",
			type.rawValue,
			action.isEmpty ? "ring" : action,
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

		// Caller cancel / hangup while callee is background (YouTube FG): soft SSE is
		// dead, so Chat voice_end never arrives. Mailbox fires VoIP action=end.
		if action == "end" {
			// Chat voice_end often already tore CallKit before this VoIP wake.
			let alreadyEnded = BeamioNativeVoiceSignaling.wasRemoteEnded(
				callId: resolvedId,
				sessionId: sessionId
			)
			let hadLive = callKit.hasLiveCallKitCall()
				|| (!resolvedId.isEmpty && callKit.lastReportedCallId == resolvedId)
			BeamioNativeVoiceSignaling.applyRemoteMediaEnd(callId: resolvedId, sessionId: sessionId)
			if hadLive {
				NSLog("[BeamioVoip] PushKit end — tore live CallKit callId=%@", resolvedId)
				callKit.writeBusyQaBreadcrumb("pushkit-end-tore-live:\(resolvedId)")
				completion()
				return
			}
			// Apple: every VoIP push must report CallKit. Orphan end (process woken
			// only by cancel, or chat already cleared chrome) → report then
			// immediate remoteEnded tear inside reportIncoming (no sticky/suspend).
			NSLog(
				"[BeamioVoip] PushKit end — orphan report+end callId=%@ alreadyEnded=%@",
				resolvedId,
				alreadyEnded ? "yes" : "no"
			)
			callKit.writeBusyQaBreadcrumb(
				"pushkit-end-orphan:\(resolvedId):alreadyEnded=\(alreadyEnded ? "yes" : "no")"
			)
			reportIncomingCallKit(
				callId: resolvedId,
				sessionId: sessionId,
				peerAddress: peerAddress,
				displayName: displayName,
				claimedTag: claimedTag,
				claimedAddress: claimedAddress,
				requiresCallKit: true,
				mustReportForPushKit: true
			) { error in
				if let error {
					NSLog(
						"[BeamioVoip] PushKit end orphan report err=%@",
						error.localizedDescription
					)
				}
				completion()
			}
			return
		}

		// Prefetch offerArmor → sessionKey BEFORE CallKit so a fast Decline can
		// AES-encrypt voice_call_reject_v1. VoIP budget is short; do not await.
		prefetchOfferForIncoming(callId: resolvedId, sessionId: sessionId)
		// Apple: report CallKit and wait for its completion BEFORE PushKit completion().
		// Calling PushKit completion early while app was woken by VoIP can end the call
		// or kill the process (iOS 13+ VoIP entitlement rules). System CallKit only.
		reportIncomingCallKit(
			callId: resolvedId,
			sessionId: sessionId,
			peerAddress: peerAddress,
			displayName: displayName,
			claimedTag: claimedTag,
			claimedAddress: claimedAddress,
			requiresCallKit: true,
			mustReportForPushKit: true
		) { error in
			if let error {
				NSLog(
					"[BeamioVoip] PushKit→CallKit done with error=%@ — still completing PushKit",
					error.localizedDescription
				)
			} else {
				NSLog("[BeamioVoip] PushKit→CallKit done OK — completing PushKit")
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

	/// Decrypt offer on a background queue; `rememberOffer` caches sessionKey for Decline.
	/// Soft-seed may already be ringing — push verified @BeamioTag under PushKit keys.
	private func prefetchOfferForIncoming(callId: String, sessionId: String) {
		guard !callId.isEmpty || sessionId.count >= 16 else { return }
		if let hit = BeamioNativeVoiceSignaling.cachedOffer(callId: callId, sessionId: sessionId),
		   !hit.sessionKey.isEmpty
		{
			NSLog("[BeamioVoip] offer cache hit callId=%@", callId)
			if !hit.beamioTag.isEmpty || !hit.shortAddress.isEmpty {
				DispatchQueue.main.async { [weak self] in
					self?.callKit.updateVerifiedIdentity(
						callId: callId,
						sessionId: sessionId,
						tag: hit.beamioTag,
						shortAddress: hit.shortAddress
					)
				}
			}
			return
		}
		DispatchQueue.global(qos: .userInitiated).async { [weak self] in
			BeamioVoiceOfferIdentity.resolve(callId: callId, sessionId: sessionId) { resolved in
				guard let resolved else {
					NSLog(
						"[BeamioVoip] offer prefetch miss callId=%@ sessionId=%@",
						callId,
						sessionId
					)
					return
				}
				if !resolved.sessionKey.isEmpty {
					BeamioNativeVoiceSignaling.rememberOffer(resolved)
				}
				NSLog(
					"[BeamioVoip] offer prefetch OK pushCallId=%@ offerCallId=%@ tag=%@ hasSessionKey=%@",
					callId,
					resolved.callId,
					resolved.beamioTag.isEmpty ? "-" : resolved.beamioTag,
					resolved.sessionKey.isEmpty ? "no" : "yes"
				)
				// Always update under PushKit registration keys — not offer.callId.
				if !resolved.beamioTag.isEmpty || !resolved.shortAddress.isEmpty {
					DispatchQueue.main.async {
						self?.callKit.updateVerifiedIdentity(
							callId: callId,
							sessionId: sessionId,
							tag: resolved.beamioTag,
							shortAddress: resolved.shortAddress
						)
					}
				}
			}
		}
	}

	/// After opaque CallKit: decrypt offerArmor → `reportCall(updated:)` with BeamioTag.
	/// Also caches sessionKey so Decline uplink can run without waiting for mailbox again.
	private func scheduleVerifiedIdentityUpdate(callId: String, sessionId: String) {
		guard !callId.isEmpty || sessionId.count >= 16 else { return }
		BeamioVoiceOfferIdentity.resolve(callId: callId, sessionId: sessionId) { [weak self] resolved in
			guard let self else { return }
			guard let resolved else {
				NSLog("[BeamioVoip] verified identity miss callId=%@", callId)
				self.callKit.noteIdentityResolveFinished(callId: callId, appliedTag: false)
				return
			}
			if !resolved.sessionKey.isEmpty {
				BeamioNativeVoiceSignaling.rememberOffer(resolved)
			}
			let hasLabel =
				BeamioIncomingCallPayload.normalizedBeamioTag(resolved.beamioTag) != nil
				|| !resolved.shortAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			NSLog(
				"[BeamioVoip] verified identity ready pushCallId=%@ offerCallId=%@ tag=%@ short=%@",
				callId,
				resolved.callId,
				resolved.beamioTag.isEmpty ? "-" : resolved.beamioTag,
				resolved.shortAddress.isEmpty ? "-" : resolved.shortAddress
			)
			// PushKit callId/sessionId are the CallIdentity map keys. Offer JSON
			// may carry a different callId — using that alone skips reportCall(updated:).
			DispatchQueue.main.async {
				self.callKit.updateVerifiedIdentity(
					callId: callId,
					sessionId: sessionId,
					tag: resolved.beamioTag,
					shortAddress: resolved.shortAddress
				)
				// updateVerifiedIdentity already notes when hasLabel; only finish
				// the bg-task path when resolve produced nothing usable.
				if !hasLabel {
					self.callKit.noteIdentityResolveFinished(callId: callId, appliedTag: false)
				}
			}
		}
	}
}
