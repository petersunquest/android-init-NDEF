import CoreNFC
import Foundation

/// NTAG / ISO14443 URI NDEF via `NFCTagReaderSession` (entitlement **TAG**; **NDEF** is disallowed for current SDK / store checks).
final class BeamioNFCSession: NSObject, NFCTagReaderSessionDelegate {
    var onMessage: ((Result<(url: URL, raw: String), Error>) -> Void)?
    private var session: NFCTagReaderSession?

    func begin() {
        guard NFCTagReaderSession.readingAvailable else {
            onMessage?(.failure(NSError(domain: "NFC", code: 1, userInfo: [NSLocalizedDescriptionKey: "NFC not available"])))
            return
        }
        guard let s = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil) else {
            onMessage?(.failure(NSError(domain: "NFC", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not start NFC session"])))
            return
        }
        s.alertMessage = "Hold the NTAG card near the top of the iPhone."
        session = s
        s.begin()
    }

    func invalidate() {
        session?.invalidate()
        session = nil
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        self.session = nil
        if let nfcErr = error as? NFCReaderError {
            switch nfcErr.code {
            case .readerSessionInvalidationErrorFirstNDEFTagRead,
                 .readerSessionInvalidationErrorUserCanceled:
                return
            default:
                break
            }
        }
        syncMessageFailureIfNeeded(error)
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        if tags.count > 1 {
            session.invalidate(errorMessage: "Hold only one tag at a time.")
            self.session = nil
            return
        }
        guard let tag = tags.first else {
            session.invalidate(errorMessage: "No tag found.")
            self.session = nil
            return
        }
        session.connect(to: tag) { [weak self] error in
            guard let self else { return }
            if let error {
                session.invalidate(errorMessage: error.localizedDescription)
                self.session = nil
                return
            }
            self.readNDEF(from: tag, session: session)
        }
    }

    private func readNDEF(from tag: NFCTag, session: NFCTagReaderSession) {
        let ndefTag: NFCNDEFTag?
        switch tag {
        case let .iso15693(t): ndefTag = t
        case let .feliCa(t): ndefTag = t
        case let .iso7816(t): ndefTag = t
        case let .miFare(t): ndefTag = t
        @unknown default:
            ndefTag = nil
        }
        guard let ndefTag else {
            session.invalidate(errorMessage: "Unsupported tag type.")
            self.session = nil
            return
        }
        ndefTag.queryNDEFStatus { [weak self] status, _, error in
            guard let self else { return }
            if let error {
                session.invalidate(errorMessage: error.localizedDescription)
                self.session = nil
                return
            }
            guard status != .notSupported else {
                session.invalidate(errorMessage: "Tag does not support NDEF.")
                self.session = nil
                return
            }
            ndefTag.readNDEF { message, error in
                if let error {
                    session.invalidate(errorMessage: error.localizedDescription)
                    self.session = nil
                    return
                }
                guard let message else {
                    session.invalidate(errorMessage: "No NDEF message.")
                    self.session = nil
                    return
                }
                for rec in message.records {
                    if let u = self.parseWellKnownUri(record: rec) {
                        self.onMessage?(.success((u, u.absoluteString)))
                        session.invalidate()
                        self.session = nil
                        return
                    }
                }
                session.invalidate(errorMessage: "No URI NDEF record found.")
                self.session = nil
            }
        }
    }

    /// Avoid duplicate failure delivery if invalidation runs on a background queue.
    private func syncMessageFailureIfNeeded(_ error: Error) {
        if Thread.isMainThread {
            onMessage?(.failure(error))
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onMessage?(.failure(error))
            }
        }
    }

    private func parseWellKnownUri(record: NFCNDEFPayload) -> URL? {
        guard record.typeNameFormat == .nfcWellKnown else { return nil }
        let type = record.type
        guard type.count >= 1, type[0] == 0x55 else { return nil } // 'U'
        let payload = record.payload
        guard !payload.isEmpty else { return nil }
        var idx = 0
        let prefixCode = payload[idx]
        idx += 1
        let prefix = BeamioNFCSession.uriPrefixes[Int(prefixCode)] ?? ""
        guard let rest = String(data: payload.subdata(in: idx ..< payload.count), encoding: .utf8) else { return nil }
        let urlStr = prefix + rest
        return URL(string: urlStr)
    }

    /// NFC Forum URI prefix map (subset)
    private static let uriPrefixes: [Int: String] = [
        0x00: "",
        0x01: "http://www.",
        0x02: "https://www.",
        0x03: "http://",
        0x04: "https://",
    ]
}

enum BeamioSunParser {
    static func sunParams(from url: URL) -> SunParams? {
        guard let comp = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let q = comp.queryItems
        else { return nil }
        func p(_ name: String) -> String? {
            q.first(where: { $0.name == name })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let uid = p("uid"), !uid.isEmpty,
              let e = p("e"), e.count == 64,
              let c = p("c"), c.count == 6,
              let m = p("m"), m.count == 16,
              e.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil,
              c.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil,
              m.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil
        else { return nil }
        let allZero = e.allSatisfy { $0 == "0" } && c.allSatisfy { $0 == "0" } && m.allSatisfy { $0 == "0" }
        if allZero { return nil }
        return SunParams(uid: uid, e: e.lowercased(), c: c.uppercased(), m: m.lowercased())
    }

    static func uidHexPreview(from url: URL) -> String? {
        if let sun = sunParams(from: url) { return sun.uid }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "uid" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
