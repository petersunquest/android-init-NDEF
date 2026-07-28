import Foundation

/// `ethers.getAddress` / EIP-55，用于 `signMessage(wallet.address)`
enum BeamioEIP55 {
    static func checksumAddress(lowercaseHex40: String) throws -> String {
        var s = lowercaseHex40.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard s.count == 40, s.allSatisfy({ $0.isHexDigit }) else {
            throw BeamioEIP55Error.badAddress
        }
        let h = BeamioEthWallet.keccak256(Data(s.utf8))
        let hashHex = h.map { String(format: "%02x", $0) }.joined()
        var out = "0x"
        for (i, ch) in s.enumerated() {
            guard let ascii = ch.asciiValue else { throw BeamioEIP55Error.badAddress }
            if ascii >= UInt8(ascii: "0"), ascii <= UInt8(ascii: "9") {
                out.append(ch)
                continue
            }
            // EIP-55: same index `i` into the 40-char address and into the 64-char Keccak hex string (per-nibble).
            guard i < hashHex.count else { throw BeamioEIP55Error.badAddress }
            let hashIdx = hashHex.index(hashHex.startIndex, offsetBy: i)
            guard let nib = UInt8(String(hashHex[hashIdx]), radix: 16) else {
                throw BeamioEIP55Error.badAddress
            }
            if nib >= 8 {
                out.append(Character(UnicodeScalar(ascii - 32)))
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

enum BeamioEIP55Error: Error {
    case badAddress
}
