import Foundation
import Security

/// 对齐 `uuid62.v4()`：`uuid.v4` 16 字节随机 → base62，左侧补 `0` 至长度 22
enum BeamioUUID62 {
    private static let outputLength = 22

    static func generateV4() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        setV4VersionAndVariant(&bytes)
        let enc = BeamioBase62.encode(bytes)
        let padded = String(repeating: "0", count: 32) + enc
        return String(padded.suffix(outputLength))
    }

    private static func setV4VersionAndVariant(_ id: inout [UInt8]) {
        id[6] = (id[6] & 0x0f) | 0x40
        id[8] = (id[8] & 0x3f) | 0x80
    }
}
