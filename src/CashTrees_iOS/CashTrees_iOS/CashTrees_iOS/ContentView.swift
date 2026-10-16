//
//  ContentView.swift
//  CashTrees_iOS
//
//  Created by peter on 2026-03-27.
//

import Combine
import AVFoundation
import CoreImage
import CoreNFC
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

/// Consumer shell loads embedded SilentPassUI via `cashtrees-local://` scheme handler.
/// Remote `https://beamio.app/app/` deep links are mapped to the same path on localhost.
private func defaultLocalWebAppURL(from host: CashTreesLocalPWAHost) -> URL {
    host.entryURL
}

/// Launch / splash / empty WebView surface — avoids a pure-black flash when content process dies.
private let cashTreesWebSurfaceColor = UIColor(red: 0 / 255, green: 4 / 255, blue: 20 / 255, alpha: 1)
private let cashTreesWebSurfaceSwiftUIColor = Color(red: 0 / 255, green: 4 / 255, blue: 20 / 255)

/// 与注入脚本 `window.webkit.messageHandlers.CashTreesIOS` 一致
private let cashTreesIOSWKHandlerName = "CashTreesIOS"

/// 与 Android MainActivity.NfcStatusStrings 及 PWA 解析一致
private enum NfcStatusString {
    static let ready = "ready"
    static let noHardware = "no_hardware"
    static let disabled = "disabled"
    static let permissionDenied = "nfc_permission_denied"
}

/// SUN query（与 MainActivity.parseSunParamsFromNdefUrl 一致；模板 e/c/m 全 0 为 nil）
private struct SunParams {
    let uid: String
    let e: String
    let c: String
    let m: String
}

// MARK: - NFC + Web 负载

private func queryDict(from components: URLComponents) -> [String: String] {
    var out: [String: String] = [:]
    for item in components.queryItems ?? [] {
        if let v = item.value { out[item.name] = v }
    }
    return out
}

