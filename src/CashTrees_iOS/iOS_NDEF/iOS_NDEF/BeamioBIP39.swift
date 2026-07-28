import CryptoSwift
import Foundation
import Security

enum BeamioBIP39Error: Error {
    case missingWordlist
    case badWordlist
    case random
    case checksum
}

/// BIP-39：12 词英文助记词 + PBKDF2(seed)，与 `ethers.HDNodeWallet.fromPhrase` / `createOrGetWallet` 兼容
enum BeamioBIP39 {
    private static var cachedWords: [String]?

    private static func loadWords() throws -> [String] {
        if let c = cachedWords { return c }
        guard let url = Bundle.main.url(forResource: "bip39-english", withExtension: "txt") else {
            throw BeamioBIP39Error.missingWordlist
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let words = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard words.count == 2048 else { throw BeamioBIP39Error.badWordlist }
        cachedWords = words
        return words
    }

    /// 128-bit 熵 → 12 个词
    static func generateMnemonic12() throws -> String {
        let words = try loadWords()
        var entropy = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, entropy.count, &entropy) == errSecSuccess else {
            throw BeamioBIP39Error.random
        }
        let h = SHA2(variant: .sha256).calculate(for: entropy)
        var bits: [Bool] = []
        for b in entropy {
            for i in (0 ..< 8).reversed() {
                bits.append((b >> UInt8(i)) & 1 == 1)
            }
        }
        for i in 0 ..< 4 {
            bits.append((h[0] >> UInt8(7 - i)) & 1 == 1)
        }
        guard bits.count == 132 else { throw BeamioBIP39Error.checksum }
        var chosen: [String] = []
        for g in 0 ..< 12 {
            var idx = 0
            for b in 0 ..< 11 {
                idx = (idx << 1) + (bits[g * 11 + b] ? 1 : 0)
            }
            chosen.append(words[idx])
        }
        return chosen.joined(separator: " ")
    }

    /// BIP39 seed（64 字节）；passphrase 为 BIP39 扩展口令（通常 `""`）。英文词表下 NFKD 与 UTF-8 一致。
    static func seedBytes(mnemonicPhrase: String, passphrase: String = "") throws -> Data {
        let phrase = mnemonicPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let salt = Data(("mnemonic" + passphrase).utf8)
        let pwd = Data(phrase.utf8)
        let pbkdf2 = try PKCS5.PBKDF2(
            password: [UInt8](pwd),
            salt: [UInt8](salt),
            iterations: 2048,
            keyLength: 64,
            variant: .sha2(.sha512)
        )
        return Data(try pbkdf2.calculate())
    }
}
