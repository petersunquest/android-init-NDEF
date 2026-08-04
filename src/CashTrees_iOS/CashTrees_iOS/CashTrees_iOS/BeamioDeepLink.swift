//
//  BeamioDeepLink.swift
//  CashTrees_iOS
//
//  Universal Links (https://beamio.app/...) + custom scheme (beamio://open?...).
//

import Combine
import Foundation
import UIKit

enum BeamioDeepLink {
    static let customScheme = "beamio"
    static let customOpenHost = "open"

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
    static let universalLinkPathPrefixes = ["/app"]

    /// Share / install landing: unwrap `?target=https://beamio.app/app/…` to the inner PWA URL.
    ///
    /// `/app-download` must never load inside the native WKWebView — it is the homepage SPA,
    /// not SilentPassUI `/app/`, and can strand the launch splash on a loading interstitial.
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
        let targetPath = sanitized.path
        guard targetPath == "/app" || targetPath == "/app/" || targetPath.hasPrefix("/app/") else {
            return nil
        }
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

    /// Pasteboard / Play-referrer style deferred install: only merchant/coupon/redeem deep links.
    static func resolveDeferredInstallDeepLink(from url: URL) -> URL? {
        guard let resolved = resolveWebAppURL(from: url) ?? resolveHTTPSWebTarget(url) else { return nil }
        guard urlCarriesMerchantOrCouponPayload(resolved) else { return nil }
        return resolved
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
        let discover = (map["discover"] ?? "").lowercased()
        if discover == "open" || discover == "1" || discover == "true" { return true }
        let couponId = map["couponid"] ?? ""
        let claim = (map["claim"] ?? "").lowercased()
        if !couponId.isEmpty, claim.isEmpty || claim == "open" || claim == "1" || claim == "true" {
            return true
        }
        if map["redeemcode"] != nil { return true }
        return false
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

    func handleIncomingURL(_ url: URL) {
        guard let resolved = BeamioDeepLink.resolveWebAppURL(from: url) else { return }
        pendingWebURLStorage = BeamioDeepLink.mapResolvedWebAppURLToLocal(resolved)
        scheduleDeepLinkArrivalPublish()
    }

    /// After App Store install: landing copied `https://beamio.app/app/?beamiocard=…&ref=…` to the pasteboard.
    /// Consume once on cold start when no Universal Link / custom scheme arrived.
    func consumeDeferredDeepLinkFromPasteboardIfNeeded() {
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
