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
import SwiftUI
import UIKit
import WebKit

/// POS terminal: WebView loads POS PWA only (`beamio-pos-pwa-native-webview-shell.mdc`).
/// Deprecated: native POS UI in `iOS_NDEF/`. Consumer shell uses `BeamioDeepLink.defaultWebAppURL` (`/app/`).
private let cashTreesAppURL = URL(string: "https://pos.conet.network/")!

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
}

// MARK: - WK Coordinator

final class CashTreesWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NFCTagReaderSessionDelegate {
    weak var webView: WKWebView?
    weak var loadState: CashTreesWebLoadState?

    private var nfcSession: NFCTagReaderSession?
    private var bindSessionActive = false
    private var initialWebRenderReadySignaled = false
    private var webContentProcessNeedsReload = false
    private var lastLoadedWebURLString: String?
    private var becameActiveObserver: NSObjectProtocol?
    var lastHandledDeepLinkNonce = 0

    override init() {
        super.init()
        becameActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recoverWebContentIfNeeded()
        }
    }

    deinit {
        if let becameActiveObserver {
            NotificationCenter.default.removeObserver(becameActiveObserver)
        }
    }

    func loadWebAppURL(_ url: URL, in webView: WKWebView, bypassDedup: Bool = false) {
        let key = url.absoluteString
        if !bypassDedup, lastLoadedWebURLString == key { return }
        lastLoadedWebURLString = key
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        webView.load(request)
    }

    /// Start the splash handoff only after the page reports that it has
    /// completed an actual render pass, so the splash fades into ready content
    /// instead of a white interstitial.
    private func beginInitialWebHandoffIfNeeded() {
        guard !initialWebRenderReadySignaled else { return }
        initialWebRenderReadySignaled = true
        DispatchQueue.main.async { [weak self] in
            self?.loadState?.beginSplashHandoff()
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
            loadWebAppURL(unwrapped, in: webView, bypassDedup: true)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
        webContentProcessNeedsReload = true
        initialWebRenderReadySignaled = false
        if UIApplication.shared.applicationState == .active {
            performWebContentRecovery(on: webView)
        }
    }

    private func recoverWebContentIfNeeded() {
        guard webContentProcessNeedsReload, let webView else { return }
        performWebContentRecovery(on: webView)
    }

    private func performWebContentRecovery(on webView: WKWebView) {
        webContentProcessNeedsReload = false
        initialWebRenderReadySignaled = false
        if webView.url != nil {
            webView.reload()
            return
        }
        if let last = lastLoadedWebURLString, let url = URL(string: last) {
            loadWebAppURL(url, in: webView, bypassDedup: true)
            return
        }
        loadWebAppURL(cashTreesAppURL, in: webView, bypassDedup: true)
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

    /// document start 注入用：与 Android `CashTreesAndroid.getNfcStatus()` 字符串一致
    static func bridgeInjectionScript(nfcStatus: String) -> String {
        let esc = nfcStatus
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        window.__CT_IOS_NFC_STATUS__='\(esc)';
        (function(){
          var H='\(cashTreesIOSWKHandlerName)';
          if(!window.webkit||!window.webkit.messageHandlers||!window.webkit.messageHandlers[H])return;
          window.CashTreesIOS={
            getNfcStatus:function(){return window.__CT_IOS_NFC_STATUS__||'no_bridge';},
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
            openURL:function(payload){
              payload=payload||{};
              window.webkit.messageHandlers[H].postMessage({
                action:'openURL',
                url:payload.url||''
              });
            }
          };
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
        guard message.name == cashTreesIOSWKHandlerName,
              let body = message.body as? [String: Any],
              let action = body["action"] as? String
        else { return }
        switch action {
        case "startPhysicalCardBind":
            DispatchQueue.main.async { [weak self] in self?.armNfcPhysicalCardRead() }
        case "cancelPhysicalCardBind":
            DispatchQueue.main.async { [weak self] in self?.disarmNfcReader(notifyWeb: true, error: "cancelled") }
        case "saveRecoveryQrToPhotos":
            let dataUrl = body["dataUrl"] as? String
            let filename = body["filename"] as? String
            let requestId = body["requestId"] as? String
            saveRecoveryQrToPhotos(dataUrl: dataUrl, filename: filename, requestId: requestId)
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
        case "webContentReady":
            DispatchQueue.main.async { [weak self] in self?.beginInitialWebHandoffIfNeeded() }
        case "openURL":
            let url = body["url"] as? String
            DispatchQueue.main.async { [weak self] in self?.openExternalURLFromBridge(url) }
        default:
            break
        }
    }

    /// PWA `CashTreesIOS.openURL({ url })` — open http(s)/mailto/tel in the system browser or handler.
    private func openExternalURLFromBridge(_ raw: String?) {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return }
        let allowed: Set<String> = ["http", "https", "mailto", "tel"]
        guard allowed.contains(scheme) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
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

    private func dispatchIOSBridgeJsonToWeb(_ dict: [String: Any]) {
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
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
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
          s.textContent = 'html,body{overflow-x:hidden!important;max-width:100%;touch-action:pan-y;}';
          (document.head || document.documentElement).appendChild(s);
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: viewportJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )

        let status = queryIosNfcStatusString()
        let bridge = CashTreesWebCoordinator.bridgeInjectionScript(nfcStatus: status)
        config.userContentController.addUserScript(
            WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        let renderReady = CashTreesWebCoordinator.renderReadyInjectionScript()
        config.userContentController.addUserScript(
            WKUserScript(source: renderReady, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        let coord = context.coordinator
        coord.loadState = loadState
        config.userContentController.add(coord, name: cashTreesIOSWKHandlerName)

        let webView = WKWebView(frame: .zero, configuration: config)
        coord.webView = webView
        webView.navigationDelegate = coord
        webView.uiDelegate = coord
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

        let initialURL = deepLinkStore.takePendingWebURL() ?? cashTreesAppURL
        coord.lastHandledDeepLinkNonce = deepLinkStore.deepLinkNonce
        coord.loadWebAppURL(initialURL, in: webView)
        loadState.scheduleSplashFallback()
        return webView
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: CashTreesWebCoordinator) {
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: cashTreesIOSWKHandlerName)
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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var webLoadState = CashTreesWebLoadState()
    @State private var webContentVisible = false

    var body: some View {
        ZStack {
            cashTreesWebSurfaceSwiftUIColor
                .ignoresSafeArea()
            CashTreesWebView(loadState: webLoadState, deepLinkStore: deepLinkStore)
                .opacity(webContentVisible ? 1 : 0)
                .ignoresSafeArea()
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
            guard newPhase == .active, !webLoadState.isSplashVisible else { return }
            // Safety net: never leave WebView at opacity 0 after splash is gone.
            webContentVisible = true
        }
    }
}

#Preview {
    ContentView(deepLinkStore: CashTreesDeepLinkStore())
}
