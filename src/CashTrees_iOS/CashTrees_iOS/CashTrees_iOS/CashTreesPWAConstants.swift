//
//  CashTreesPWAConstants.swift
//  CashTrees_iOS
//

import Foundation

enum CashTreesPWAScheme {
    static let scheme = "cashtrees-local"
    static let host = "localhost"
    static let remoteUpdateManifestURL = URL(string: "https://beamio.app/app/update.json")!
    static let remoteBundleBaseURL = URL(string: "https://beamio.app/app/")!

    static var entryURL: URL {
        URL(string: "\(scheme)://\(host)/index.html")!
    }

    static func entryURL(path: String, query: String? = nil, fragment: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var normalized = path
        if normalized.isEmpty { normalized = "/" }
        if !normalized.hasPrefix("/") { normalized = "/\(normalized)" }
        components.path = normalized == "/" ? "/" : normalized
        if let query, !query.isEmpty {
            components.queryItems = query
                .split(separator: "&")
                .compactMap { pair in
                    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { return nil }
                    return URLQueryItem(name: parts[0], value: parts[1])
                }
        }
        components.fragment = fragment
        return components.url ?? entryURL
    }
}

struct CashTreesPWAUpdateInfo: Codable, Equatable {
    let ver: String
    let filename: String
}
