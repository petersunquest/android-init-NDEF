//
//  BeamioCardRemoteImage.swift
//  iOS_NDEF
//
//  Raster URLs use AsyncImage; SVG and some gateway URLs (e.g. CoNET IPFS getFragment) use WKWebView — UIImage cannot decode SVG, and getFragment has no .svg suffix while returning image/svg+xml.
//

import SwiftUI
import WebKit

/// True when the URL is likely an SVG resource (path, data URL, or common query hints).
func beamioCardImageUrlLooksLikeSvg(urlString: String) -> Bool {
    let t = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return false }
    let lower = t.lowercased()
    if lower.hasPrefix("data:image/svg+xml") { return true }
    guard let u = URL(string: t) else { return false }
    let ext = u.pathExtension.lowercased()
    if ext == "svg" { return true }
    let pathLower = u.path.lowercased()
    if pathLower.contains(".svg?") || pathLower.hasSuffix(".svg") { return true }
    if let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems {
        for it in items {
            let n = it.name.lowercased()
            let v = (it.value ?? "").lowercased()
            if v == "svg" && (n == "format" || n == "type" || n == "fm") { return true }
        }
    }
    return false
}

/// True when the URL should be loaded with WebKit (`<img>`), not `AsyncImage`: SVG hints, or CoNET `/api/getFragment` (often `Content-Type: image/svg+xml` without a `.svg` path).
func beamioCardImageUrlNeedsWebKitImageLoader(urlString: String) -> Bool {
    if beamioCardImageUrlLooksLikeSvg(urlString: urlString) { return true }
    let t = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let u = URL(string: t) else { return false }
    let host = (u.host ?? "").lowercased()
    let path = u.path.lowercased()
    if host.contains("ipfs.conet.network"), path.contains("/api/getfragment") {
        return true
    }
    return false
}

private func beamioEscapeUrlForHtmlImgSrc(_ raw: String) -> String {
    raw
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
        .replacingOccurrences(of: "<", with: "&lt;")
}

/// Loads remote or data SVG in a transparent WebKit view; uses an HTML wrapper so `object-fit: cover` matches raster `scaledToFill`.
struct BeamioSvgWebImage: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject {
        var lastKey: String = ""
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        let w = WKWebView(frame: .zero, configuration: config)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.backgroundColor = .clear
        w.scrollView.isScrollEnabled = false
        w.scrollView.bounces = false
        return w
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let key = url.absoluteString
        if context.coordinator.lastKey == key { return }
        context.coordinator.lastKey = key

        if url.scheme?.lowercased() == "data" {
            webView.load(URLRequest(url: url))
            return
        }

        let src = beamioEscapeUrlForHtmlImgSrc(url.absoluteString)
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
        html,body{margin:0;padding:0;width:100%;height:100%;background:transparent!important;overflow:hidden}
        img{width:100%;height:100%;object-fit:cover;display:block;object-position:center}
        </style></head><body><img src="\(src)" alt="" decoding="async" /></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}

/// Card artwork: `AsyncImage` for bitmaps; `BeamioSvgWebImage` when `beamioCardImageUrlNeedsWebKitImageLoader` is true.
struct BeamioCardRasterOrSvgImage<Fallback: View>: View {
    let urlString: String?
    var rasterContentMode: ContentMode = .fill
    @ViewBuilder var fallback: () -> Fallback

    var body: some View {
        Group {
            let s0 = urlString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !s0.isEmpty, let url = URL(string: s0) {
                if beamioCardImageUrlNeedsWebKitImageLoader(urlString: s0) {
                    BeamioSvgWebImage(url: url)
                        .id(s0)
                } else {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(img):
                            img.resizable().aspectRatio(contentMode: rasterContentMode)
                        case .failure:
                            fallback()
                        case .empty:
                            ProgressView().scaleEffect(0.7)
                        @unknown default:
                            fallback()
                        }
                    }
                }
            } else {
                fallback()
            }
        }
    }
}
