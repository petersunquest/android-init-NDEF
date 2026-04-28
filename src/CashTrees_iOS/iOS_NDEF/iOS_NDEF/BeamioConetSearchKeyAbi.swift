import Foundation

/// CoNET `AddressPGP.searchKey(address)` calldata + ABI decode — parity with SilentPassUI `getKeysFromCoNETPGPSC` / `searchKey`.
enum BeamioConetSearchKeyAbi {
    /// `searchKey(address)` selector
    private static let searchKeySelector = "052f2778"

    static func encodeSearchKeyCall(recipientEoa lower40Hex: String) -> String? {
        var h = lower40Hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasPrefix("0x") { h.removeFirst(2) }
        guard h.count == 40, h.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { return nil }
        return "0x" + searchKeySelector + String(repeating: "0", count: 24) + h
    }

    /// Decodes `(string userPgpKeyID, string userPublicKeyArmored, string routePgpKeyID, string routePublicKeyArmored, bool routeOnline)`.
    /// Returns **armored PGP block** for the recipient (after base64 unwrap of `userPublicKeyArmored`), or `nil` if missing.
    static func decodeSearchKeyUserPublicArmored(hex: String) -> String? {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("0x") || raw.hasPrefix("0X") { raw.removeFirst(2) }
        guard raw.count % 2 == 0, let data = Data(hexString: raw), data.count >= 160 else { return nil }

        func u256(_ off: Int) -> UInt64 {
            guard off + 32 <= data.count else { return 0 }
            let slice = data[off + 24 ..< off + 32]
            return slice.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }

        func readAbiString(headWordByteOffset: Int) -> String? {
            let ptr = Int(u256(headWordByteOffset))
            guard ptr + 32 <= data.count else { return nil }
            let len = Int(u256(ptr))
            guard len >= 0, ptr + 32 + len <= data.count else { return nil }
            let body = data[(ptr + 32) ..< (ptr + 32 + len)]
            return String(data: body, encoding: .utf8)
        }

        _ = u256(128) // bool routeOnline — unused

        // Tuple word1 → `userPublicKeyArmored` (base64 of armored key), SilentPassUI `fromBase64(info.userPublicKeyArmored)`
        guard let userPubB64 = readAbiString(headWordByteOffset: 32), !userPubB64.isEmpty else { return nil }
        guard let rawArmored = Data(base64Encoded: userPubB64, options: [.ignoreUnknownCharacters]),
              let armored = String(data: rawArmored, encoding: .utf8),
              armored.contains("BEGIN PGP")
        else { return nil }

        return armored
    }
}

private extension Data {
    init?(hexString: String) {
        let s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count % 2 == 0 else { return nil }
        var out = Data()
        out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i ..< j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        self = out
    }
}
