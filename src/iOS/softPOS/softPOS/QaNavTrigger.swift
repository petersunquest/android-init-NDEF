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

    /// Main-frame decision log (policy value is the shared BeamioHostPolicy decision).
    static func logMainFrame(url: URL, policy: BeamioNavDecision) {
        log.notice("main-frame host=\(url.host ?? "", privacy: .public) path=\(url.path, privacy: .public) policy=\(String(describing: policy), privacy: .public)")
    }
}
#endif
