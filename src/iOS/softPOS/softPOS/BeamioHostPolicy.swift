//
//  BeamioHostPolicy.swift
//  softPOS
//
//  Pure main-frame navigation policy (mirror of Android `BeamioHostPolicy`). No WebKit types,
//  so unit tests can run without a WebView. Hosts are matched exactly; paths are lower-cased.
//
//  - cancel:   consumer Beamio pages and legacy/unmapped beamio.app / pos.beamio.app paths.
//              Cancelled locally; nothing is requested from the old or consumer domain.
//  - mapLocal: POS paths on POS hosts (old and new), served from the embedded scheme.
//  - pass:     any other host, left to WebKit as before.
//

import Foundation

nonisolated enum BeamioNavDecision: Equatable {
    case cancel
    case mapLocal
    case pass
}

nonisolated enum BeamioHostPolicy {
    /// Consumer Beamio hosts (old and new). Never loaded in the POS WebView.
    static let consumerHosts: Set<String> = ["beamio.ca", "www.beamio.ca", "beamio.app", "www.beamio.app"]

    /// POS hosts mapped to the embedded assets. Old pos.beamio.app is included.
    static let posHosts: Set<String> = ["pos.beamio.ca", "pos.beamio.app", "pos.conet.network"]

    /// Legacy hosts: any request to these reaches the old domain.
    static let legacyHosts: Set<String> = ["beamio.app", "www.beamio.app", "pos.beamio.app"]

    private static let bypassPrefixes = ["/api", "/og", "/metadata"]

    static func isPosPath(_ path: String) -> Bool {
        path == "/pos" || path == "/pos/" || path.hasPrefix("/pos/")
    }

    private static func isBypassPath(_ path: String) -> Bool {
        bypassPrefixes.contains { p in path == p || path.hasPrefix(p + "/") }
    }

    static func decide(host rawHost: String, path rawPath: String) -> BeamioNavDecision {
        let host = rawHost.lowercased()
        let path = rawPath.isEmpty ? "/" : rawPath.lowercased()
        if consumerHosts.contains(host) {
            return isPosPath(path) ? .mapLocal : .cancel
        }
        if host == "pos.beamio.app" {
            return isBypassPath(path) ? .cancel : .mapLocal
        }
        if host == "pos.beamio.ca" || host == "pos.conet.network" {
            return isBypassPath(path) ? .pass : .mapLocal
        }
        return .pass
    }

    /// Host a request would be sent to for this decision, or nil when nothing is requested.
    static func remoteHost(for decision: BeamioNavDecision, host: String) -> String? {
        decision == .pass ? host.lowercased() : nil
    }
}
