//
//  BeamioDeepLink.swift
//  CashTrees_iOS
//
//  Universal Links (https://beamio.app/...) + custom scheme (beamio://open?...).
//

import Combine
import Foundation
import os
import UIKit

enum BeamioDeepLink {
    private static let acceptLog = Logger(subsystem: "com.beamio.beamio", category: "DeepLink")

    /// Public unified log. `NSLog` is redacted on device and cannot prove invite delivery.
    static func accept(_ message: String) {
        acceptLog.info("\(message, privacy: .public)")
    }

    /// Cold-start `UIOpenURLAction` can arrive before SwiftUI `.onOpenURL` is attached.
    private static var coldOpenURL: URL?

    /// v57: `beamio://busy-chrome-rescue` openURL can surface the system
    /// "paste from …" sheet if we also read UIPasteboard on becomeActive.
    /// Suppress pasteboard deferred-deep-link reads until this deadline.
    private static var pasteboardDeferredDeepLinkSuppressUntil: Date?

    /// Skip pasteboard deep-link consume for `seconds` (busy chrome-rescue).
    static func suppressPasteboardDeferredDeepLink(forSeconds seconds: TimeInterval) {
        let until = Date().addingTimeInterval(max(0.5, seconds))
        if let existing = pasteboardDeferredDeepLinkSuppressUntil, existing > until {
            return
        }
        pasteboardDeferredDeepLinkSuppressUntil = until
        accept("ACCEPT pasteboard-suppress \(Int(seconds))s")
    }

    static var isPasteboardDeferredDeepLinkSuppressed: Bool {
        guard let until = pasteboardDeferredDeepLinkSuppressUntil else { return false }
        if Date() >= until {
            pasteboardDeferredDeepLinkSuppressUntil = nil
            return false
        }
        return true
    }

    static func stashColdOpenURL(_ url: URL) {
        coldOpenURL = url
        accept("ACCEPT stashed-cold-open")
    }

    static func takeColdOpenURL() -> URL? {
        defer { coldOpenURL = nil }
        return coldOpenURL
    }

    static let customScheme = "beamio"
    static let customOpenHost = "open"
    /// Device QA: `beamio://debug-incoming?callId=…&peerAddress=0x…&claimedTag=@rrr12`
    /// Posts `.cashTreesIncomingVoiceCallPush` so ContentView reports system CallKit only.
    static let debugIncomingHost = "debug-incoming"
    /// Device QA: `beamio://debug-decline?callId=…` — unanswered CallKit End → `callRejected`.
    static let debugDeclineHost = "debug-decline"
    /// Device QA: `beamio://debug-answer?callId=…` — Answer ringing CallKit → verify in-call chrome.
    static let debugAnswerHost = "debug-answer"
    /// `beamio://incall` — the shell's own wake after a CallKit Answer: activate the
    /// app and show the native call screen (never loads a web page).
    static let inCallHost = "incall"
    /// Device QA: `beamio://debug-end-all` — tear down system CallKit zombies (dual-header chrome).
    static let debugEndAllHost = "debug-end-all"
    /// Device QA: `beamio://debug-remote-end?callId=…&sessionId=…` — stamp
    /// `remoteEnded` + tear CallKit (peer Hang Up race). Used with a same-callId
    /// `debug-incoming` within ~3s to verify soft-allow / soft-skip-stale crumbs.
    static let debugRemoteEndHost = "debug-remote-end"
    /// v26: self-wake after busy secondary while backgrounded — activate then
    /// soft-reassert sticky CallKit A (background `reportNewIncomingCall` fails).
    static let busyChromeRescueHost = "busy-chrome-rescue"

    /// `beamio://debug-*` QA links work only in Debug builds. Release ignores
    /// them, so no other app or web page can fake or end a call.
    static var debugLinksEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Default in-app WebView entry when custom scheme carries query-only params (remote semantics).
    static let defaultWebAppURL = URL(string: "https://beamio.app/app/")!

