//
//  BeamioDeepLink.swift
//  softPOS
//
//  Universal Links (https://pos.beamio.app/...) + custom scheme (beamio://open?...).
//

import Combine
import Foundation

enum BeamioDeepLink {
    static let customScheme = "beamio"
    static let customOpenHost = "open"

    /// Default softPOS WebView entry — posPWA at root base path.
    static let defaultWebAppURL = URL(string: "https://pos.beamio.app/")!

    private static let posWebHost = "pos.beamio.app"

    /// HTTPS hosts the WebView may load from deep links (allowlist).
    static let allowedWebHosts: Set<String> = [
        posWebHost,
        "beamio.app",
        "www.beamio.app",
        "verra.network",
        "www.verra.network",
    ]

    /// Universal Link path prefixes on beamio.app (consumer `/app` only).
    static let universalLinkPathPrefixes = ["/app"]

    /// Share / install landing: unwrap `?target=https://…` to the inner PWA URL.
    ///
    /// `/app-download` must never load inside the native WKWebView — it is the homepage SPA,
    /// not the in-app PWA, and can strand the launch splash on a loading interstitial.
    static func unwrapAppDownloadLandingURL(_ url: URL) -> URL? {
        let path = url.path
        guard path == "/app-download" || path.hasPrefix("/app-download/") else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let targetRaw = components.queryItems?.first(where: { $0.name == "target" })?.value
        else { return nil }
        let decoded = targetRaw.removingPercentEncoding ?? targetRaw
        guard let targetURL = URL(string: decoded),
              let sanitized = sanitizeHTTPSWebURL(targetURL)
        else { return nil }
        guard isAllowedInAppWebTarget(sanitized) else { return nil }
        return sanitized
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

    // MARK: - Custom scheme

    /// `beamio://open?target=<urlencode(https://…)>` or `beamio://open?…` query passthrough
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
        if url.host?.lowercased() == posWebHost {
            return url
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

    private static func isAllowedInAppWebTarget(_ url: URL) -> Bool {
        let path = url.path
        if url.host?.lowercased() == posWebHost {
            return true
        }
        return path == "/app" || path == "/app/" || path.hasPrefix("/app/")
    }

    private static func sanitizeHTTPSWebURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        guard let host = url.host?.lowercased(), allowedWebHosts.contains(host) else { return nil }
        return url
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

    func handleIncomingURL(_ url: URL) {
        guard let resolved = BeamioDeepLink.resolveWebAppURL(from: url) else { return }
        pendingWebURLStorage = resolved
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