/// 与 Kotlin Uri.parse + getQueryParameter 对齐；优先 `URLComponents(string:)`，避免 `URL(string:)` 对部分非法字符过严。
private func parseSunParamsFromNdefUrl(_ urlString: String) -> SunParams? {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var comp = URLComponents(string: trimmed.replacingOccurrences(of: " ", with: "%20"))
    if comp?.queryItems == nil, let u = URL(string: trimmed) {
        comp = URLComponents(url: u, resolvingAgainstBaseURL: false)
    }
    guard let comp = comp else { return parseSunParamsFromQueryStringFallback(trimmed) }

    var q = queryDict(from: comp)
    if let fragment = comp.fragment, fragment.contains("=") {
        var fragComp = URLComponents()
        fragComp.query = fragment
        for (k, v) in queryDict(from: fragComp) where q[k] == nil {
            q[k] = v
        }
    }

    guard let uid = q["uid"]?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty,
          let e = q["e"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          let c = q["c"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          let m = q["m"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    else { return parseSunParamsFromQueryStringFallback(trimmed) }

    if e.count != 64 || c.count != 6 || m.count != 16 { return nil }
    let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    if e.unicodeScalars.contains(where: { !hex.contains($0) }) { return nil }
    if c.unicodeScalars.contains(where: { !hex.contains($0) }) { return nil }
    if m.unicodeScalars.contains(where: { !hex.contains($0) }) { return nil }
    let el = e.lowercased(), cl = c.lowercased(), ml = m.lowercased()
    if el.allSatisfy({ $0 == "0" }) && cl.allSatisfy({ $0 == "0" }) && ml.allSatisfy({ $0 == "0" }) {
        return nil
    }
    return SunParams(uid: uid, e: e, c: c, m: m)
}

/// `?` 后手动拆 query，容错未规范编码的 URL。
private func parseSunParamsFromQueryStringFallback(_ raw: String) -> SunParams? {
    guard let idx = raw.firstIndex(of: "?") else { return nil }
    let query = String(raw[raw.index(after: idx)...])
    var q: [String: String] = [:]
    for pair in query.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        let val = String(parts[1]).removingPercentEncoding ?? String(parts[1])
        q[key] = val
    }
    guard let uid = q["uid"]?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty,
          let e = q["e"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          let c = q["c"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          let m = q["m"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    else { return nil }
    if e.count != 64 || c.count != 6 || m.count != 16 { return nil }
    let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    if e.unicodeScalars.contains(where: { !hex.contains($0) }) { return nil }
    if c.unicodeScalars.contains(where: { !hex.contains($0) }) { return nil }
    if m.unicodeScalars.contains(where: { !hex.contains($0) }) { return nil }
    let el = e.lowercased(), cl = c.lowercased(), ml = m.lowercased()
    if el.allSatisfy({ $0 == "0" }) && cl.allSatisfy({ $0 == "0" }) && ml.allSatisfy({ $0 == "0" }) {
        return nil
    }
    return SunParams(uid: uid, e: e, c: c, m: m)
}

/// NDEF Well-known URI（type "U"）
private func urlString(fromUriNdefPayload payload: Data) -> String? {
    guard !payload.isEmpty else { return nil }
    let prefixes = [
        "", "http://www.", "https://www.", "http://", "https://", "tel:", "mailto:",
        "ftp://anonymous:anonymous@", "ftp://ftp.", "ftps://", "sftp://", "smb://",
        "nfs://", "ftp://", "dav://", "news:", "urn:nfc:", "sip:", "sips:",
    ]
    let code = Int(payload[payload.startIndex])
    let rest = payload.dropFirst()
    guard let suffix = String(data: Data(rest), encoding: .utf8) else { return nil }
    if code < prefixes.count {
        return prefixes[code] + suffix
    }
    return suffix
}

private func firstNdefUriString(from message: NFCNDEFMessage?) -> String? {
    guard let records = message?.records else { return nil }
    for record in records {
        if record.typeNameFormat == .nfcWellKnown {
            if record.type == Data([0x55]) || record.type == "U".data(using: .utf8) {
                if let u = urlString(fromUriNdefPayload: record.payload) { return u }
            }
            if record.type == Data([0x53, 0x70]) || record.type == "Sp".data(using: .utf8) {
                if let nested = NFCNDEFMessage(data: record.payload),
                   let inner = firstNdefUriString(from: nested) {
                    return inner
                }
            }
        }
    }
    return nil
}

private func queryIosNfcStatusString() -> String {
    if !NFCNDEFReaderSession.readingAvailable {
        return NfcStatusString.noHardware
    }
    return NfcStatusString.ready
}

/// 与 Android `MainActivity.shouldBlockBeamioNdefTopLevelNavigation` 一致：拦截 NDEF 写入的 SUN URL，避免 WebView 拾取后跳出。
private func shouldBlockBeamioNdefTopLevelNavigation(_ url: URL, isMainFrame: Bool) -> Bool {
    guard isMainFrame else { return false }
    guard let host = url.host?.lowercased(), host.contains("beamio.app") else { return false }
    if host.contains("cashtrees.beamio.app") { return false }
    let path = url.path.lowercased()
    if path.contains("/api/sun") || path.contains("/sun") { return true }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
    let names = Set((components.queryItems ?? []).map(\.name))
    return names.contains("uid") && names.contains("e") && names.contains("c") && names.contains("m")
}

private enum MicrophonePermissionHelper {
    static var isGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    static var isUndetermined: Bool {
        AVAudioApplication.shared.recordPermission == .undetermined
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission(completionHandler: completion)
    }
}

// MARK: - Web load state（首屏 PWA 加载）

final class CashTreesWebLoadState: ObservableObject {
    @Published var isSplashVisible = true
    @Published var shouldAnimateOut = false

    private var splashFallbackWorkItem: DispatchWorkItem?

    /// Safety net when WebView never reports ready (network / JS bridge failure).
    func scheduleSplashFallback(after seconds: TimeInterval = 10) {
        splashFallbackWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.beginSplashHandoff()
        }
        splashFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelSplashFallback() {
        splashFallbackWorkItem?.cancel()
        splashFallbackWorkItem = nil
    }

    func beginSplashHandoff() {
        guard isSplashVisible, !shouldAnimateOut else { return }
        cancelSplashFallback()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isSplashVisible, !self.shouldAnimateOut else { return }
            self.shouldAnimateOut = true
        }
    }

    func finishSplashHandoff() {
        cancelSplashFallback()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isSplashVisible = false
            self.shouldAnimateOut = false
        }
    }

    /// Cover a terminated WKWebView process while the replacement document renders.
    /// The OTA check must never be allowed to expose an empty WebView surface.
    func beginRecovery() {
        splashFallbackWorkItem?.cancel()
        splashFallbackWorkItem = nil
        isSplashVisible = true
        shouldAnimateOut = false
    }
}

// MARK: - WK Coordinator

final class CashTreesWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NFCTagReaderSessionDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
    weak var webView: WKWebView?
    weak var loadState: CashTreesWebLoadState?

    let webConsoleMessageHandler = CashTreesWebConsoleMessageHandler()

    private var nfcSession: NFCTagReaderSession?
    private var bindSessionActive = false
    private var initialWebRenderReadySignaled = false
    private var webContentProcessNeedsReload = false
    private var lastLoadedWebURLString: String?
    private var becameActiveObserver: NSObjectProtocol?
    private var didEnterBackgroundObserver: NSObjectProtocol?
    private var embeddedPwaUpdateObserver: NSObjectProtocol?
    private var pushTokenObserver: NSObjectProtocol?
    private var webPushFlushObserver: NSObjectProtocol?
    private var incomingVoiceCallObserver: NSObjectProtocol?
    private var appLifecycleObserver: NSObjectProtocol?
    private var pendingCameraCaptureRequestId = ""
    private var pendingPhotoPickerRequestId = ""
    private var pendingFilePickerCompletion: (([URL]?) -> Void)?
    private var activeFilePickerSecurityScopedURLs: [URL] = []
    /// Set when the app actually enters background (not Control Center / lock peek).
    private var backgroundedAt: Date?
    private var webContentLivenessProbeGeneration = 0
    private var webContentLivenessProbeInFlight = false
    /// PushKit / APNs may fire before WKWebView exists or before PWA attaches
    /// `cashtreesios` listener — queue `pushDeviceToken` until `webContentReady`.
    private var pendingPushTokenPayloads: [[String: Any]] = []
    private var webContentReadyForPush = false
    var lastHandledDeepLinkNonce = 0

    /// JS ping must complete within this window or the content process is treated as dead.
    private let webContentLivenessPingTimeout: TimeInterval = 1.5
    /// Skip ping on ordinary app-switch / lock (seconds).
    private let webContentLivenessMinBackground: TimeInterval = 3
    /// Overnight / long suspend: last compositor frame can look alive while hit-testing is dead.
    private let webContentLongBackgroundReload: TimeInterval = 2 * 60 * 60

    override init() {
        super.init()
        // PushKit + CallKit live in BeamioVoipIncomingBootstrap (AppDelegate).
        // Wire Answer/End into the WebView once the shell is up.
        BeamioVoipIncomingBootstrap.shared.setWebBridge { [weak self] action, callId, sessionId in
            self?.dispatchIOSBridgeJsonToWeb([
                "action": action,
                "callId": callId,
                "sessionId": sessionId,
            ])
        }
        becameActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppBecameActive()
        }
        didEnterBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.backgroundedAt = Date()
        }
        embeddedPwaUpdateObserver = NotificationCenter.default.addObserver(
            forName: .cashTreesEmbeddedPwaUpdateAvailable,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.dispatchEmbeddedPwaUpdateAvailable(from: note)
        }
        pushTokenObserver = NotificationCenter.default.addObserver(
            forName: .cashTreesPushDeviceTokenUpdated,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Empty hex = native cleared stale token — still forward so PWA drops dedupe.
            let hex = (note.userInfo?["deviceToken"] as? String) ?? ""
            let platform = (note.userInfo?["platform"] as? String) ?? "ios"
            self?.dispatchIOSBridgeJsonToWeb(
                CashTreesPushRegistration.payloadForWebEvent(deviceToken: hex, platform: platform)
            )
        }
        webPushFlushObserver = NotificationCenter.default.addObserver(
            forName: .cashTreesRequestWebPushFlush,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.requestWebPushRegisterFlush()
        }
        incomingVoiceCallObserver = NotificationCenter.default.addObserver(
            forName: .cashTreesIncomingVoiceCallPush,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleIncomingVoiceCallPush(from: note)
        }
        // Cold-start debug-incoming may post before this observer exists.
        if let pending = BeamioDebugIncomingPending.take() {
            let note = Notification(name: .cashTreesIncomingVoiceCallPush, object: nil, userInfo: pending)
            handleIncomingVoiceCallPush(from: note)
        }
        appLifecycleObserver = NotificationCenter.default.addObserver(
            forName: .cashTreesAppLifecycle,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let phase = (note.userInfo?["phase"] as? String) ?? ""
            guard phase == "background" || phase == "active" || phase == "inactive" else { return }
            self?.dispatchIOSBridgeJsonToWeb([
                "action": "appLifecycle",
                "phase": phase,
            ])
        }
    }

    private func handleAppBecameActive() {
        BeamioGuardianRoster.kick()
        // Drop stale offline push tray + badge; PWA re-publishes unread via publishAppState.
        CashTreesNativeAppStateBridge.clearOfflineChatAlerts()
        // Recovery is latency-sensitive. Never await the network-backed OTA check
        // before replacing a dead WKWebView content process.
        if webContentProcessNeedsReload {
            loadState?.beginRecovery()
            if let webView {
                performWebContentRecovery(on: webView, localBase: CashTreesLocalPWAHost.shared.baseURL)
            }
        } else {
            recoverWebContentIfNeeded()
            probeWebContentLivenessAndRecoverIfNeeded()
        }
        // Wallet unlock / EIP-191 may finish after first webContentReady flush —
        // re-push cached voip/alert so registerPushDevice can land for CallKit wake.
        if webContentReadyForPush {
            CashTreesPushRegistration.flushCachedTokensToWeb()
            requestWebPushRegisterFlush()
            injectNativePushSnapshotToWeb()
        }
        Task { @MainActor in
            await CashTreesLocalPWAHost.shared.refreshOnForeground()
        }
    }

    deinit {
        BeamioVoipIncomingBootstrap.shared.setWebBridge(nil)
        if let becameActiveObserver {
            NotificationCenter.default.removeObserver(becameActiveObserver)
        }
        if let didEnterBackgroundObserver {
            NotificationCenter.default.removeObserver(didEnterBackgroundObserver)
        }
        if let embeddedPwaUpdateObserver {
            NotificationCenter.default.removeObserver(embeddedPwaUpdateObserver)
        }
        if let pushTokenObserver {
            NotificationCenter.default.removeObserver(pushTokenObserver)
        }
        if let webPushFlushObserver {
            NotificationCenter.default.removeObserver(webPushFlushObserver)
        }
        if let incomingVoiceCallObserver {
            NotificationCenter.default.removeObserver(incomingVoiceCallObserver)
        }
        if let appLifecycleObserver {
            NotificationCenter.default.removeObserver(appLifecycleObserver)
        }
    }

    /// CallKit already reported by AppDelegate bootstrap (VoIP / alert). Forward identity to PWA only.
    private func handleIncomingVoiceCallPush(from note: Notification) {
        let callId = (note.userInfo?["callId"] as? String) ?? ""
        let sessionId = (note.userInfo?["sessionId"] as? String) ?? ""
        let peerAddress = (note.userInfo?["peerAddress"] as? String) ?? ""
        let displayName = (note.userInfo?["displayName"] as? String) ?? "Beamio call"
        let claimedTag = (note.userInfo?["claimedTag"] as? String) ?? ""
        let claimedAddress = (note.userInfo?["claimedAddress"] as? String) ?? ""
        guard !callId.isEmpty else { return }
        NSLog(
            "[CashTrees] incoming→PWA callId=%@ sessionId=%@ name=%@",
            callId,
            sessionId,
            displayName
        )
        dispatchIOSBridgeJsonToWeb([
            "action": "reportIncomingSystemCall",
            "callId": callId,
            "sessionId": sessionId,
            "peerAddress": peerAddress,
            "displayName": displayName,
            "claimedTag": claimedTag,
            "claimedAddress": claimedAddress,
        ])
    }

    func loadWebAppURL(_ url: URL, in webView: WKWebView, bypassDedup: Bool = false) {
        // Receive-from-wallet callback: prefer CustomEvent inject without full reload so
        // Home's waiting listener survives the return from Coinbase / wallet handoff.
        if let auth = Self.receiveUsdcAuthPayload(from: url), !auth.isEmpty {
            let alreadyLoaded = webView.url != nil && !webView.isLoading
            if alreadyLoaded {
                injectReceiveUsdcAuth(auth, into: webView)
                return
            }
            let key = url.absoluteString
            if !bypassDedup, lastLoadedWebURLString == key {
                injectReceiveUsdcAuth(auth, into: webView)
                return
            }
            lastLoadedWebURLString = key
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            webView.load(request)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.injectReceiveUsdcAuth(auth, into: webView)
            }
            return
        }
        if let txHash = Self.receiveUsdcTxPayload(from: url), !txHash.isEmpty {
            let alreadyLoaded = webView.url != nil && !webView.isLoading
            if alreadyLoaded {
                injectReceiveUsdcTx(txHash, into: webView)
                return
            }
            let key = url.absoluteString
            if !bypassDedup, lastLoadedWebURLString == key {
                injectReceiveUsdcTx(txHash, into: webView)
                return
            }
            lastLoadedWebURLString = key
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            webView.load(request)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.injectReceiveUsdcTx(txHash, into: webView)
            }
            return
        }
        let key = url.absoluteString
        if !bypassDedup, lastLoadedWebURLString == key { return }
        lastLoadedWebURLString = key
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        webView.load(request)
    }

    private static func receiveUsdcAuthPayload(from url: URL) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        return items.first(where: { $0.name == "receiveUsdcAuth" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func receiveUsdcTxPayload(from url: URL) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        return items.first(where: { $0.name == "receiveUsdcTx" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Dual channel for PWA `subscribeReceiveUsdcAuth`: CustomEvent + sessionStorage + URL query.
    private func injectReceiveUsdcAuth(_ payload: String, into webView: WKWebView) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: [trimmed], options: []),
              let arrayJson = String(data: data, encoding: .utf8),
              arrayJson.count >= 4
        else { return }
        // JSONSerialization wraps as ["…"] — peel the quoted string for a JS literal.
        let quoted = String(arrayJson.dropFirst().dropLast())
        let js = """
        (function(){
          try {
            var detail = \(quoted);
            try { sessionStorage.setItem('beamio:receiveUsdcAuth', detail); } catch (e) {}
            try {
              var u = new URL(window.location.href);
              u.searchParams.set('receiveUsdcAuth', detail);
              history.replaceState({}, '', u.pathname + u.search + u.hash);
            } catch (e) {}
            window.dispatchEvent(new CustomEvent('beamioReceiveUsdcAuth', { detail: detail }));
            try { window.dispatchEvent(new CustomEvent('beamio:deeplink')); } catch (e) {}
          } catch (e) {}
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
        CashTreesWebConsoleRelay.logNative("injected beamioReceiveUsdcAuth (\(trimmed.count) chars)")
    }

    /// Dual channel for PWA `subscribeReceiveUsdcTx` (Smart Wallet USDC.transfer).
    private func injectReceiveUsdcTx(_ payload: String, into webView: WKWebView) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: [trimmed], options: []),
              let arrayJson = String(data: data, encoding: .utf8),
              arrayJson.count >= 4
        else { return }
        let quoted = String(arrayJson.dropFirst().dropLast())
        let js = """
        (function(){
          try {
            var detail = \(quoted);
            try { sessionStorage.setItem('beamio:receiveUsdcTx', detail); } catch (e) {}
            try {
              var u = new URL(window.location.href);
              u.searchParams.set('receiveUsdcTx', detail);
              history.replaceState({}, '', u.pathname + u.search + u.hash);
            } catch (e) {}
            window.dispatchEvent(new CustomEvent('beamioReceiveUsdcTx', { detail: detail }));
            try { window.dispatchEvent(new CustomEvent('beamio:deeplink')); } catch (e) {}
          } catch (e) {}
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
        CashTreesWebConsoleRelay.logNative("injected beamioReceiveUsdcTx (\(trimmed.count) chars)")
    }

    /// Start the splash handoff only after the page reports that it has
    /// completed an actual render pass, so the splash fades into ready content
    /// instead of a white interstitial.
    private func beginInitialWebHandoffIfNeeded() {
        guard !initialWebRenderReadySignaled else { return }
        initialWebRenderReadySignaled = true
        DispatchQueue.main.async { [weak self] in
            self?.loadState?.beginSplashHandoff()
            // PWA listener is attached by init — flush any early PushKit/APNs tokens
            // and re-post cached voip so `ios_voip` reaches registerPushDevice.
            self?.markWebContentReadyForPushAndFlush()
        }
    }

    private func markWebContentReadyForPushAndFlush() {
        webContentReadyForPush = true
        flushPendingPushTokenPayloads()
        CashTreesPushRegistration.flushCachedTokensToWeb()
        injectNativePushSnapshotToWeb()
        requestWebPushRegisterFlush()
        // Wallet unlock often lags first paint — keep kicking register.
        for delay in [3.0, 8.0, 20.0, 45.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.webContentReadyForPush else { return }
                CashTreesPushRegistration.flushCachedTokensToWeb()
                self.injectNativePushSnapshotToWeb()
                self.requestWebPushRegisterFlush()
            }
        }
    }

    /// Kick PWA HTTP `registerPushDevice` after delayed VoIP/alert re-notify
    /// (wallet unlock may lag behind PushKit events past the first flush window).
    private func requestWebPushRegisterFlush() {
        guard let webView, webContentReadyForPush else { return }
        let js = """
        (function(){
          try {
            if (typeof window.__beamioFlushPushRegister === 'function') {
              window.__beamioFlushPushRegister();
            }
          } catch (e) {}
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Sync UserDefaults voip/alert hex into the PWA even if CustomEvent delivery fails.
    private func injectNativePushSnapshotToWeb() {
        guard let webView, webContentReadyForPush else { return }
        let voip = (CashTreesPushRegistration.lastVoipDeviceTokenHex ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let alert = (CashTreesPushRegistration.lastDeviceTokenHex ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !voip.isEmpty || !alert.isEmpty else { return }
        let voipEsc = voip.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let alertEsc = alert.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function(){
          try {
            window.__beamioNativePushSnapshot = { ios: '\(alertEsc)', ios_voip: '\(voipEsc)' };
            if (typeof window.__beamioIngestNativePushSnapshot === 'function') {
              window.__beamioIngestNativePushSnapshot();
            }
          } catch (e) {}
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func flushPendingPushTokenPayloads() {
        guard webContentReadyForPush, webView != nil else { return }
        let queued = pendingPushTokenPayloads
        pendingPushTokenPayloads.removeAll()
        for payload in queued {
            dispatchIOSBridgeJsonToWeb(payload)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if shouldBlockBeamioNdefTopLevelNavigation(url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false) {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame ?? false,
           let unwrapped = BeamioDeepLink.unwrapAppDownloadLandingURL(url) {
            decisionHandler(.cancel)
            loadWebAppURL(BeamioDeepLink.mapResolvedWebAppURLToLocal(unwrapped), in: webView, bypassDedup: true)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        CashTreesWebConsoleRelay.reinject(into: webView, reason: "didCommit")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        (webView as? CashTreesWKWebView)?.stripInnerContentInputAccessoryView()
        let activeVer = CashTreesLocalPWAHost.shared.activeVersion()
        let pendingVer = CashTreesLocalPWAHost.shared.pendingUpdateVersion() ?? "none"
        CashTreesWebConsoleRelay.logNative("PWA bundle active=\(activeVer) pending=\(pendingVer)")
        CashTreesWebConsoleRelay.reinject(into: webView, reason: "didFinish")
        webView.evaluateJavaScript(
            "(function(){ return { ver: window.__CT_EMBEDDED_PWA_VER__||'', pending: window.__CT_EMBEDDED_PWA_PENDING_VER__||'' }; })();"
        ) { result, _ in
            if let dict = result as? [String: Any] {
                let ver = dict["ver"] as? String ?? ""
                let pending = dict["pending"] as? String ?? ""
                CashTreesWebConsoleRelay.logNative("PWA JS globals ver=\(ver) pending=\(pending)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.beginInitialWebHandoffIfNeeded()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        beginInitialWebHandoffIfNeeded()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        beginInitialWebHandoffIfNeeded()
    }

    /// iOS often kills the WKWebView content process after long background; reload on terminate or next foreground.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        cancelWebContentLivenessProbe()
        webContentProcessNeedsReload = true
        initialWebRenderReadySignaled = false
        loadState?.beginRecovery()
        guard UIApplication.shared.applicationState == .active else { return }
        performWebContentRecovery(on: webView, localBase: CashTreesLocalPWAHost.shared.baseURL)
    }

    private func recoverWebContentIfNeeded() {
        guard webContentProcessNeedsReload, let webView else { return }
        performWebContentRecovery(on: webView, localBase: CashTreesLocalPWAHost.shared.baseURL)
    }

    /// Overnight jetsam often leaves the last compositor frame on screen without calling
    /// `webViewWebContentProcessDidTerminate`. A JS ping (or long-background policy) is the
    /// only reliable way to detect a frozen WebContent process.
    private func probeWebContentLivenessAndRecoverIfNeeded() {
        guard !webContentProcessNeedsReload, let webView else { return }
        guard loadState?.isSplashVisible != true else { return }
        guard let started = backgroundedAt else { return }
        backgroundedAt = nil
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed >= webContentLivenessMinBackground else { return }

        if elapsed >= webContentLongBackgroundReload {
            CashTreesWebConsoleRelay.logNative(
                "WKWebView long-background \(Int(elapsed))s — reloading last URL"
            )
            beginZombieWebContentRecovery(on: webView)
            return
        }

        guard !webContentLivenessProbeInFlight else { return }
        webContentLivenessProbeInFlight = true
        webContentLivenessProbeGeneration += 1
        let generation = webContentLivenessProbeGeneration
        var finished = false

        let finish: (Bool) -> Void = { [weak self] alive in
            guard let self, !finished else { return }
            finished = true
            self.webContentLivenessProbeInFlight = false
            guard generation == self.webContentLivenessProbeGeneration else { return }
            if alive {
                self.pokeWebViewInteraction(webView)
                return
            }
            CashTreesWebConsoleRelay.logNative("WKWebView JS ping failed — reloading zombie process")
            self.beginZombieWebContentRecovery(on: webView)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + webContentLivenessPingTimeout) {
            finish(false)
        }
        webView.evaluateJavaScript("1") { result, error in
            DispatchQueue.main.async {
                if error != nil {
                    finish(false)
                    return
                }
                if let number = result as? NSNumber, number.intValue == 1 {
                    finish(true)
                    return
                }
                finish(result != nil)
            }
        }
    }

    private func cancelWebContentLivenessProbe() {
        webContentLivenessProbeGeneration += 1
        webContentLivenessProbeInFlight = false
    }

    private func beginZombieWebContentRecovery(on webView: WKWebView) {
        cancelWebContentLivenessProbe()
        webContentProcessNeedsReload = true
        initialWebRenderReadySignaled = false
        loadState?.beginRecovery()
        performWebContentRecovery(on: webView, localBase: CashTreesLocalPWAHost.shared.baseURL)
    }

    private func pokeWebViewInteraction(_ webView: WKWebView) {
        webView.isUserInteractionEnabled = false
        webView.scrollView.isScrollEnabled = false
        webView.isUserInteractionEnabled = true
        webView.scrollView.isScrollEnabled = true
        webView.setNeedsLayout()
        webView.layoutIfNeeded()
    }

    private func performWebContentRecovery(on webView: WKWebView, localBase: URL) {
        webContentProcessNeedsReload = false
        initialWebRenderReadySignaled = false
        // Zombie WKWebView often no-ops `reload()`. Always issue a fresh load of the last URL.
        if let current = webView.url {
            loadWebAppURL(current, in: webView, bypassDedup: true)
            return
        }
        if let last = lastLoadedWebURLString, let url = URL(string: last) {
            loadWebAppURL(url, in: webView, bypassDedup: true)
            return
        }
        loadWebAppURL(localBase, in: webView, bypassDedup: true)
    }

    // MARK: WKUIDelegate — PWA getUserMedia 预授权（对齐 Android WebChromeClient.onPermissionRequest）

    @available(iOS 15.0, *)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        switch type {
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                decisionHandler(.grant)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        decisionHandler(granted ? .grant : .deny)
                    }
                }
            default:
                decisionHandler(.deny)
            }
        case .microphone:
            if MicrophonePermissionHelper.isGranted {
                decisionHandler(.grant)
            } else if MicrophonePermissionHelper.isUndetermined {
                MicrophonePermissionHelper.request { granted in
                    DispatchQueue.main.async {
                        decisionHandler(granted ? .grant : .deny)
                    }
                }
            } else {
                decisionHandler(.deny)
            }
        case .cameraAndMicrophone:
            let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
            let grantVideo = videoStatus == .authorized
            let grantMic = MicrophonePermissionHelper.isGranted
            if grantVideo && grantMic {
                decisionHandler(.grant)
                return
            }
            if videoStatus == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { videoGranted in
                    if MicrophonePermissionHelper.isUndetermined {
                        MicrophonePermissionHelper.request { micGranted in
                            DispatchQueue.main.async {
                                decisionHandler(videoGranted && micGranted ? .grant : .deny)
                            }
                        }
                    } else {
                        DispatchQueue.main.async {
                            decisionHandler(videoGranted && grantMic ? .grant : .deny)
                        }
                    }
                }
            } else if MicrophonePermissionHelper.isUndetermined {
                MicrophonePermissionHelper.request { micGranted in
                    DispatchQueue.main.async {
                        decisionHandler(grantVideo && micGranted ? .grant : .deny)
                    }
                }
            } else {
                decisionHandler(.deny)
            }
        @unknown default:
            decisionHandler(.deny)
        }
    }

    // WKWebView does not open <input type="file"> on its own. Without this
    // callback the PWA returns from the native shell with no FileList, which
    // makes Attach files appear to fail only inside iOS.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        for url in activeFilePickerSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeFilePickerSecurityScopedURLs.removeAll()
        pendingFilePickerCompletion?([])
        pendingFilePickerCompletion = completionHandler

        guard let presenter = topViewController() else {
            pendingFilePickerCompletion = nil
            completionHandler(nil)
            return
        }

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [UTType.item],
            asCopy: true
        )
        picker.allowsMultipleSelection = parameters.allowsMultipleSelection
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let completion = pendingFilePickerCompletion
        pendingFilePickerCompletion = nil
        // Cloud/File Provider URLs may require a security-scoped access
        // assertion even when the picker was opened with `asCopy: true`.
        // Keep the assertion alive while WKWebView consumes the URLs.
        activeFilePickerSecurityScopedURLs = urls.filter {
            $0.startAccessingSecurityScopedResource()
        }
        DispatchQueue.main.async {
            completion?(urls)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let completion = pendingFilePickerCompletion
        pendingFilePickerCompletion = nil
        for url in activeFilePickerSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeFilePickerSecurityScopedURLs.removeAll()
        completion?(nil)
    }

    /// document start 注入用：与 Android `CashTreesAndroid.getNfcStatus()` 字符串一致
    static func bridgeInjectionScript(
        nfcStatus: String,
        embeddedVer: String,
        pendingVer: String
    ) -> String {
        func esc(_ raw: String) -> String {
            raw
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
        }
        let nfcEsc = esc(nfcStatus)
        let verEsc = esc(embeddedVer)
        let pendingEsc = esc(pendingVer)
        return """
        window.__CT_IOS_NFC_STATUS__='\(nfcEsc)';
        window.__CT_EMBEDDED_PWA_VER__='\(verEsc)';
        window.__CT_EMBEDDED_PWA_PENDING_VER__='\(pendingEsc)';
        (function(){
          var H='\(cashTreesIOSWKHandlerName)';
          function install(){
            if(!window.webkit||!window.webkit.messageHandlers||!window.webkit.messageHandlers[H])return false;
            if(window.CashTreesIOS&&typeof window.CashTreesIOS.bindPushIdentity==='function')return true;
            window.CashTreesIOS={
            getNfcStatus:function(){return window.__CT_IOS_NFC_STATUS__||'no_bridge';},
            getEmbeddedPwaVersion:function(){return window.__CT_EMBEDDED_PWA_VER__||'';},
            getEmbeddedPwaPendingVersion:function(){return window.__CT_EMBEDDED_PWA_PENDING_VER__||'';},
            applyEmbeddedPwaUpdate:function(){
              window.webkit.messageHandlers[H].postMessage({action:'applyEmbeddedPwaUpdate'});
            },
            startPhysicalCardBind:function(){
              window.webkit.messageHandlers[H].postMessage({action:'startPhysicalCardBind'});
            },
            cancelPhysicalCardBind:function(){
              window.webkit.messageHandlers[H].postMessage({action:'cancelPhysicalCardBind'});
            },
            saveRecoveryQrToPhotos:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'saveRecoveryQrToPhotos',
                dataUrl:payload.dataUrl||'',
                filename:payload.filename||'',
                requestId:payload.requestId||''
              });
            },
            saveFile:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'saveFile',
                dataUrl:payload.dataUrl||'',
                filename:payload.filename||'',
                mimeType:payload.mimeType||'application/octet-stream',
                requestId:payload.requestId||''
              });
            },
            scanRecoveryQr:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'scanRecoveryQr',
                requestId:payload.requestId||''
              });
            },
            scanQr:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'scanQr',
                requestId:payload.requestId||''
              });
            },
            requestCameraCapture:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'requestCameraCapture',
                requestId:payload.requestId||'',
                mediaType:payload.mediaType||'video'
              });
            },
            requestPhotoPicker:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'requestPhotoPicker',
                requestId:payload.requestId||''
              });
            },
            startSystemCall:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'startSystemCall',
                callId:payload.callId||'',
                sessionId:payload.sessionId||'',
                peerAddress:payload.peerAddress||'',
                displayName:payload.displayName||''
              });
            },
            reportIncomingSystemCall:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'reportIncomingSystemCall',
                callId:payload.callId||'',
                sessionId:payload.sessionId||'',
                peerAddress:payload.peerAddress||'',
                displayName:payload.displayName||'',
                claimedTag:payload.claimedTag||'',
                claimedAddress:payload.claimedAddress||'',
                identityWarning:payload.identityWarning||''
              });
            },
            endSystemCall:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'endSystemCall',
                callId:payload.callId||'',
                sessionId:payload.sessionId||''
              });
            },
            openURL:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'openURL',
                url:payload.url||''
              });
            },
            openInAppBrowser:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'openInAppBrowser',
                url:payload.url||'',
                requestId:payload.requestId||''
              });
            },
            queryInstalledApps:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'queryInstalledApps',
                requestId:payload.requestId||'',
                queries:payload.queries||[]
              });
            },
            listInstalledWalletApps:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'listInstalledWalletApps',
                requestId:payload.requestId||'',
                queries:payload.queries||[]
              });
            },
            publishAppState:function(state){
              window.webkit.messageHandlers[H].postMessage({
                action:'publishAppState',
                state:state||{}
              });
            },
            clearOfflineChatAlerts:function(){
              window.webkit.messageHandlers[H].postMessage({
                action:'clearOfflineChatAlerts'
              });
            },
            notifyBackgroundChat:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'notifyBackgroundChat',
                badge:payload.badge,
                appIconBadge:payload.appIconBadge,
                title:payload.title||'',
                body:payload.body||''
              });
            },
            bindPushIdentity:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'bindPushIdentity',
                eoa:payload.eoa||'',
                pgpKeyId:payload.pgpKeyId||''
              });
            },
            setNativeChatPgpSecrets:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'setNativeChatPgpSecrets',
                privateKeyArmor:payload.privateKeyArmor||'',
                publicKeyArmor:payload.publicKeyArmor||'',
                pgpKeyId:payload.pgpKeyId||'',
                routePublicKeyArmor:payload.routePublicKeyArmor||'',
                entryDomains:Array.isArray(payload.entryDomains)?payload.entryDomains:[],
                siNodes:Array.isArray(payload.siNodes)?payload.siNodes:[],
                mailboxIp:payload.mailboxIp||'',
                eoa:payload.eoa||''
              });
            },
            setNativeSiNodeRoster:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'setNativeSiNodeRoster',
                siNodes:Array.isArray(payload.siNodes)?payload.siNodes:[],
                mailboxIp:payload.mailboxIp||''
              });
            },
            postPgpCiphertext:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'postPgpCiphertext',
                requestId:payload.requestId||'',
                data:payload.data||'',
                excludeIps:Array.isArray(payload.excludeIps)?payload.excludeIps:[]
              });
            },
            registerPushDeviceHttp:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'registerPushDeviceHttp',
                requestId:payload.requestId||'',
                url:payload.url||'',
                body:payload.body||''
              });
            },
            debugLog:function(level,message){
              window.webkit.messageHandlers[H].postMessage({
                action:'consoleLog',
                level:level||'log',
                message:String(message||'')
              });
            }
          };
            return true;
          }
          if(install())return;
          var n=0;
          var t=setInterval(function(){
            if(install()||++n>=200)clearInterval(t);
          },25);
        })();
        """
    }

    /// Report "render ready" only after `load` plus two animation frames, so
    /// SwiftUI fades the splash into already-painted WebView pixels.
    static func renderReadyInjectionScript() -> String {
        """
        (function(){
          var sent = false;
          function notifyReady() {
            if (sent) return;
            sent = true;
            try {
              window.webkit.messageHandlers.\(cashTreesIOSWKHandlerName).postMessage({action:'webContentReady'});
            } catch (_) {}
          }
          function afterPaint() {
            requestAnimationFrame(function() {
              requestAnimationFrame(function() {
                notifyReady();
              });
            });
          }
          if (document.readyState === 'complete') {
            afterPaint();
            return;
          }
          window.addEventListener('load', function() {
            afterPaint();
          }, { once: true });
          setTimeout(function() {
            afterPaint();
          }, 1800);
        })();
        """
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == CashTreesWebConsoleRelay.handlerName {
            CashTreesWebConsoleRelay.handle(message)
            return
        }
        guard message.name == cashTreesIOSWKHandlerName,
              let body = message.body as? [String: Any],
              let action = body["action"] as? String
        else { return }
        switch action {
        case "consoleLog":
            CashTreesWebConsoleRelay.handleBridgeConsoleLog(body)
        case "startPhysicalCardBind":
            DispatchQueue.main.async { [weak self] in self?.armNfcPhysicalCardRead() }
        case "cancelPhysicalCardBind":
            DispatchQueue.main.async { [weak self] in self?.disarmNfcReader(notifyWeb: true, error: "cancelled") }
        case "saveRecoveryQrToPhotos":
            let dataUrl = body["dataUrl"] as? String
            let filename = body["filename"] as? String
            let requestId = body["requestId"] as? String
            saveRecoveryQrToPhotos(dataUrl: dataUrl, filename: filename, requestId: requestId)
        case "saveFile":
            let dataUrl = body["dataUrl"] as? String
            let filename = body["filename"] as? String
            let mimeType = body["mimeType"] as? String
            let requestId = body["requestId"] as? String
            saveFile(dataUrl: dataUrl, filename: filename, mimeType: mimeType, requestId: requestId)
        case "scanRecoveryQr":
            let requestId = body["requestId"] as? String
            DispatchQueue.main.async { [weak self] in
                self?.presentGeneralQRScanner(requestId: requestId, filter: .recoveryCodeOnly, bridgeAction: "scanRecoveryQr")
            }
        case "scanQr":
            let requestId = body["requestId"] as? String
            DispatchQueue.main.async { [weak self] in
                self?.presentGeneralQRScanner(requestId: requestId, filter: .anyText, bridgeAction: "scanQr")
            }
        case "requestCameraCapture":
            let requestId = body["requestId"] as? String ?? ""
            DispatchQueue.main.async { [weak self] in
                self?.presentCameraCapture(requestId: requestId)
            }
        case "requestPhotoPicker":
            let requestId = body["requestId"] as? String ?? ""
            DispatchQueue.main.async { [weak self] in
                self?.presentPhotoPicker(requestId: requestId)
            }
        case "startSystemCall":
            let callId = body["callId"] as? String ?? ""
            let sessionId = body["sessionId"] as? String ?? ""
            // B35: never pass peer/tag into CallKit — dual EOA/@tag collapses
            // the system in-call bottom bar. Opaque "Beamio" only.
            DispatchQueue.main.async {
                BeamioVoipIncomingBootstrap.shared.callKit.startOutgoing(
                    callId: callId,
                    handle: "Beamio",
                    sessionId: sessionId
                )
            }
        case "reportIncomingSystemCall":
            let callId = body["callId"] as? String ?? ""
            let sessionId = body["sessionId"] as? String ?? ""
            let peerAddress = body["peerAddress"] as? String ?? ""
            let displayName = body["displayName"] as? String
                ?? (peerAddress.isEmpty ? "Beamio call" : peerAddress)
            let claimedTag = body["claimedTag"] as? String ?? ""
            let claimedAddress = body["claimedAddress"] as? String ?? ""
            let identityWarning = body["identityWarning"] as? String ?? ""
            DispatchQueue.main.async {
                BeamioVoipIncomingBootstrap.shared.reportIncomingCallKit(
                    callId: callId,
                    sessionId: sessionId,
                    peerAddress: peerAddress,
                    displayName: displayName,
                    claimedTag: claimedTag,
                    claimedAddress: claimedAddress,
                    identityWarning: identityWarning
                )
            }
        case "endSystemCall":
            let callId = body["callId"] as? String ?? ""
            let sessionId = body["sessionId"] as? String ?? ""
            DispatchQueue.main.async {
                BeamioVoipIncomingBootstrap.shared.callKit.end(callId: callId, sessionId: sessionId)
            }
        case "webContentReady":
            DispatchQueue.main.async { [weak self] in self?.beginInitialWebHandoffIfNeeded() }
        case "openURL":
            let url = body["url"] as? String
            DispatchQueue.main.async { [weak self] in self?.openExternalURLFromBridge(url) }
        case "openInAppBrowser":
            let inAppUrl = body["url"] as? String
            let inAppRequestId = body["requestId"] as? String
            DispatchQueue.main.async { [weak self] in
                self?.presentInAppBrowserFromBridge(inAppUrl, requestId: inAppRequestId)
            }
        case "queryInstalledApps", "listInstalledWalletApps":
            let walletListRequestId = body["requestId"] as? String
            let queries = body["queries"]
            DispatchQueue.main.async { [weak self] in
                self?.queryInstalledAppsFromBridge(
                    action: action,
                    requestId: walletListRequestId,
                    queriesRaw: queries
                )
            }
        case "applyEmbeddedPwaUpdate":
            Task { @MainActor [weak self] in
                guard let self, let webView = self.webView else { return }
                let host = CashTreesLocalPWAHost.shared
                let ok = await host.applyPendingUpdate()
                var payload: [String: Any] = [
                    "action": "applyEmbeddedPwaUpdate",
                    "ok": ok,
                    "ver": host.activeVersion(),
                ]
                if !ok, let err = host.lastError {
                    payload["error"] = err
                }
                self.dispatchIOSBridgeJsonToWeb(payload)
                if ok {
                    self.syncEmbeddedPwaVersionGlobals(in: webView)
                    webView.reload()
                }
            }
        case "publishAppState":
            let state = body["state"] as? [String: Any]
            DispatchQueue.main.async {
                CashTreesNativeAppStateBridge.applyFromWebPayload(state)
            }
        case "clearOfflineChatAlerts":
            // PWA entered Chat: tray only; unread badge restored by next publishAppState.
            DispatchQueue.main.async {
                CashTreesNativeAppStateBridge.clearOfflineChatAlerts(resetBadge: false)
            }
        case "notifyBackgroundChat":
            DispatchQueue.main.async {
                CashTreesNativeAppStateBridge.notifyBackgroundChat(from: body)
            }
        case "setNativeChatPgpSecrets":
            DispatchQueue.main.async {
                let ok = BeamioChatPgpKeychain.upsert(fromWeb: body)
                NSLog("[CashTreesIOS] setNativeChatPgpSecrets ok=%@", ok ? "true" : "false")
            }
        case "setNativeSiNodeRoster":
            DispatchQueue.main.async {
                let ok = BeamioChatPgpKeychain.upsertRoster(fromWeb: body)
                NSLog("[CashTreesIOS] setNativeSiNodeRoster ok=%@", ok ? "true" : "false")
            }
        case "postPgpCiphertext":
            let requestId = (body["requestId"] as? String) ?? ""
            let armor = (body["data"] as? String) ?? ""
            let excludeRaw = body["excludeIps"] as? [Any] ?? []
            let exclude = Set(excludeRaw.compactMap { $0 as? String })
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var blocked = exclude
                let mailbox = BeamioChatPgpKeychain.loadMailboxIp()
                if !mailbox.isEmpty { blocked.insert(mailbox) }
                let result = BeamioSiCipherPost.post(
                    armor: armor,
                    nodes: BeamioChatPgpKeychain.loadSiNodes(),
                    excludeIps: blocked
                )
                DispatchQueue.main.async {
                    self?.dispatchIOSBridgeJsonToWeb([
                        "action": "postPgpCiphertext",
                        "requestId": requestId,
                        "ok": result.ok,
                        "status": result.status,
                        "body": result.body,
                        "error": result.error,
                    ])
                }
            }
        case "bindPushIdentity":
            let eoa = body["eoa"] as? String
            let pgpKeyId = body["pgpKeyId"] as? String
            let bindRequestId = (body["requestId"] as? String) ?? ""
            DispatchQueue.main.async { [weak self] in
                // PWA already attached `cashtreesios` before calling bind — treat
                // as ready so queued/cached voip reaches registerPushDevice.
                self?.webContentReadyForPush = true
                CashTreesPushRegistration.bindIdentity(eoa: eoa, pgpKeyId: pgpKeyId)
                self?.flushPendingPushTokenPayloads()
                self?.injectNativePushSnapshotToWeb()
                self?.requestWebPushRegisterFlush()
                // Sync reply with current hex so PWA can HTTP-register immediately
                // (CustomEvent alone was missed when listener/bind raced).
                var reply: [String: Any] = [
                    "action": "bindPushIdentity",
                    "ok": true,
                ]
                if !bindRequestId.isEmpty { reply["requestId"] = bindRequestId }
                if let voip = CashTreesPushRegistration.lastVoipDeviceTokenHex,
                   !voip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    reply["ios_voip"] = voip.lowercased()
                }
                if let alert = CashTreesPushRegistration.lastDeviceTokenHex,
                   !alert.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    reply["ios"] = alert.lowercased()
                }
                self?.dispatchIOSBridgeJsonToWeb(reply)
                for delay in [1.5, 4.0, 10.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, self.webContentReadyForPush else { return }
                        CashTreesPushRegistration.flushCachedTokensToWeb()
                        self.injectNativePushSnapshotToWeb()
                        self.requestWebPushRegisterFlush()
                    }
                }
            }
        case "registerPushDeviceHttp":
            // PWA-signed body → native URLSession (WKWebView custom-scheme fetch
            // to beamio.app often fails; CallKit wake needs DB write).
            let pushRegRequestId = (body["requestId"] as? String) ?? ""
            let pushRegUrl = (body["url"] as? String) ?? ""
            let pushRegBody = (body["body"] as? String) ?? ""
            DispatchQueue.main.async { [weak self] in
                self?.postRegisterPushDeviceHttp(
                    urlString: pushRegUrl,
                    bodyJson: pushRegBody,
                    requestId: pushRegRequestId
                )
            }
        default:
            break
        }
    }

    /// POST already-signed `registerPushDevice` JSON via URLSession.
    private func postRegisterPushDeviceHttp(urlString: String, bodyJson: String, requestId: String) {
        let rid = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
        func reply(ok: Bool, status: Int = 0, error: String? = nil) {
            var payload: [String: Any] = [
                "action": "registerPushDeviceHttp",
                "requestId": rid,
                "ok": ok,
            ]
            if status > 0 { payload["status"] = status }
            if let error, !error.isEmpty { payload["error"] = error }
            dispatchIOSBridgeJsonToWeb(payload)
        }
        guard let url = URL(string: urlString),
              url.scheme == "https",
              let host = url.host,
              (host == "beamio.app" || host.hasSuffix(".beamio.app")),
              let data = bodyJson.data(using: .utf8),
              !data.isEmpty
        else {
            reply(ok: false, error: "invalid_url_or_body")
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 14)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error {
                    reply(ok: false, error: error.localizedDescription)
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                var success = false
                if status >= 200, status < 300, let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    success = json["success"] as? Bool == true
                }
                CashTreesWebConsoleRelay.logNative(
                    "registerPushDeviceHttp status=\(status) ok=\(success) rid=\(rid.prefix(12))"
                )
                reply(ok: success, status: status)
                _ = self
            }
        }.resume()
    }

    private func dispatchEmbeddedPwaUpdateAvailable(from note: Notification) {
        guard let userInfo = note.userInfo,
              let currentVer = userInfo["currentVer"] as? String,
              let pendingVer = userInfo["pendingVer"] as? String
        else { return }
        dispatchIOSBridgeJsonToWeb([
            "action": "embeddedPwaUpdateAvailable",
            "currentVer": currentVer,
            "pendingVer": pendingVer,
        ])
        if let webView {
            syncEmbeddedPwaVersionGlobals(in: webView, pendingVer: pendingVer)
        }
    }

    private func syncEmbeddedPwaVersionGlobals(in webView: WKWebView, pendingVer: String? = nil) {
        let host = CashTreesLocalPWAHost.shared
        let active = host.activeVersion()
        let pending = pendingVer ?? host.pendingUpdateVersion() ?? ""
        let js = """
        window.__CT_EMBEDDED_PWA_VER__='\(active.replacingOccurrences(of: "'", with: "\\'"))';
        window.__CT_EMBEDDED_PWA_PENDING_VER__='\(pending.replacingOccurrences(of: "'", with: "\\'"))';
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// PWA `CashTreesIOS.openURL({ url })` — http(s)/mailto/tel, plus catalog wallet schemes.
    /// Native opens the PWA URL as-is; do not invent package or scheme URLs.
    private static let allowedExternalURLSchemes: Set<String> = [
        "http", "https", "mailto", "tel",
        // EIP-681 (`ethereum:0x…@8453/transfer?…`) for Coinbase Wallet / system wallet handoff.
        "ethereum",
        "metamask", "cbwallet", "coinbase", "base",
        "okx", "okex", "tpdapp", "tpoutside", "phantom", "trust",
    ]

    private func openExternalURLFromBridge(_ raw: String?) {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return }
        guard Self.allowedExternalURLSchemes.contains(scheme) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    /// Full-screen in-app WebView (bottom → top via `coverVertical`). Top Back closes; title = domain.
    /// On dismiss, PWA receives `cashtreesios` `{ action: "inAppBrowserClosed", requestId, url }`.
    private func presentInAppBrowserFromBridge(_ raw: String?, requestId: String?) {
        guard let url = CashTreesInAppBrowserController.sanitizedHTTPURL(from: raw) else { return }
        guard let presenter = topViewController() else { return }
        if presenter is CashTreesInAppBrowserController { return }
        if presenter.presentedViewController is CashTreesInAppBrowserController { return }
        let rid = (requestId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let browser = CashTreesInAppBrowserController(url: url)
        browser.onClosed = { [weak self] in
            self?.dispatchIOSBridgeJsonToWeb([
                "action": "inAppBrowserClosed",
                "ok": true,
                "requestId": rid,
                "url": url.absoluteString,
                "reason": "dismissed",
            ])
        }
        presenter.present(browser, animated: true)
    }

    /// PWA `queryInstalledApps({ requestId, queries })`. Empty / unparseable queries → MetaMask / Coinbase Wallet.
    private func queryInstalledAppsFromBridge(action: String, requestId: String?, queriesRaw: Any?) {
        let queries = parseInstalledAppQueries(queriesRaw)
        let ids: [String]
        if queries.isEmpty {
            ids = legacyInstalledWalletIds()
        } else {
            ids = queries.compactMap { query in
                let installed = query.schemes.contains { scheme in
                    guard let url = URL(string: "\(scheme)://") else { return false }
                    return UIApplication.shared.canOpenURL(url)
                }
                return installed ? query.id : nil
            }
        }
        var payload: [String: Any] = [
            "action": action,
            "ok": true,
            "ids": ids,
        ]
        let rid = requestId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rid.isEmpty {
            payload["requestId"] = rid
        }
        dispatchIOSBridgeJsonToWeb(payload)
    }

    private struct NativeInstalledAppQuery {
        let id: String
        let schemes: [String]
    }

    private func parseInstalledAppQueries(_ raw: Any?) -> [NativeInstalledAppQuery] {
        guard let list = raw as? [Any] else { return [] }
        var out: [NativeInstalledAppQuery] = []
        for item in list {
            guard let dict = item as? [String: Any] else { continue }
            let id = (dict["id"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !id.isEmpty else { continue }
            let schemes = stringList(from: dict["schemes"])
                .map { normalizeQueryScheme($0) }
                .filter { !$0.isEmpty }
            out.append(NativeInstalledAppQuery(id: id, schemes: schemes))
        }
        return out
    }

    private func stringList(from raw: Any?) -> [String] {
        if let arr = raw as? [String] { return arr }
        if let arr = raw as? [Any] { return arr.compactMap { $0 as? String } }
        return []
    }

    private func normalizeQueryScheme(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasSuffix("://") {
            s = String(s.dropLast(3))
        } else if s.hasSuffix(":") {
            s = String(s.dropLast())
        }
        return s
    }

    private func legacyInstalledWalletIds() -> [String] {
        var ids: [String] = []
        if let metamask = URL(string: "metamask://"), UIApplication.shared.canOpenURL(metamask) {
            ids.append("metamask")
        }
        let coinbaseInstalled =
            (URL(string: "cbwallet://").map { UIApplication.shared.canOpenURL($0) } ?? false)
            || (URL(string: "coinbase://").map { UIApplication.shared.canOpenURL($0) } ?? false)
        if coinbaseInstalled {
            ids.append("base")
        }
        return ids
    }

    private func presentGeneralQRScanner(requestId: String?, filter: GeneralQRScanFilter, bridgeAction: String) {
        let rid = requestId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let presenter = topViewController() else {
            dispatchQRBridgeResult(
                bridgeAction: bridgeAction,
                ok: false,
                text: nil,
                recoveryCode: nil,
                error: "no_presenter",
                requestId: rid
            )
            return
        }
        let scanner = GeneralQRScannerViewController()
        scanner.filter = filter
        scanner.modalPresentationStyle = .fullScreen
        scanner.onSuccess = { [weak self] text in
            // Native scanner is fully dismissed before this runs; hand control back to the PWA.
            self?.dispatchQRBridgeResult(
                bridgeAction: bridgeAction,
                ok: true,
                text: bridgeAction == "scanQr" ? text : nil,
                recoveryCode: bridgeAction == "scanRecoveryQr" ? text : nil,
                error: nil,
                requestId: rid
            )
        }
        scanner.onFailure = { [weak self] failure in
            let error: String
            switch failure {
            case .cancelled:
                error = "cancelled"
            case .cameraUnavailable:
                error = "camera_unavailable"
            case .cameraPermissionDenied:
                error = "camera_permission_denied"
            case .qrNotFound:
                error = bridgeAction == "scanRecoveryQr" ? "recovery_qr_not_found" : "qr_not_found"
            case .unsupportedFile:
                error = "unsupported_file"
            }
            self?.dispatchQRBridgeResult(
                bridgeAction: bridgeAction,
                ok: false,
                text: nil,
                recoveryCode: nil,
                error: error,
                requestId: rid
            )
        }
        presenter.present(scanner, animated: true)
    }

    private func presentCameraCapture(requestId: String) {
        pendingCameraCaptureRequestId = requestId
        guard UIImagePickerController.isSourceTypeAvailable(.camera),
              let presenter = topViewController()
        else {
            pendingCameraCaptureRequestId = ""
            dispatchIOSBridgeJsonToWeb([
                "action": "cameraCapture",
                "ok": false,
                "requestId": requestId,
                "error": "camera_unavailable",
            ])
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.movie"]
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 120
        picker.delegate = self
        picker.modalPresentationStyle = .fullScreen
        presenter.present(picker, animated: true)
    }

    private func presentPhotoPicker(requestId: String) {
        guard let presenter = topViewController() else {
            dispatchIOSBridgeJsonToWeb([
                "action": "photoPicker",
                "ok": false,
                "requestId": requestId,
                "error": "no_presenter",
            ])
            return
        }
        pendingPhotoPickerRequestId = requestId
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 0
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let requestId = pendingPhotoPickerRequestId
        pendingPhotoPickerRequestId = ""
        picker.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            guard !results.isEmpty else {
                self.dispatchIOSBridgeJsonToWeb([
                    "action": "photoPicker",
                    "ok": false,
                    "requestId": requestId,
                    "error": "cancelled",
                ])
                return
            }
            // Never wait synchronously here. `didFinishPicking` is called on the
            // main thread, and blocking it with a semaphore prevents the file
            // provider and WKWebView from completing the hand-off. This was
            // especially visible when returning from iCloud with a large video.
            var sentAnyFile = false

            func reportReadFailure() {
                self.dispatchIOSBridgeJsonToWeb([
                    "action": "photoPicker",
                    "ok": false,
                    "requestId": requestId,
                    "error": "file_read_failed",
                ])
            }

            func sendResult(at index: Int) {
                guard index < results.count else {
                    if !sentAnyFile {
                        reportReadFailure()
                    }
                    return
                }

                let provider = results[index].itemProvider
                guard let typeIdentifier = provider.registeredTypeIdentifiers.first else {
                    sendResult(at: index + 1)
                    return
                }

                provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url), !data.isEmpty else {
                        DispatchQueue.main.async {
                            sendResult(at: index + 1)
                        }
                        return
                    }

                    let mimeType = UTType(typeIdentifier)?.preferredMIMEType ?? "application/octet-stream"
                    let filename = url.lastPathComponent.isEmpty
                        ? "photo-\(UUID().uuidString)"
                        : url.lastPathComponent
                    sentAnyFile = true
                    let startPayload: [String: Any] = [
                        "action": "photoPickerStart",
                        "ok": true,
                        "requestId": requestId,
                        "mimeType": mimeType,
                        "filename": filename,
                    ]
                    // 48 KiB is divisible by three, so each independently
                    // encoded slice can be concatenated into the original
                    // Base64 stream. Keeping the encoded slices short avoids
                    // building a second full-size copy of a large video.
                    let dataChunkSize = 48 * 1024
                    let fileIndex = index
                    func sendChunk(at offset: Int, chunkIndex: Int) {
                        guard offset < data.count else {
                            self.dispatchIOSBridgeJsonToWeb([
                                "action": "photoPickerEnd",
                                "ok": true,
                                "requestId": requestId,
                            ]) {
                                sendResult(at: fileIndex + 1)
                            }
                            return
                        }
                        let length = min(dataChunkSize, data.count - offset)
                        let encodedChunk = data.subdata(in: offset..<(offset + length)).base64EncodedString()
                        self.dispatchIOSBridgeJsonToWeb([
                            "action": "photoPickerChunk",
                            "requestId": requestId,
                            "index": chunkIndex,
                            "data": encodedChunk,
                        ]) {
                            sendChunk(at: offset + length, chunkIndex: chunkIndex + 1)
                        }
                    }
                    self.dispatchIOSBridgeJsonToWeb(startPayload) {
                        sendChunk(at: 0, chunkIndex: 0)
                    }
                }
            }

            sendResult(at: 0)
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        let requestId = pendingCameraCaptureRequestId
        pendingCameraCaptureRequestId = ""
        picker.dismiss(animated: true) { [weak self] in
            self?.dispatchIOSBridgeJsonToWeb([
                "action": "cameraCapture",
                "ok": false,
                "requestId": requestId,
                "error": "cancelled",
            ])
        }
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any],
    ) {
        let requestId = pendingCameraCaptureRequestId
        pendingCameraCaptureRequestId = ""
        let movieURL = info[.mediaURL] as? URL
        let data = movieURL.flatMap { try? Data(contentsOf: $0) }
        picker.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            guard let data else {
                self.dispatchIOSBridgeJsonToWeb([
                    "action": "cameraCapture",
                    "ok": false,
                    "requestId": requestId,
                    "error": "video_read_failed",
                ])
                if let movieURL {
                    try? FileManager.default.removeItem(at: movieURL)
                }
                return
            }
            // Do not inject the entire video as one JavaScript string. A short
            // recording can exceed WKWebView's evaluateJavaScript payload
            // limit, which used to make the PWA receive no usable result and
            // show a generic camera error. Transfer the base64 body in small
            // ASCII-only chunks instead.
            var payloads: [[String: Any]] = [[
                "action": "cameraCaptureStart",
                "ok": true,
                "requestId": requestId,
                "mimeType": "video/mp4",
            ]]
            let encoded = data.base64EncodedString()
            let chunkSize = 64 * 1024
            var index = 0
            while index < encoded.count {
                let start = encoded.index(encoded.startIndex, offsetBy: index)
                let end = encoded.index(start, offsetBy: min(chunkSize, encoded.count - index))
                payloads.append([
                    "action": "cameraCaptureChunk",
                    "requestId": requestId,
                    "index": index / chunkSize,
                    "data": String(encoded[start..<end]),
                ])
                index += encoded.distance(from: start, to: end)
            }
            payloads.append([
                "action": "cameraCaptureEnd",
                "ok": true,
                "requestId": requestId,
            ])
            self.dispatchIOSBridgeJsonSequenceToWeb(payloads)
            if let movieURL {
                try? FileManager.default.removeItem(at: movieURL)
            }
        }
    }

    private func saveFile(dataUrl: String?, filename: String?, mimeType: String?, requestId: String?) {
        let rid = requestId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = dataUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let comma = raw.firstIndex(of: ",")
        let encoded = comma.map { String(raw[raw.index(after: $0)...]) } ?? raw
        guard !encoded.isEmpty,
              let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters])
        else {
            dispatchIOSBridgeJsonToWeb(["action": "saveFile", "ok": false, "requestId": rid, "error": "invalid_file_data"])
            return
        }
        let safeName = (filename ?? "download")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = (safeName?.isEmpty == false ? safeName! : "download")
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(finalName)
        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            dispatchIOSBridgeJsonToWeb(["action": "saveFile", "ok": false, "requestId": rid, "error": "file_write_failed"])
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let presenter = self.topViewController() else {
                self.dispatchIOSBridgeJsonToWeb(["action": "saveFile", "ok": false, "requestId": rid, "error": "no_presenter"])
                return
            }
            let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.sourceView = self.webView ?? presenter.view
                popover.sourceRect = CGRect(
                    x: (self.webView?.bounds.midX ?? presenter.view.bounds.midX),
                    y: (self.webView?.bounds.midY ?? presenter.view.bounds.midY),
                    width: 1,
                    height: 1
                )
            }
            activity.completionWithItemsHandler = { _, completed, _, _ in
                try? FileManager.default.removeItem(at: fileURL)
                self.dispatchIOSBridgeJsonToWeb([
                    "action": "saveFile",
                    "ok": completed,
                    "requestId": rid,
                ])
            }
            presenter.present(activity, animated: true)
        }
    }

    private func saveRecoveryQrToPhotos(dataUrl: String?, filename: String?, requestId: String?) {
        let rid = requestId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let raw = dataUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            dispatchPhotoSaveResult(ok: false, error: "missing_data_url", requestId: rid)
            return
        }
        guard let image = imageFromPngDataUrl(raw) else {
            dispatchPhotoSaveResult(ok: false, error: "invalid_image_data", requestId: rid)
            return
        }

        let performSave = { [weak self] in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }, completionHandler: { success, error in
                self?.dispatchPhotoSaveResult(
                    ok: success,
                    error: success ? nil : (error?.localizedDescription ?? "photo_save_failed"),
                    requestId: rid
                )
            })
        }

        if #available(iOS 14, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            switch status {
            case .authorized, .limited:
                performSave()
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                    if newStatus == .authorized || newStatus == .limited {
                        performSave()
                    } else {
                        self.dispatchPhotoSaveResult(ok: false, error: "photo_permission_denied", requestId: rid)
                    }
                }
            default:
                dispatchPhotoSaveResult(ok: false, error: "photo_permission_denied", requestId: rid)
            }
        } else {
            let status = PHPhotoLibrary.authorizationStatus()
            switch status {
            case .authorized:
                performSave()
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization { newStatus in
                    if newStatus == .authorized {
                        performSave()
                    } else {
                        self.dispatchPhotoSaveResult(ok: false, error: "photo_permission_denied", requestId: rid)
                    }
                }
            default:
                dispatchPhotoSaveResult(ok: false, error: "photo_permission_denied", requestId: rid)
            }
        }
    }

    private func imageFromPngDataUrl(_ raw: String) -> UIImage? {
        let base64: String
        if let comma = raw.firstIndex(of: ",") {
            base64 = String(raw[raw.index(after: comma)...])
        } else {
            base64 = raw
        }
        guard let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) else {
            return nil
        }
        return UIImage(data: data)
    }

    private func dispatchPhotoSaveResult(ok: Bool, error: String?, requestId: String) {
        var dict: [String: Any] = [
            "action": "saveRecoveryQrToPhotos",
            "ok": ok,
            "requestId": requestId,
        ]
        if let error = error, !error.isEmpty {
            dict["error"] = error
        }
        dispatchIOSBridgeJsonToWeb(dict)
    }

    private func dispatchQRBridgeResult(
        bridgeAction: String,
        ok: Bool,
        text: String?,
        recoveryCode: String?,
        error: String?,
        requestId: String
    ) {
        var dict: [String: Any] = [
            "action": bridgeAction,
            "ok": ok,
            "requestId": requestId,
        ]
        if let text = text, !text.isEmpty {
            dict["text"] = text
        }
        if let recoveryCode = recoveryCode, !recoveryCode.isEmpty {
            dict["recoveryCode"] = recoveryCode
        }
        if let error = error, !error.isEmpty {
            dict["error"] = error
        }
        dispatchIOSBridgeJsonToWeb(dict)
    }

    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while true {
            if let presented = top?.presentedViewController {
                top = presented
            } else if let nav = top as? UINavigationController {
                top = nav.visibleViewController
            } else if let tab = top as? UITabBarController {
                top = tab.selectedViewController
            } else {
                return top
            }
        }
    }

    private func dispatchIOSBridgeJsonToWeb(_ dict: [String: Any], completion: (() -> Void)? = nil) {
        // Early PushKit before WebView / before PWA listener: queue push tokens.
        if let action = dict["action"] as? String, action == "pushDeviceToken" {
            if webView == nil || !webContentReadyForPush {
                pendingPushTokenPayloads.append(dict)
                // Keep only the latest token per platform (ios vs ios_voip).
                var latestByPlatform: [String: [String: Any]] = [:]
                for item in pendingPushTokenPayloads {
                    let platform = (item["platform"] as? String)?.lowercased() ?? "ios"
                    latestByPlatform[platform] = item
                }
                pendingPushTokenPayloads = Array(latestByPlatform.values)
                NSLog(
                    "[CashTreesPush] queued pushDeviceToken platform=%@ (webReady=%@ webView=%@)",
                    (dict["platform"] as? String) ?? "?",
                    webContentReadyForPush ? "1" : "0",
                    webView == nil ? "nil" : "ok"
                )
                completion?()
                return
            }
        }
        guard let webView = webView else { return }
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let payload = String(data: data, encoding: .utf8)
        else { return }
        let js = """
        (function(){try{var d=\(payload);\
        window.dispatchEvent(new CustomEvent('cashtreesios',{detail:d}));\
        if(d&&d.ok&&(d.action==='scanQr'||d.action==='scanRecoveryQr')){try{window.focus&&window.focus();}catch(_){}}\
        }catch(e){}})();
        """
        DispatchQueue.main.async {
            webView.evaluateJavaScript(js) { _, _ in
                completion?()
            }
        }
    }

    private func dispatchIOSBridgeJsonSequenceToWeb(
        _ payloads: [[String: Any]],
        completion: (() -> Void)? = nil
    ) {
        guard !payloads.isEmpty else {
            completion?()
            return
        }
        var index = 0
        func sendNext() {
            guard index < payloads.count else {
                completion?()
                return
            }
            let payload = payloads[index]
            index += 1
            self.dispatchIOSBridgeJsonToWeb(payload) {
                sendNext()
            }
        }
        sendNext()
    }

    /// Core NFC：系统会强制展示扫描界面（含 `alertMessage`），无公开 API 可隐藏；仅可改提示文案。
    private func armNfcPhysicalCardRead() {
        guard NFCNDEFReaderSession.readingAvailable else {
            dispatchNfcJsonToWeb(["ok": false, "error": "no_hardware"])
            return
        }
        bindSessionActive = true
        let configuration = NFCTagReaderSession.Configuration(pollingOption: [.iso14443])
        let session = NFCTagReaderSession(configuration: configuration, delegate: self, queue: nil)
        session.alertMessage = "Hold your NFC card near the top of your iPhone."
        nfcSession = session
        session.begin()
    }

    private func disarmNfcReader(notifyWeb: Bool, error: String?) {
        bindSessionActive = false
        nfcSession?.invalidate()
        nfcSession = nil
        if notifyWeb, let error = error {
            dispatchNfcJsonToWeb(["ok": false, "error": error])
        }
    }

    private func dispatchNfcJsonToWeb(_ dict: [String: Any]) {
        guard let webView = webView else { return }
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let payload = String(data: data, encoding: .utf8)
        else { return }
        let js = """
        (function(){try{var d=\(payload);\
        window.dispatchEvent(new CustomEvent('cashtreesnfc',{detail:d}));\
        }catch(e){}})();
        """
        DispatchQueue.main.async {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: NFCTagReaderSessionDelegate

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        let wasActive = bindSessionActive
        bindSessionActive = false
        nfcSession = nil
        if let nfcErr = error as? NFCReaderError, nfcErr.code == .readerSessionInvalidationErrorUserCanceled {
            if wasActive { dispatchNfcJsonToWeb(["ok": false, "error": "cancelled"]) }
            return
        }
        if wasActive {
            dispatchNfcJsonToWeb(["ok": false, "error": error.localizedDescription])
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard bindSessionActive, let first = tags.first else { return }
        session.connect(to: first) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.bindSessionActive = false
                self.dispatchNfcJsonToWeb(["ok": false, "error": error.localizedDescription])
                session.invalidate()
                return
            }

            let tagUidHex: String
            let mifare: NFCMiFareTag
            switch first {
            case .miFare(let m):
                mifare = m
                tagUidHex = m.identifier.map { String(format: "%02X", $0) }.joined()
            default:
                self.bindSessionActive = false
                self.dispatchNfcJsonToWeb(["ok": false, "error": "unsupported_tag"])
                session.invalidate()
                return
            }

            mifare.readNDEF { [weak self] message, _ in
                guard let self = self else { return }
                self.bindSessionActive = false
                if tagUidHex.isEmpty {
                    self.dispatchNfcJsonToWeb(["ok": false, "error": "empty_tag_uid"])
                    session.invalidate()
                    return
                }
                let uriString = firstNdefUriString(from: message)
                let sun = uriString.flatMap { parseSunParamsFromNdefUrl($0) }
                let queryUid = sun?.uid ?? tagUidHex
                var payload: [String: Any] = [
                    "ok": true,
                    "tagUidHex": tagUidHex,
                    "queryUid": queryUid,
                ]
                if let u = uriString { payload["ndefUri"] = u }
                if let s = sun {
                    payload["sun"] = [
                        "uid": s.uid,
                        "e": s.e,
                        "c": s.c,
                        "m": s.m,
                    ]
                }
                self.dispatchNfcJsonToWeb(payload)
                session.invalidate()
            }
        }
    }
}

