import CoreNFC
import Foundation

/// NTAG / ISO14443 URI NDEF via `NFCTagReaderSession` (entitlement **TAG**; **NDEF** is disallowed for current SDK / store checks).
final class BeamioNFCSession: NSObject, NFCTagReaderSessionDelegate {
    var onMessage: ((Result<(url: URL, raw: String), Error>) -> Void)?
    /// System NFC sheet dismissed by user (Cancel / swipe) — not tag errors or successful read invalidation.
    var onUserCanceled: (() -> Void)?
    /// Device cannot use tag reading (`readingAvailable` is false). VM may fall back to QR (read/topup/charge) or dismiss (Link App).
    var onReadingUnavailable: (() -> Void)?
    private var session: NFCTagReaderSession?

    /// Set immediately before `onMessage(.success)` + `session.invalidate()`. Core NFC often reports
    /// `.readerSessionInvalidationErrorFirstNDEFTagRead` after a **successful** read; we must not treat
    /// that as failure. For `invalidate(errorMessage:)` failures, this stays `false` so the error still
    /// reaches the app (see `didInvalidateWithError`).
    private var didDeliverSuccessForActiveSession = false

    /// Last `errorMessage` passed to `invalidate(errorMessage:)` for this session. iOS sometimes reports
    /// `.readerSessionInvalidationErrorUserCanceled` when the sheet closes after an in-session tag error;
    /// we must deliver `onMessage(.failure)` (retry NFC) instead of `onUserCanceled` (opens QR).
    private var pendingInvalidateErrorMessage: String?

    func begin() {
        guard NFCTagReaderSession.readingAvailable else {
            let cb = onReadingUnavailable
            if let cb {
                if Thread.isMainThread {
                    cb()
                } else {
                    DispatchQueue.main.async { cb() }
                }
            }
            return
        }
        session?.invalidate()
        session = nil
        let configuration = NFCTagReaderSession.Configuration(
            pollingOption: .iso14443,
            iso7816SelectIdentifiers: [],
            feliCaSystemCodes: []
        )
        let s = NFCTagReaderSession(configuration: configuration, delegate: self, queue: nil)
        s.alertMessage = "Hold the NTAG card near the top of the iPhone."
        didDeliverSuccessForActiveSession = false
        pendingInvalidateErrorMessage = nil
        session = s
        s.begin()
    }

    func invalidate() {
        session?.invalidate()
        session = nil
    }

    /// Ignore delegate callbacks from a session we already replaced or tore down (stops stale Core NFC events propagating into app logic).
    private func isActiveSession(_ s: NFCTagReaderSession) -> Bool {
        session === s
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        guard isActiveSession(session) else { return }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        guard isActiveSession(session) else { return }
        self.session = nil
        if let nfcErr = error as? NFCReaderError {
            switch nfcErr.code {
            case .readerSessionInvalidationErrorFirstNDEFTagRead:
                // Success path calls `invalidate()` after delivering payload; this code is expected then.
                // Do not swallow real failures from `invalidate(errorMessage:)` (flag stays false).
                if didDeliverSuccessForActiveSession {
                    didDeliverSuccessForActiveSession = false
                    pendingInvalidateErrorMessage = nil
                    return
                }
            case .readerSessionInvalidationErrorUserCanceled:
                // After a successful URI read we call `invalidate()` with no message; some iOS versions report
                // `userCanceled` instead of `firstNDEFTagRead`. Must not fire `onUserCanceled` (opens QR) while
                // charge/topup workflow is already running from `onMessage(.success)`.
                if didDeliverSuccessForActiveSession {
                    didDeliverSuccessForActiveSession = false
                    pendingInvalidateErrorMessage = nil
                    return
                }
                if let msg = pendingInvalidateErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !msg.isEmpty {
                    pendingInvalidateErrorMessage = nil
                    let err = NSError(
                        domain: "BeamioNFCTagRead",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: msg]
                    )
                    syncMessageFailureIfNeeded(err)
                    return
                }
                pendingInvalidateErrorMessage = nil
                let cb = onUserCanceled
                if let cb {
                    if Thread.isMainThread {
                        cb()
                    } else {
                        DispatchQueue.main.async { cb() }
                    }
                }
                return
            default:
                break
            }
        }
        didDeliverSuccessForActiveSession = false
        pendingInvalidateErrorMessage = nil
        syncMessageFailureIfNeeded(error)
    }

    private func invalidateTagSession(_ session: NFCTagReaderSession, errorMessage: String) {
        let trimmed = errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingInvalidateErrorMessage = trimmed.isEmpty ? "Tap to read the card again." : trimmed
        session.invalidate(errorMessage: errorMessage)
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard isActiveSession(session) else { return }
        if tags.count > 1 {
            invalidateTagSession(session, errorMessage: "Hold only one tag at a time.")
            return
        }
        guard let tag = tags.first else {
            invalidateTagSession(session, errorMessage: "No tag found.")
            return
        }
        session.connect(to: tag) { [weak self] error in
            guard let self else { return }
            guard self.isActiveSession(session) else { return }
            if let error {
                self.invalidateTagSession(session, errorMessage: error.localizedDescription)
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
            invalidateTagSession(session, errorMessage: "Unsupported tag type.")
            return
        }
        ndefTag.queryNDEFStatus { [weak self] status, _, error in
            guard let self else { return }
            guard self.isActiveSession(session) else { return }
            if let error {
                self.invalidateTagSession(session, errorMessage: error.localizedDescription)
                return
            }
            guard status != .notSupported else {
                self.invalidateTagSession(session, errorMessage: "Tag does not support NDEF.")
                return
            }
            ndefTag.readNDEF { [weak self] message, error in
                guard let self else { return }
                guard self.isActiveSession(session) else { return }
                if let error {
                    self.invalidateTagSession(session, errorMessage: error.localizedDescription)
                    return
                }
                guard let message else {
                    self.invalidateTagSession(session, errorMessage: "No NDEF message.")
                    return
                }
                for rec in message.records {
                    if let u = self.parseWellKnownUri(record: rec) {
                        self.deliverPayloadOnMain(url: u, session: session)
                        return
                    }
                }
                self.invalidateTagSession(session, errorMessage: "No URI NDEF record found.")
            }
        }
    }

    private func deliverPayloadOnMain(url: URL, session: NFCTagReaderSession) {
        let raw = url.absoluteString
        if Thread.isMainThread {
            guard isActiveSession(session) else { return }
            didDeliverSuccessForActiveSession = true
            onMessage?(.success((url, raw)))
            session.invalidate()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.isActiveSession(session) else { return }
                self.didDeliverSuccessForActiveSession = true
                self.onMessage?(.success((url, raw)))
                session.invalidate()
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
