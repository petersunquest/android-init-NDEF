//
//  QaNavTrigger.swift
//  softPOS
//
//  Debug-only navigation trigger for WebView policy evidence. Compiled out of Release builds.
//  `xcrun simctl openurl <device> "beamiopos://qa-nav?url=<https url>"` asks the POS WebView to
//  navigate its main frame; the navigation then goes through the normal decidePolicyFor policy.
//

#if DEBUG
import Foundation
import os
import WebKit

enum QaNavTrigger {
    static let notificationName = Notification.Name("BeamioQaNavRequested")
    static let log = Logger(subsystem: "com.beamio.app.pos.qa", category: "nav")
    static let allowedHosts: Set<String> = [
        "beamio.app", "www.beamio.app", "pos.beamio.app",
        "beamio.ca", "www.beamio.ca", "pos.beamio.ca",
    ]

    /// Returns true when the URL was a QA navigation request (consumed, never forwarded to the app).
    static func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "beamiopos", url.host?.lowercased() == "qa-nav" else { return false }
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value ?? ""
        guard let target = URL(string: raw), target.scheme?.lowercased() == "https",
              let host = target.host?.lowercased(), allowedHosts.contains(host)
        else {
            log.notice("qa-nav rejected (https Beamio hosts only)")
            return true
        }
        log.notice("qa-nav request \(target.absoluteString, privacy: .public)")
        NotificationCenter.default.post(name: notificationName, object: nil, userInfo: ["url": target])
        return true
    }

    /// Launch-argument trigger (no system URL prompt): `xcrun simctl launch <dev> <bundle> -qaNavURL <https url>`.
    /// Only the six Beamio test hosts are accepted; anything else is ignored and logged.
    static func validatedLaunchURL(_ raw: String) -> URL? {
        guard let target = URL(string: raw), target.scheme?.lowercased() == "https",
              let host = target.host?.lowercased(), allowedHosts.contains(host)
        else {
            log.notice("qa launch url ignored (https Beamio hosts only)")
            return nil
        }
        return target
    }

    private static var didRunLaunchNavigation = false

    /// Called once from the first main-frame load completion; navigates to the launch-argument URL.
    static func runLaunchNavigationOnce(_ webView: WKWebView) {
        guard !didRunLaunchNavigation else { return }
        didRunLaunchNavigation = true
        guard let raw = UserDefaults.standard.string(forKey: "qaNavURL"),
              let target = validatedLaunchURL(raw)
        else { return }
        log.notice("launch navigation to \(target.absoluteString, privacy: .public)")
        let js = "window.location.href='\(target.absoluteString)'"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// Main-frame decision log (policy value is the shared BeamioHostPolicy decision).
    static func logMainFrame(url: URL, policy: BeamioNavDecision) {
        log.notice("main-frame host=\(url.host ?? "", privacy: .public) path=\(url.path, privacy: .public) policy=\(String(describing: policy), privacy: .public)")
    }
}
#endif
