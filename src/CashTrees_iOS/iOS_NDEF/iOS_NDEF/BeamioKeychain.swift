import Foundation
import Security

enum BeamioKeychain {
    private static let service = "com.beamio.iosndef.wallet.privatekey"

    static func loadPrivateKeyHex() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data,
              let s = String(data: data, encoding: .utf8)?.nilIfEmpty
        else { return nil }
        return s
    }

    static func savePrivateKeyHex(_ hex: String) throws {
        try deletePrivateKey()
        guard let data = hex.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            throw NSError(domain: "BeamioKeychain", code: 1)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: "BeamioKeychain", code: Int(status)) }
    }

    static func deletePrivateKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