    /// Embedded SilentPassUI served by `WKURLSchemeHandler` on device (`cashtrees-local://localhost/`).
    static let localWebAppBaseURL = URL(string: "\(CashTreesPWAScheme.scheme)://\(CashTreesPWAScheme.host)/")!

    /// HTTPS hosts the WebView may load from deep links (allowlist).
    static let allowedWebHosts: Set<String> = [
        "beamio.app",
        "www.beamio.app",
        "verra.network",
        "www.verra.network",
    ]

    /// Universal Link path prefixes handled by this consumer shell.
    /// AASA on beamio.app also lists `/app-download` (unwrapped below). POS must not claim these paths.
    static let universalLinkPathPrefixes = ["/app"]

    /// Share / install landing: unwrap `?target=https://beamio.app/app/…` to the inner PWA URL.
    ///
    /// `/app-download` must never load inside the native WKWebView — it is the homepage SPA,
    /// not SilentPassUI `/app/`, and can strand the launch splash on a loading interstitial.
    ///
    /// Personal invite landings may put `invite=0x…` on the **outer** `/app-download` URL
    /// (desktop shows Invited by) without a nested `target=`. Preserve that EOA into `/app/?invite=`.
    static func unwrapAppDownloadLandingURL(_ url: URL) -> URL? {
        let path = url.path
        guard path == "/app-download" || path.hasPrefix("/app-download/") else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let outerInvite = agentInviteQueryValue(from: components.queryItems)

        if let targetRaw = components.queryItems?.first(where: { $0.name == "target" })?.value {
            let decoded = targetRaw.removingPercentEncoding ?? targetRaw
            guard let targetURL = URL(string: decoded),
                  let sanitized = sanitizeHTTPSWebURL(targetURL)
            else { return nil }
            let targetPath = sanitized.path
            guard targetPath == "/app" || targetPath == "/app/" || targetPath.hasPrefix("/app/") else {
                return nil
            }
            let merged = mergeAgentInviteIfNeeded(into: sanitized, outerInvite: outerInvite)
            NSLog("[BeamioDeepLink] unwrap app-download target → %@", merged.absoluteString)
            if merged.absoluteString.localizedCaseInsensitiveContains("invite="),
               !merged.path.localizedCaseInsensitiveContains("app-download") {
                accept("ACCEPT unwrap-target")
            }
            return merged
        }

        // Invite-only landing: `/app-download?invite=0x…` (no target) → `/app/?invite=0x…`
        guard let invite = outerInvite else { return nil }
        guard let inviteOnly = webAppURLWithInvite(invite) else { return nil }
        NSLog("[BeamioDeepLink] unwrap invite-only app-download → %@", inviteOnly.absoluteString)
        accept("ACCEPT unwrap-invite-only")
        return inviteOnly
    }

    /// Build `https://beamio.app/app/?invite=<eoa>` for invite-only landings.
    private static func webAppURLWithInvite(_ invite: String) -> URL? {
        var merged = URLComponents(url: defaultWebAppURL, resolvingAgainstBaseURL: false)
        merged?.queryItems = [URLQueryItem(name: "invite", value: invite)]
        guard let resolved = merged?.url else { return nil }
        return sanitizeHTTPSWebURL(resolved) ?? resolved
    }

