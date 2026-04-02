import CryptoKit
import Foundation
import Security
import argon2

enum BeamioRecoverCryptoError: Error {
    case argon2
    case aes
}

/// 对齐 `beamio.ts` 的 `hashPasswordBrowser` / `deriveAesKeyFromPassword` / `aesGcmEncryptWithStored`
/// Argon2id 经 `phc-winner-argon2` **ref** 实现（无 `opt.c` / SSE），与 `@noble/hashes` argon2id 参数一致。
enum BeamioRecoverCrypto {
    struct Argon2Stored {
        var algo: String
        var v: Int
        var m: Int
        var t: Int
        var p: Int
        var salt: String
        var hash: String
    }

    private static let defaultMemoryKib: UInt32 = 32 * 1024
    private static let defaultIterations: UInt32 = 3
    private static let defaultParallelism: UInt32 = 1
    private static let derivedKeyLength = 32
    private static let saltLength = 16

    private static func randomSalt16() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: saltLength)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BeamioRecoverCryptoError.argon2
        }
        return Data(bytes)
    }

    private static func argon2idRaw(
        password: Data,
        salt: Data,
        t: UInt32,
        memoryKib: UInt32,
        parallelism: UInt32,
        outputLength: Int
    ) throws -> Data {
        var out = [UInt8](repeating: 0, count: outputLength)
        let rc: Int32 = password.withUnsafeBytes { pwdBuf in
            salt.withUnsafeBytes { saltBuf in
                guard let pwdBase = pwdBuf.baseAddress,
                      let saltBase = saltBuf.baseAddress else { return -4 /* ARGON2_PWD_TOO_SHORT */ }
                return argon2id_hash_raw(
                    t,
                    memoryKib,
                    parallelism,
                    pwdBase,
                    pwdBuf.count,
                    saltBase,
                    saltBuf.count,
                    &out,
                    outputLength
                )
            }
        }
        guard rc == 0 /* ARGON2_OK */ else { throw BeamioRecoverCryptoError.argon2 }
        return Data(out)
    }

    static func hash_password_browser(pin: String) throws -> Argon2Stored {
        let salt = try randomSalt16()
        let derived = try argon2idRaw(
            password: Data(pin.utf8),
            salt: salt,
            t: defaultIterations,
            memoryKib: defaultMemoryKib,
            parallelism: defaultParallelism,
            outputLength: derivedKeyLength
        )
        return Argon2Stored(
            algo: "argon2id",
            v: Int(ARGON2_VERSION_13.rawValue),
            m: Int(defaultMemoryKib),
            t: Int(defaultIterations),
            p: Int(defaultParallelism),
            salt: salt.base64EncodedString(),
            hash: derived.base64EncodedString()
        )
    }

    private static func derive_aes_key(password: String, stored: Argon2Stored) throws -> SymmetricKey {
        guard let saltData = Data(base64Encoded: stored.salt) else { throw BeamioRecoverCryptoError.argon2 }
        let derived = try argon2idRaw(
            password: Data(password.utf8),
            salt: saltData,
            t: UInt32(stored.t),
            memoryKib: UInt32(stored.m),
            parallelism: UInt32(stored.p),
            outputLength: derivedKeyLength
        )
        return SymmetricKey(data: derived)
    }

    static func aes_gcm_encrypt_stored(plaintext: String, password: String, stored: Argon2Stored) throws -> String {
        let key = try derive_aes_key(password: password, stored: stored)
        var iv = [UInt8](repeating: 0, count: 12)
        guard SecRandomCopyBytes(kSecRandomDefault, iv.count, &iv) == errSecSuccess else {
            throw BeamioRecoverCryptoError.aes
        }
        let nonce = try AES.GCM.Nonce(data: Data(iv))
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key, nonce: nonce)
        var combined = Data(iv)
        combined.append(sealed.ciphertext)
        combined.append(sealed.tag)
        return combined.base64EncodedString()
    }

    static func stored_to_json_object(_ stored: Argon2Stored) -> [String: Any] {
        [
            "algo": stored.algo,
            "v": stored.v,
            "m": stored.m,
            "t": stored.t,
            "p": stored.p,
            "salt": stored.salt,
            "hash": stored.hash,
        ]
    }

    static func json_wrapper_to_base64(stored: [String: Any], img: String) throws -> String {
        let inner: [String: Any] = ["stored": stored, "img": img]
        let d = try JSONSerialization.data(withJSONObject: inner)
        return d.base64EncodedString()
    }
}
