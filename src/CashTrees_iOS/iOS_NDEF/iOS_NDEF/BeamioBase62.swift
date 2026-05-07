import Foundation

/// 与 `uuid62`（base-x 字母表）一致，用于 `generateCODE` 风格 recovery code
enum BeamioBase62 {
    static let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
    private static let alphabetMap: [UInt8: Int] = {
        var m: [UInt8: Int] = [:]
        for (i, u) in alphabet.enumerated() { m[u] = i }
        return m
    }()

    /// 与 `base-x` / `uuid62` 一致的字节 → base62
    static func encode(_ source: [UInt8]) -> String {
        guard !source.isEmpty else { return "" }
        var prefix = ""
        var k = 0
        while k < source.count - 1, source[k] == 0 {
            prefix.unicodeScalars.append(UnicodeScalar(alphabet[0]))
            k += 1
        }
        var digits: [Int] = [0]
        for u in source {
            var carry = Int(u)
            var j = 0
            while j < digits.count {
                carry += digits[j] << 8
                digits[j] = carry % 62
                carry /= 62
                j += 1
            }
            while carry > 0 {
                digits.append(carry % 62)
                carry /= 62
            }
        }
        var s = prefix
        for d in digits.reversed() {
            s.unicodeScalars.append(UnicodeScalar(alphabet[d]))
        }
        return s
    }

    static func decode(_ s: String) throws -> [UInt8] {
        guard !s.isEmpty else { return [] }
        var bytes: [UInt8] = [0]
        for ch in s.utf8 {
            guard let v = alphabetMap[ch] else {
                throw BeamioBase62Error.invalidChar
            }
            var carry = v
            for j in 0 ..< bytes.count {
                carry += Int(bytes[j]) * 62
                bytes[j] = UInt8(carry & 0xff)
                carry >>= 8
            }
            while carry > 0 {
                bytes.append(UInt8(carry & 0xff))
                carry >>= 8
            }
        }
        var zeros = 0
        for ch in s.utf8 where ch == UInt8(ascii: "0") { zeros += 1 }
        return [UInt8](repeating: 0, count: zeros) + bytes.reversed()
    }
}

enum BeamioBase62Error: Error {
    case invalidChar
}