    /// If outer landing carried `invite=` and the inner `/app/` URL does not, copy it in.
    private static func mergeAgentInviteIfNeeded(into url: URL, outerInvite: String?) -> URL {
        guard let outerInvite else { return url }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        if agentInviteQueryValue(from: components.queryItems) != nil {
            return url
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "invite", value: outerInvite))
        var next = components
        next.queryItems = items
        return next.url ?? url
    }

    /// `invite` / `Invite` query = EOA `0x` + 40 hex (personal referral).
    private static func agentInviteQueryValue(from items: [URLQueryItem]?) -> String? {
        guard let items else { return nil }
        for name in ["invite", "Invite"] {
            guard let raw = items.first(where: { $0.name == name })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty
            else { continue }
            if raw.range(of: #"^0x[0-9a-fA-F]{40}$"#, options: .regularExpression) != nil {
                return raw
            }
        }
        return nil
    }

    /// Resolve an incoming Universal Link or `beamio://` URL to an allowed HTTPS URL for the WebView.
    static func resolveWebAppURL(from incoming: URL) -> URL? {
        guard let scheme = incoming.scheme?.lowercased() else { return nil }
        switch scheme {
        case customScheme:
            return resolveCustomSchemeURL(incoming)
        case "https":
            return resolveUniversalLinkURL(incoming)
        default:
            return nil
        }
    }

    /// `application(_:open:)` + SwiftUI `.onOpenURL` both fire for the same
    /// `beamio://debug-incoming` — collapse duplicates within this window.
    private static var lastDebugIncomingCallId: String = ""
    private static var lastDebugIncomingAt: Date = .distantPast
    private static let debugIncomingDedupeWindow: TimeInterval = 1.5

    /// Handle `beamio://debug-incoming?…` for on-device Incoming UI acceptance (no real dial).
    @discardableResult
    static func handleDebugIncomingIfPresent(_ url: URL) -> Bool {
        guard debugLinksEnabled else { return false }
        guard url.scheme?.lowercased() == customScheme else { return false }
        let host = (url.host ?? "").lowercased()
        let pathHost: String = {
            let p = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return p.lowercased()
        }()
        guard host == debugIncomingHost || (host.isEmpty && pathHost == debugIncomingHost) else {
            return false
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String {
            items.first(where: { $0.name == name })?.value?
                .removingPercentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
        // Unique callId by default. Reusing `debug-incoming-stable` left a system
        // CallKit UUID with the old EOA/@tag dual header; reportNewIncomingCall then
        // failed (CallUUIDAlreadyExists) and debug-answer answered the zombie —
        // bottom Speaker/Mute/End piled in the corner.
        let callId = q("callId").isEmpty ? "debug-incoming-\(stamp)" : q("callId")
        let sessionId = q("sessionId").isEmpty ? "debug-sess-\(stamp)" : q("sessionId")
        let peerAddress = q("peerAddress").isEmpty
            ? "0x3ca84050541f4a2f570f717c9d52624161dfaa7f"
            : q("peerAddress")
        let claimedTag = q("claimedTag").isEmpty ? (q("tag").isEmpty ? "@rrr12" : q("tag")) : q("claimedTag")
        let claimedAddress = q("claimedAddress").isEmpty ? peerAddress : q("claimedAddress")
        let displayName = q("displayName").isEmpty ? claimedTag : q("displayName")
        let selfProbe = q("selfProbe").lowercased()
        let now = Date()
        if callId == lastDebugIncomingCallId,
           now.timeIntervalSince(lastDebugIncomingAt) < debugIncomingDedupeWindow {
            NSLog(
                "[BeamioDeepLink] debug-incoming DEDUPE callId=%@ age=%.2fs",
                callId,
                now.timeIntervalSince(lastDebugIncomingAt)
            )
            return true
        }
        lastDebugIncomingCallId = callId
        lastDebugIncomingAt = now
        NSLog(
            "[BeamioDeepLink] debug-incoming callId=%@ tag=%@ peer=%@",
            callId,
            claimedTag,
            peerAddress
        )
        let userInfo: [AnyHashable: Any] = [
            "callId": callId,
            "sessionId": sessionId,
            "peerAddress": peerAddress,
            "displayName": displayName,
            "claimedTag": claimedTag,
            "claimedAddress": claimedAddress,
        ]
        // System CallKit only (no glass overlay). Recreate provider only when
        // idle — so zombie dual-header chrome cannot steal Answer on a fresh
        // first ring. If already ringing/connected/sticky, skip recreate (would
        // kill the live call and defeat the single-call busy gate QA path).
        // Re-read sticky/busy *inside* deliver — entry snapshot can race dual openURL.
        let deliver = {
            let ck = BeamioVoipIncomingBootstrap.shared.callKit
            let stickyNow = ck.hasStickyPrimaryExcluding(
                callId: callId,
                sessionId: sessionId
            )
            let busyNow = ck.isStickyOrBusyExcluding(
                callId: callId,
                sessionId: sessionId
            )
            let liveNow = ck.hasLiveCallKitCall()
            let reportCallKit = {
                BeamioVoipIncomingBootstrap.shared.reportFromUserInfo(userInfo) { error in
                    if let error {
                        NSLog(
                            "[BeamioDeepLink] debug-incoming report error=%@",
                            error.localizedDescription
                        )
                    } else {
                        NSLog("[BeamioDeepLink] debug-incoming report OK callId=%@", callId)
                    }
                }
            }
            if busyNow || liveNow || stickyNow {
                // v17 busy/sticky: decline-only — NEVER reportCallKit / recreate.
                // openURL report was system-CXEnding sticky A → Home idle after-b.
                // sendDecline(busy) + emitToWeb(callRejected) for chat leave-behind.
                NSLog(
                    "[BeamioDeepLink] debug-incoming busy — decline-only callId=%@ busy=%@ live=%@ sticky=%@",
                    callId,
                    busyNow ? "yes" : "no",
                    liveNow ? "yes" : "no",
                    stickyNow ? "yes" : "no"
                )
                BeamioVoipIncomingBootstrap.shared.rejectSecondaryWhileBusy(
                    callId: callId,
                    sessionId: sessionId
                )
            } else {
                // v19: idle path reports directly. Do NOT recreateProvider here —
                // recreate is sticky-blocked / races soft-reassert and made CALL A
                // miss while CALL B landed as a fresh first ring (@rr02). Use
                // debug-end-all for teardown; first inbound just reportNewIncomingCall.
                reportCallKit()
                if selfProbe == "pwa" {
                    // In-process second call. Do not openURL call B — that
                    // activates the scene and SpringBoard drops Incoming.
                    ck.armDebugSelfProbePwa(primaryCallId: callId)
                }
                if !ck.isStickyOrBusyExcluding(callId: callId, sessionId: sessionId) {
                    NotificationCenter.default.post(
                        name: .cashTreesIncomingVoiceCallPush,
                        object: nil,
                        userInfo: userInfo
                    )
                }
                // Delayed re-post for PWA only for the sole first inbound.
                // Busy second inbound must not schedule these timers.
                let notifyWebIfIdle = {
                    let busy = BeamioVoipIncomingBootstrap.shared.callKit
                        .isStickyOrBusyExcluding(callId: callId, sessionId: sessionId)
                    guard !busy else {
                        NSLog(
                            "[BeamioDeepLink] debug-incoming delayed-notify SKIP busy callId=%@",
                            callId
                        )
                        return
                    }
                    NotificationCenter.default.post(
                        name: .cashTreesIncomingVoiceCallPush,
                        object: nil,
                        userInfo: userInfo
                    )
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: notifyWebIfIdle)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: notifyWebIfIdle)
            }
        }
        BeamioDebugIncomingPending.stash(userInfo)
        if Thread.isMainThread {
            deliver()
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
        return true
    }

    /// Handle `beamio://debug-decline?callId=…` — request CallKit End without Answer (Decline path).
    @discardableResult
    static func handleDebugDeclineIfPresent(_ url: URL) -> Bool {
        guard debugLinksEnabled else { return false }
        guard url.scheme?.lowercased() == customScheme else { return false }
        let host = (url.host ?? "").lowercased()
        let pathHost: String = {
            let p = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return p.lowercased()
        }()
        guard host == debugDeclineHost || (host.isEmpty && pathHost == debugDeclineHost) else {
            return false
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String {
            items.first(where: { $0.name == name })?.value?
                .removingPercentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        // Prefer explicit callId; otherwise end the last reported / ringing call.
        let callId = q("callId").isEmpty
            ? BeamioVoipIncomingBootstrap.shared.callKit.lastReportedCallId
            : q("callId")
        let sessionId = q("sessionId")
        NSLog("[BeamioDeepLink] debug-decline callId=%@ sessionId=%@", callId, sessionId)
        let run = {
            BeamioVoipIncomingBootstrap.shared.callKit.end(callId: callId, sessionId: sessionId)
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
        return true
    }

    /// Handle `beamio://debug-answer?callId=…` — Answer ringing CallKit for in-call layout QA.
    @discardableResult
    static func handleDebugAnswerIfPresent(_ url: URL) -> Bool {
        guard debugLinksEnabled else { return false }
        guard url.scheme?.lowercased() == customScheme else { return false }
        let host = (url.host ?? "").lowercased()
        let pathHost: String = {
            let p = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return p.lowercased()
        }()
        guard host == debugAnswerHost || (host.isEmpty && pathHost == debugAnswerHost) else {
            return false
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String {
            items.first(where: { $0.name == name })?.value?
                .removingPercentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        // Empty callId → answer lastReported / any ringing inbound (never a
        // stale deterministic UUID from a previous dual-handle report).
        let callId = q("callId").isEmpty
            ? BeamioVoipIncomingBootstrap.shared.callKit.lastReportedCallId
            : q("callId")
        let sessionId = q("sessionId")
        // stay=1|true|yes → Answer without private suspend (Accept-stay QA).
        let stayRaw = q("stay").lowercased()
        let stay = stayRaw == "1" || stayRaw == "true" || stayRaw == "yes"
        NSLog(
            "[BeamioDeepLink] debug-answer callId=%@ sessionId=%@ stay=%@",
            callId,
            sessionId,
            stay ? "1" : "0"
        )
        let run = {
            BeamioVoipIncomingBootstrap.shared.callKit.answer(
                callId: callId,
                sessionId: sessionId,
                stay: stay
            )
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
        return true
    }

    /// Handle `beamio://debug-incall?action=mute|speaker|minimize|show|end|facetime|video` —
    /// press the shell call screen controls on a device with no touch automation.
    /// `facetime` / `video` toggles **local** FaceTime uplink only (peer must press separately).
    @discardableResult
    static func handleDebugInCallIfPresent(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == customScheme else { return false }
        let host = (url.host ?? "").lowercased()
        // `incall` is the shell's own wake after Answer and must work in Release.
        let isDebugInCall = debugLinksEnabled && host == "debug-incall"
        guard isDebugInCall || host == inCallHost else { return false }
        let action = host == inCallHost
            ? "show"
            : (URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "action" })?.value?.lowercased() ?? "")
        NSLog("[BeamioDeepLink] debug-incall action=%@", action)
        DispatchQueue.main.async {
            let model = BeamioInCallScreenModel.shared
            switch action {
            case "mute": model.toggleMute()
            case "speaker": model.toggleSpeaker()
            case "minimize": model.minimize()
            case "show": model.ensureSurfaceVisible(source: "deepLink-incall")
            case "end": model.hangUp()
            case "facetime", "video", "video-on", "video-toggle":
                BeamioVoipIncomingBootstrap.shared.callKit.writeBusyQaBreadcrumb(
                    "faceTime deep-link live=\(model.live ? "1" : "0") callId=\(model.callId)"
                )
                model.toggleFaceTime()
            default: break
            }
        }
        return true
    }

    /// Handle `beamio://debug-end-all` — end every CallKit call still held by the system.
    @discardableResult
    static func handleDebugEndAllIfPresent(_ url: URL) -> Bool {
        guard debugLinksEnabled else { return false }
        guard url.scheme?.lowercased() == customScheme else { return false }
        let host = (url.host ?? "").lowercased()
        let pathHost: String = {
            let p = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return p.lowercased()
        }()
        guard host == debugEndAllHost || (host.isEmpty && pathHost == debugEndAllHost) else {
            return false
        }
        NSLog("[BeamioDeepLink] debug-end-all")
        let run = {
            BeamioVoipIncomingBootstrap.shared.callKit.endAllCallsForDebug()
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
        return true
    }

    /// Handle `beamio://debug-remote-end?callId=…&sessionId=…` — peer Hang Up race stamp.
    @discardableResult
    static func handleDebugRemoteEndIfPresent(_ url: URL) -> Bool {
        guard debugLinksEnabled else { return false }
        guard url.scheme?.lowercased() == customScheme else { return false }
        let host = (url.host ?? "").lowercased()
        let pathHost: String = {
            let p = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return p.lowercased()
        }()
        guard host == debugRemoteEndHost || (host.isEmpty && pathHost == debugRemoteEndHost) else {
            return false
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String {
            items.first(where: { $0.name == name })?.value?
                .removingPercentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let callKit = BeamioVoipIncomingBootstrap.shared.callKit
        let callId = q("callId").isEmpty ? callKit.lastReportedCallId : q("callId")
        let sessionId = q("sessionId")
        NSLog(
            "[BeamioDeepLink] debug-remote-end callId=%@ sessionId=%@",
            callId,
            sessionId
        )
        BeamioVoipIncomingBootstrap.shared.callKit.writeBusyQaBreadcrumb(
            "debug-remote-end:\(callId):sid=\(sessionId)"
        )
        let run = {
            BeamioNativeVoiceSignaling.applyRemoteMediaEnd(
                callId: callId,
                sessionId: sessionId
            )
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
        return true
    }

    /// Handle `beamio://busy-chrome-rescue` — activate host then restore sticky CallKit A.
    @discardableResult
    static func handleBusyChromeRescueIfPresent(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == customScheme else { return false }
        let host = (url.host ?? "").lowercased()
        let pathHost: String = {
            let p = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return p.lowercased()
        }()
        guard host == busyChromeRescueHost || (host.isEmpty && pathHost == busyChromeRescueHost) else {
            return false
        }
        NSLog("[BeamioDeepLink] busy-chrome-rescue")
        let run = {
            BeamioVoipIncomingBootstrap.shared.callKit.handleBusyChromeRescue()
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
        return true
    }

    // MARK: - Custom scheme

    /// `beamio://open?target=<urlencode(https://…)>` or `beamio://open?beamiocard=…&redeemcode=…`
    private static func resolveCustomSchemeURL(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        let host = (components.host ?? "").lowercased()
        let path = components.path
        let isOpenRoute =
            host == customOpenHost
            || host.isEmpty && (path.isEmpty || path == "/" || path == "/open")
        guard isOpenRoute else { return nil }

        if let targetRaw = components.queryItems?.first(where: { $0.name == "target" })?.value {
            let decoded = targetRaw.removingPercentEncoding ?? targetRaw
            guard let targetURL = URL(string: decoded) else { return nil }
            return resolveHTTPSWebTarget(targetURL)
        }

        let passthrough = (components.queryItems ?? []).filter { $0.name != "target" }
        guard !passthrough.isEmpty else { return defaultWebAppURL }

        var merged = URLComponents(url: defaultWebAppURL, resolvingAgainstBaseURL: false)
        merged?.queryItems = passthrough
        guard let resolved = merged?.url else { return defaultWebAppURL }
        return sanitizeHTTPSWebURL(resolved) ?? resolved
    }

    // MARK: - Universal Links

    private static func resolveUniversalLinkURL(_ url: URL) -> URL? {
        guard sanitizeHTTPSWebURL(url) != nil else { return nil }
        if let unwrapped = unwrapAppDownloadLandingURL(url) {
            return unwrapped
        }
        let path = url.path
        guard universalLinkPathPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            return nil
        }
        return url
    }

    private static func resolveHTTPSWebTarget(_ url: URL) -> URL? {
        guard let sanitized = sanitizeHTTPSWebURL(url) else { return nil }
        return unwrapAppDownloadLandingURL(sanitized) ?? sanitized
    }

    private static func sanitizeHTTPSWebURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        guard let host = url.host?.lowercased(), allowedWebHosts.contains(host) else { return nil }
        return url
    }

    /// Map an allowed remote PWA URL to the on-device embedded scheme path.
    /// `https://beamio.app/app/?x=1` → `cashtrees-local://localhost/?x=1` (bundle uses root `PUBLIC_URL=/`).
    static func mapResolvedWebAppURLToLocal(_ remote: URL, localBase: URL = localWebAppBaseURL) -> URL {
        guard let components = URLComponents(url: remote, resolvingAgainstBaseURL: false) else {
            return localBase
        }

        var path = components.path
        if path == "/app" {
            path = "/"
        } else if path.hasPrefix("/app/") {
            path = String(path.dropFirst(4))
            if path.isEmpty { path = "/" }
        }

        var local = URLComponents(url: localBase, resolvingAgainstBaseURL: false) ?? URLComponents()
        local.scheme = localBase.scheme
        local.host = localBase.host
        local.port = localBase.port
        local.path = path == "/" ? localBase.path : path
        local.queryItems = components.queryItems
        local.fragment = components.fragment
        return local.url ?? localBase
    }

    /// Pasteboard / Play-referrer style deferred install: merchant/coupon/redeem **or** personal `invite=`.
    static func resolveDeferredInstallDeepLink(from url: URL) -> URL? {
        guard let resolved = resolveWebAppURL(from: url) ?? resolveHTTPSWebTarget(url) else { return nil }
        guard urlCarriesDeferredInstallPayload(resolved) else { return nil }
        return resolved
    }

    /// True when the resolved `/app/` URL should survive post-install pasteboard restore.
    private static func urlCarriesDeferredInstallPayload(_ url: URL) -> Bool {
        if urlCarriesAgentInvite(url) { return true }
        return urlCarriesMerchantOrCouponPayload(url)
    }

    private static func urlCarriesAgentInvite(_ url: URL) -> Bool {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return false
        }
        return agentInviteQueryValue(from: items) != nil
    }

    private static func urlCarriesMerchantOrCouponPayload(_ url: URL) -> Bool {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return false
        }
        var map: [String: String] = [:]
        for item in items {
            guard let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                continue
            }
            let key = item.name.lowercased()
            if map[key] == nil {
                map[key] = value
            }
        }
        let card = map["beamiocard"] ?? ""
        guard !card.isEmpty else { return false }
        if map["redeemcode"] != nil { return true }
        let couponId = map["couponid"] ?? ""
        let claim = (map["claim"] ?? "").lowercased()
        if !couponId.isEmpty {
            return claim.isEmpty || claim == "open" || claim == "1" || claim == "true"
        }
        // Merchant link: `discover=open|1|true`, or a bare `beamiocard` with no `discover`.
        let discover = (map["discover"] ?? "").lowercased()
        return discover.isEmpty || discover == "open" || discover == "1" || discover == "true"
    }
}

/// Stash for ContentView to drain CallKit if notification was posted before observer attach.
enum BeamioDebugIncomingPending {
    private static let lock = NSLock()
    private static var stored: [AnyHashable: Any]?

    static func stash(_ userInfo: [AnyHashable: Any]) {
        lock.lock()
        stored = userInfo
        lock.unlock()
    }

    static func take() -> [AnyHashable: Any]? {
        lock.lock()
        defer { lock.unlock() }
        let value = stored
        stored = nil
        return value
    }
}

/// Queues deep-link targets until the WKWebView can load them.
///
/// `pendingWebURL` is **not** `@Published`: clearing it during `UIViewRepresentable`
/// updates caused "Publishing changes from within view updates" and blocked splash handoff.
final class CashTreesDeepLinkStore: ObservableObject {
    /// Increments when a new deep link arrives; `CashTreesWebView` observes this nonce only.
    @Published private(set) var deepLinkNonce = 0
    private var pendingWebURLStorage: URL?
    private var didAttemptPasteboardDeferredDeepLink = false

    func consumeColdOpenURLIfNeeded() {
        guard let url = BeamioDeepLink.takeColdOpenURL() else { return }
        handleIncomingURL(url)
    }

    func handleIncomingURL(_ url: URL) {
        if BeamioDeepLink.handleDebugIncomingIfPresent(url) { return }
        if BeamioDeepLink.handleDebugDeclineIfPresent(url) { return }
        if BeamioDeepLink.handleDebugAnswerIfPresent(url) { return }
        if BeamioDeepLink.handleDebugInCallIfPresent(url) { return }
        if BeamioDeepLink.handleDebugEndAllIfPresent(url) { return }
        if BeamioDeepLink.handleDebugRemoteEndIfPresent(url) { return }
        if BeamioDeepLink.handleBusyChromeRescueIfPresent(url) { return }
        guard let resolved = BeamioDeepLink.resolveWebAppURL(from: url) else {
            NSLog("[BeamioDeepLink] handleIncomingURL unresolved %@", url.absoluteString)
            return
        }
        let local = BeamioDeepLink.mapResolvedWebAppURLToLocal(resolved)
        NSLog(
            "[BeamioDeepLink] handleIncomingURL remote=%@ local=%@",
            resolved.absoluteString,
            local.absoluteString
        )
        if local.absoluteString.localizedCaseInsensitiveContains("invite="),
           !local.path.localizedCaseInsensitiveContains("app-download") {
            BeamioDeepLink.accept("ACCEPT incoming")
        }
        pendingWebURLStorage = local
        scheduleDeepLinkArrivalPublish()
    }

    /// After App Store install: landing copied `https://beamio.app/app/?beamiocard=…` or `…?invite=0x…` to the pasteboard.
    /// Consume once on cold start when no Universal Link / custom scheme arrived.
    func consumeDeferredDeepLinkFromPasteboardIfNeeded() {
        // v57: busy-chrome-rescue openURL must not trigger paste sheet.
        if BeamioDeepLink.isPasteboardDeferredDeepLinkSuppressed {
            BeamioDeepLink.accept("ACCEPT pasteboard-skip-suppressed")
            return
        }
        guard !didAttemptPasteboardDeferredDeepLink else { return }
        didAttemptPasteboardDeferredDeepLink = true
        guard pendingWebURLStorage == nil else { return }
        guard let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let candidate = URL(string: raw)
        else { return }
        guard let resolved = BeamioDeepLink.resolveDeferredInstallDeepLink(from: candidate) else { return }
        pendingWebURLStorage = BeamioDeepLink.mapResolvedWebAppURLToLocal(resolved)
        // Avoid re-opening the same merchant/coupon on every cold start.
        if UIPasteboard.general.string == raw {
            UIPasteboard.general.string = ""
        }
        scheduleDeepLinkArrivalPublish()
    }

    /// Read and clear the queued URL. Does not touch `@Published` state.
    func takePendingWebURL() -> URL? {
        defer { pendingWebURLStorage = nil }
        return pendingWebURLStorage
    }

    /// Never publish synchronously — `onOpenURL` / Universal Links can arrive mid view update.
    private func scheduleDeepLinkArrivalPublish() {
        DispatchQueue.main.async { [weak self] in
            self?.deepLinkNonce += 1
        }
    }
}