// MARK: - SwiftUI WebView

struct CashTreesWebView: UIViewRepresentable {
    @ObservedObject var loadState: CashTreesWebLoadState
    @ObservedObject var deepLinkStore: CashTreesDeepLinkStore
    @ObservedObject var localPWAHost: CashTreesLocalPWAHost

    func makeCoordinator() -> CashTreesWebCoordinator {
        CashTreesWebCoordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true

        /// 必须含 `viewport-fit=cover`，WKWebView 才会把刘海区安全区暴露给 CSS `env(safe-area-inset-*)`（与 Safari/PWA 一致）。
        /// 若整段覆盖远程 viewport，会抹掉 `viewport-fit` 导致 Web 侧 safe-area 恒为 0、首屏贴顶。
        let viewportJS = """
        (function() {
          var m = document.querySelector('meta[name="viewport"]');
          var fit = 'viewport-fit=cover';
          if (!m) {
            m = document.createElement('meta');
            m.name = 'viewport';
            (document.head || document.documentElement).appendChild(m);
            m.setAttribute('content', 'width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no, ' + fit);
          } else {
            var c = (m.getAttribute('content') || '').trim();
            if (c.indexOf('viewport-fit') === -1) {
              m.setAttribute('content', c ? (c + ', ' + fit) : fit);
            }
          }
          var s = document.createElement('style');
          // Keep the page itself horizontally clipped, but do not block
          // horizontal gestures on nested overflow-x-auto rails.
          s.textContent = 'html,body{overflow-x:hidden!important;max-width:100%;touch-action:pan-x pan-y!important;}';
          (document.head || document.documentElement).appendChild(s);
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: viewportJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )

        config.setURLSchemeHandler(localPWAHost.schemeHandler, forURLScheme: CashTreesPWAScheme.scheme)

        let consoleRelay = CashTreesWebConsoleRelay.injectionScript()
        config.userContentController.addUserScript(
            CashTreesWebConsoleRelay.pageUserScript(
                source: consoleRelay,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        config.userContentController.addUserScript(
            CashTreesWebConsoleRelay.pageUserScript(
                source: consoleRelay,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )

        let coord = context.coordinator
        coord.loadState = loadState
        // Register handlers BEFORE user scripts so documentStart bridge can see
        // messageHandlers.CashTreesIOS (otherwise CashTreesIOS never installs).
        config.userContentController.add(coord, name: cashTreesIOSWKHandlerName)
        config.userContentController.add(coord.webConsoleMessageHandler, name: CashTreesWebConsoleRelay.handlerName)
        CashTreesWebConsoleRelay.logNative("registered handlers CashTreesIOS + \(CashTreesWebConsoleRelay.handlerName)")

        let status = queryIosNfcStatusString()
        let bridge = CashTreesWebCoordinator.bridgeInjectionScript(
            nfcStatus: status,
            embeddedVer: localPWAHost.activeVersion(),
            pendingVer: localPWAHost.pendingUpdateVersion() ?? ""
        )
        config.userContentController.addUserScript(
            WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        let renderReady = CashTreesWebCoordinator.renderReadyInjectionScript()
        config.userContentController.addUserScript(
            WKUserScript(source: renderReady, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        let webView = CashTreesWKWebView(frame: .zero, configuration: config)
        coord.webView = webView
        webView.navigationDelegate = coord
        webView.uiDelegate = coord
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        webView.isOpaque = true
        webView.backgroundColor = cashTreesWebSurfaceColor
        let sv = webView.scrollView
        // 与 `viewport-fit=cover` + 页内 `env(safe-area-inset-*)` 配合：避免 UIScrollView 再自动加一套 safe area inset（叠双层或挤顶）。
        sv.backgroundColor = cashTreesWebSurfaceColor
        sv.contentInsetAdjustmentBehavior = .never
        sv.minimumZoomScale = 1.0
        sv.maximumZoomScale = 1.0
        sv.zoomScale = 1.0
        sv.bouncesZoom = false
        sv.pinchGestureRecognizer?.isEnabled = false
        sv.alwaysBounceHorizontal = false
        sv.showsHorizontalScrollIndicator = false
        sv.bounces = false

        let pendingRemote: URL? = {
            deepLinkStore.consumeDeferredDeepLinkFromPasteboardIfNeeded()
            return deepLinkStore.takePendingWebURL()
        }()
        let initialURL = pendingRemote ?? defaultLocalWebAppURL(from: localPWAHost)
        coord.lastHandledDeepLinkNonce = deepLinkStore.deepLinkNonce
        coord.loadWebAppURL(initialURL, in: webView)
        loadState.scheduleSplashFallback()
        return webView
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: CashTreesWebCoordinator) {
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: cashTreesIOSWKHandlerName)
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: CashTreesWebConsoleRelay.handlerName)
        coordinator.webView = nil
        coordinator.loadState = nil
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.loadState = loadState
        let nonce = deepLinkStore.deepLinkNonce
        guard nonce != context.coordinator.lastHandledDeepLinkNonce else { return }
        DispatchQueue.main.async {
            guard nonce == deepLinkStore.deepLinkNonce else { return }
            context.coordinator.lastHandledDeepLinkNonce = nonce
            guard let url = deepLinkStore.takePendingWebURL() else { return }
            context.coordinator.loadWebAppURL(url, in: uiView, bypassDedup: true)
        }
    }
}

// MARK: - Splash（WebView 首屏加载前；与系统 LaunchScreen 保持同一视觉）

private struct CashTreesSplashOverlay: View {
    let animateOut: Bool
    let onAnimationCompleted: () -> Void

    /// Match the POS launch handoff background so the splash sits on the same
    /// deep navy surface during the full-screen phase and dismissal.
    private let splashBackground = cashTreesWebSurfaceSwiftUIColor
    private let burstTargetScale: CGFloat = 2.55
    private let burstDuration: Double = 0.52

    private enum Phase {
        case fullScreen
        case dismissing
    }

    @State private var phase: Phase = .fullScreen
    @State private var logoScale: CGFloat = 1.0
    @State private var overlayOpacity: CGFloat = 1.0
    @State private var animationCycle = 0

    var body: some View {
        Group {
            switch phase {
            case .fullScreen:
                splashBody
                    .allowsHitTesting(true)
            case .dismissing:
                splashBody
                    .opacity(overlayOpacity)
                    .allowsHitTesting(true)
            }
        }
        .ignoresSafeArea()
        .onChange(of: animateOut) { _, newValue in
            guard newValue else { return }
            startLogoBurst()
        }
    }

    private var splashBody: some View {
        ZStack {
            splashBackground
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                splashLogo
                    .scaleEffect(logoScale, anchor: .center)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading")
        }
    }

    private var splashLogo: some View {
        Image("SplashAppLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 120, height: 120)
    }

    private func startLogoBurst() {
        guard phase == .fullScreen else { return }
        animationCycle += 1
        let cycle = animationCycle
        phase = .dismissing
        logoScale = 1.0
        overlayOpacity = 1.0
        withAnimation(.easeInOut(duration: burstDuration)) {
            logoScale = burstTargetScale
            overlayOpacity = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + burstDuration + 0.05) {
            guard cycle == animationCycle else { return }
            onAnimationCompleted()
        }
    }
}

struct ContentView: View {
    @ObservedObject var deepLinkStore: CashTreesDeepLinkStore
    @ObservedObject private var localPWAHost = CashTreesLocalPWAHost.shared
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var webLoadState = CashTreesWebLoadState()
    @State private var webContentVisible = false

    var body: some View {
        ZStack {
            cashTreesWebSurfaceSwiftUIColor
                .ignoresSafeArea()
            if localPWAHost.isReady {
                CashTreesWebView(
                    loadState: webLoadState,
                    deepLinkStore: deepLinkStore,
                    localPWAHost: localPWAHost
                )
                .opacity(webContentVisible ? 1 : 0)
                .ignoresSafeArea()
            }
            if webLoadState.isSplashVisible {
                CashTreesSplashOverlay(
                    animateOut: webLoadState.shouldAnimateOut,
                    onAnimationCompleted: {
                        webLoadState.finishSplashHandoff()
                    }
                )
            }
        }
        .onAppear {
            localPWAHost.startIfNeeded()
            webLoadState.scheduleSplashFallback()
        }
        .onChange(of: webLoadState.shouldAnimateOut) { _, newValue in
            guard newValue else { return }
            DispatchQueue.main.async {
                webContentVisible = true
            }
        }
        .onChange(of: webLoadState.isSplashVisible) { _, newValue in
            DispatchQueue.main.async {
                webContentVisible = !newValue
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            let phase: String
            switch newPhase {
            case .background:
                phase = "background"
            case .inactive:
                phase = "inactive"
            case .active:
                phase = "active"
            @unknown default:
                phase = "active"
            }
            NotificationCenter.default.post(
                name: .cashTreesAppLifecycle,
                object: nil,
                userInfo: ["phase": phase]
            )
            if newPhase == .background {
                // Keep brand surface visible; server may be killed while WebView process survives.
                webContentVisible = !webLoadState.isSplashVisible
                return
            }
            guard newPhase == .active else { return }
            // Keep the current pixels visible during an ordinary app switch.
            // If WKWebView was terminated, the coordinator has already restored
            // the splash before reloading and will reveal the page after render.
            guard !webLoadState.isSplashVisible else { return }
            webContentVisible = true
        }
    }
}

#Preview {
    ContentView(deepLinkStore: CashTreesDeepLinkStore())
}
