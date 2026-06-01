//
//  CashTreesLocalSchemeHandler.swift
//  CashTrees_iOS
//

import Foundation
import WebKit

/// Serves embedded SilentPassUI from Documents (`active/`) via custom URL scheme.
final class CashTreesLocalSchemeHandler: NSObject, WKURLSchemeHandler {
    private let bundleStore: CashTreesPWABundleStore
    private let queue = DispatchQueue(label: "CashTreesLocalSchemeHandler.queue")
    private var inFlight = 0

    init(bundleStore: CashTreesPWABundleStore = .shared) {
        self.bundleStore = bundleStore
        super.init()
    }

    var hasInFlightTasks: Bool {
        queue.sync { inFlight > 0 }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        bumpInFlight(+1)
        defer { bumpInFlight(-1) }

        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let path = requestURL.path.isEmpty ? "/" : requestURL.path
        guard let fileURL = bundleStore.resolveFileURL(for: path) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let mime = Self.mimeType(for: fileURL.pathExtension)
            let headers: [String: String] = [
                "Content-Type": mime,
                "Content-Length": "\(data.count)",
                "Cache-Control": "no-cache",
                "Access-Control-Allow-Origin": "*",
            ]
            guard let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                urlSchemeTask.didFailWithError(URLError(.badServerResponse))
                return
            }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Reads are synchronous from local disk.
    }

    func waitForInFlightTasks(timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !hasInFlightTasks { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func bumpInFlight(_ delta: Int) {
        queue.sync { inFlight += delta }
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "webp": return "image/webp"
        case "map": return "application/json"
        default: return "application/octet-stream"
        }
    }
}
