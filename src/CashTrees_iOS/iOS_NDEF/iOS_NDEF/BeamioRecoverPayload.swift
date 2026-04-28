import Foundation

/// 对齐 `beamio.ts` `createRecover` + `newUser` 的 `recover` 数组
enum BeamioRecoverPayload {
    struct BuildResult {
        var recover: [[String: String]]
        var recoveryCode: String
        var privateKeyHex: String
        var mnemonicPhrase: String
    }

    static func build(beamioTag: String, pin: String, mnemonicPhrase: String) throws -> BuildResult {
        let pkHex = try BeamioBIP32.ethereumPrivateKeyHexFromMnemonic(mnemonicPhrase)
        let code = BeamioUUID62.generateV4()
        let stored = try BeamioRecoverCrypto.hash_password_browser(pin: pin)
        let phraseB64 = Data(mnemonicPhrase.utf8).base64EncodedString()
        let img = try BeamioRecoverCrypto.aes_gcm_encrypt_stored(plaintext: phraseB64, password: code, stored: stored)
        let img1 = try BeamioRecoverCrypto.aes_gcm_encrypt_stored(plaintext: phraseB64, password: pin, stored: stored)
        let sto = BeamioRecoverCrypto.stored_to_json_object(stored)
        let enc0 = try BeamioRecoverCrypto.json_wrapper_to_base64(stored: sto, img: img)
        let enc1 = try BeamioRecoverCrypto.json_wrapper_to_base64(stored: sto, img: img1)
        let hash0 = BeamioEthWallet.solidityPackedKeccak256(utf8Parts: [code, ""])
        let hash1 = BeamioEthWallet.solidityPackedKeccak256(utf8Parts: [beamioTag])
        let recover: [[String: String]] = [
            ["hash": hash0, "encrypto": enc0],
            ["hash": hash1, "encrypto": enc1],
        ]
        return BuildResult(
            recover: recover,
            recoveryCode: code,
            privateKeyHex: pkHex,
            mnemonicPhrase: mnemonicPhrase
        )
    }
}
