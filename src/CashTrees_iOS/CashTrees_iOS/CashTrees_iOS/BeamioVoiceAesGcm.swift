import Foundation
import CryptoKit

/// AES-256-GCM frame crypto matching PWA `encryptVoiceFrame` /
/// `decryptVoiceFrame`: nonce(12) ‖ ciphertext‖tag → standard base64. No AAD.
enum BeamioVoiceAesGcm {
	enum Error: Swift.Error {
		case invalidKey
		case encryptFailed
		case decryptFailed
		case frameTooShort
	}

	/// `sessionKey` is the offer's base64-encoded 32-byte key.
	static func keyFromBase64(_ value: String) throws -> SymmetricKey {
		guard let data = Data(base64Encoded: value.trimmingCharacters(in: .whitespacesAndNewlines)),
		      data.count == 32
		else { throw Error.invalidKey }
		return SymmetricKey(data: data)
	}

	static func encrypt(key: SymmetricKey, plain: Data) throws -> String {
		let nonce = AES.GCM.Nonce()
		guard let sealed = try? AES.GCM.seal(plain, using: key, nonce: nonce) else {
			throw Error.encryptFailed
		}
		// CryptoKit Combined = nonce ‖ ciphertext ‖ tag (same layout as Web Crypto).
		guard let combined = sealed.combined else { throw Error.encryptFailed }
		return combined.base64EncodedString()
	}

	static func encryptUtf8Json(keyBase64: String, jsonObject: [String: Any]) throws -> String {
		let key = try keyFromBase64(keyBase64)
		guard let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: []),
		      let _ = String(data: data, encoding: .utf8)
		else { throw Error.encryptFailed }
		return try encrypt(key: key, plain: data)
	}

	static func decrypt(key: SymmetricKey, payloadBase64: String) throws -> Data {
		guard let packed = Data(base64Encoded: payloadBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
		      packed.count >= 28
		else { throw Error.frameTooShort }
		guard let box = try? AES.GCM.SealedBox(combined: packed),
		      let plain = try? AES.GCM.open(box, using: key)
		else { throw Error.decryptFailed }
		return plain
	}
}
