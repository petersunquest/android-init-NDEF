import Foundation

/// 对齐 Android `parseOpenContainerRelayPayload` / `parseJsonObjectForQrPayment`
enum BeamioOpenContainerQR {
    struct ParseResult {
        var payload: [String: Any]?
        var rejectReason: String?
    }

    static func parse(_ content: String) -> ParseResult {
        guard var root = parseJsonObjectForQrPayment(content) else {
            return ParseResult(payload: nil, rejectReason: "not a JSON object")
        }
        if let inner = root["openContainerPayload"] as? [String: Any] {
            root = inner
        }
        let account = optString(root["account"])
        let signature = optString(root["signature"])
        if account.isEmpty {
            return ParseResult(payload: nil, rejectReason: "missing or empty account")
        }
        if signature.isEmpty {
            return ParseResult(payload: nil, rejectReason: "missing or empty signature")
        }
        let to = optString(root["to"])
        let items = root["items"] as? [[String: Any]]
        let hasClosed = !to.isEmpty && (items?.isEmpty == false)
        let isOpen: Bool = {
            if root["currencyType"] != nil { return true }
            if hasClosed { return false }
            let nonceOk = root["nonce"] != nil
            let dl = root["deadline"] != nil || root["validBefore"] != nil
            return nonceOk && dl
        }()
        if isOpen {
            normalizeReactOpenRelayPayload(&root)
            return ParseResult(payload: root, rejectReason: nil)
        }
        if hasClosed {
            return ParseResult(payload: root, rejectReason: nil)
        }
        return ParseResult(payload: nil, rejectReason: "neither open relay nor closed relay")
    }

    private static func normalizeReactOpenRelayPayload(_ o: inout [String: Any]) {
        let vb = optString(o["validBefore"])
        let dl = optString(o["deadline"])
        if dl.isEmpty, !vb.isEmpty { o["deadline"] = vb }
        if vb.isEmpty, !dl.isEmpty { o["validBefore"] = dl }
        if o["maxAmount"] == nil { o["maxAmount"] = "0" }
        if o["currencyType"] == nil { o["currencyType"] = 4 }
    }

    private static func parseJsonObjectForQrPayment(_ content: String) -> [String: Any]? {
        var t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let candidate = extractJsonObjectSubstring(t) ?? t
        if let o = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) as? [String: Any] {
            return o
        }
        // outer JSON string
        if let v = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) {
            if let str = v as? String {
                var inner = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if inner.hasPrefix("\u{FEFF}") { inner.removeFirst() }
                inner = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                let sub = extractJsonObjectSubstring(inner) ?? inner
                return try? JSONSerialization.jsonObject(with: Data(sub.utf8)) as? [String: Any]
            }
        }
        return nil
    }

    private static func extractJsonObjectSubstring(_ raw: String) -> String? {
        guard let s = raw.firstIndex(of: "{"),
              let e = raw.lastIndex(of: "}"),
              s < e
        else { return nil }
        return String(raw[s ... e])
    }

    private static func optString(_ v: Any?) -> String {
        guard let v else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return "\(v)"
    }

    static func parseBeamioWallet(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "wallet" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEthAddress
    }

    static func parseBeamioTab(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "beamio" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    struct CustomerIdentity {
        var beamioTag: String?
        var wallet: String?

        var hasIdentity: Bool {
            beamioTag?.nilIfEmpty != nil || wallet?.nilIfEthAddress != nil
        }
    }

    /// beamio.app link (`beamio` / `wallet` query) or Scan to Pay OpenContainer JSON (`account` + `signature`).
    static func parseCustomerIdentity(from text: String) -> CustomerIdentity? {
        if let url = customerLinkURL(from: text) {
            let beamio = parseBeamioTab(from: url)
            let wallet = parseBeamioWallet(from: url)
            if beamio != nil || wallet != nil {
                return CustomerIdentity(beamioTag: beamio, wallet: wallet)
            }
        }
        let parsed = parse(text)
        guard parsed.payload != nil else { return nil }
        let account = optString(parsed.payload?["account"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEthAddress
        guard account != nil else { return nil }
        return CustomerIdentity(beamioTag: nil, wallet: account)
    }

    /// Android `Uri.parse` + QR payloads: trim BOM/whitespace; if bare string fails, detect first http(s) link.
    static func customerLinkURL(from raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\u{FEFF}") { trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let u = URL(string: trimmed), u.scheme == "http" || u.scheme == "https" { return u }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let ns = trimmed as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let detector, let m = detector.firstMatch(in: trimmed, options: [], range: range),
              m.resultType == .link,
              let u = m.url,
              u.scheme == "http" || u.scheme == "https"
        else { return nil }
        return u
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var nilIfEthAddress: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("0x"), t.count >= 42 else { return nil }
        return t
    }
}
