//
//  ContentView.swift
//  CashTrees_iOS
//
//  Created by peter on 2026-03-27.
//

import CoreNFC
import SwiftUI
import WebKit

private let cashTreesAppURL = URL(string: "https://cashtrees.beamio.app/app/")!

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

// MARK: - WK Coordinator

final class CashTreesWebCoordinator: NSObject, WKScriptMessageHandler, NFCTagReaderSessionDelegate {
    weak var webView: WKWebView?

    private var nfcSession: NFCTagReaderSession?
    private var bindSessionActive = false

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
            }
          };
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
        default:
            break
        }
    }

    /// Core NFC：系统会强制展示扫描界面（含 `alertMessage`），无公开 API 可隐藏；仅可改提示文案。
    private func armNfcPhysicalCardRead() {
        guard NFCNDEFReaderSession.readingAvailable else {
            dispatchNfcJsonToWeb(["ok": false, "error": "no_hardware"])
            return
        }
        bindSessionActive = true
        let session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil)
        session?.alertMessage = "Hold your CashTrees card near the top of your iPhone."
        nfcSession = session
        session?.begin()
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
    func makeCoordinator() -> CashTreesWebCoordinator {
        CashTreesWebCoordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true

        let viewportJS = """
        (function() {
          var m = document.querySelector('meta[name="viewport"]');
          if (!m) {
            m = document.createElement('meta');
            m.name = 'viewport';
            (document.head || document.documentElement).appendChild(m);
          }
          m.setAttribute('content', 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no');
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

        let coord = context.coordinator
        config.userContentController.add(coord, name: cashTreesIOSWKHandlerName)

        let webView = WKWebView(frame: .zero, configuration: config)
        coord.webView = webView
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.maximumZoomScale = 1.0
        webView.scrollView.bouncesZoom = false
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false

        var request = URLRequest(url: cashTreesAppURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
        return webView
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: CashTreesWebCoordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: cashTreesIOSWKHandlerName)
        coordinator.webView = nil
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ContentView: View {
    var body: some View {
        CashTreesWebView()
            .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}
