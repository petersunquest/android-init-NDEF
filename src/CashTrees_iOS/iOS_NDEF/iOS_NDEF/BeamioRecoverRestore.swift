import Foundation

/// Decode on-chain recover blob — `beamio.ts` `decodeRecoverStoragePayload(fromBase64(...))`.
enum BeamioRecoverRestore {
    struct StoragePayload {
        var stored: BeamioRecoverCrypto.Argon2Stored
        var img: String
    }

    /// Contract returns a base64 string of JSON `{ "stored": Argon2idHash, "img": "<aes ciphertext b64>" }`.
    static func decodeStoragePayload(outerBase64: String) -> StoragePayload? {
        let trimmed = outerBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = Data(base64Encoded: trimmed),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let img = obj["img"] as? String,
              let storedDict = obj["stored"] as? [String: Any],
              let stored = BeamioRecoverCrypto.Argon2Stored(json: storedDict)
        else { return nil }
        return StoragePayload(stored: stored, img: img)
    }
}
