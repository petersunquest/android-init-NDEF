import CryptoSwift
import Foundation

enum BeamioBIP32Error: Error {
    case derive
    case badMaster
}

/// BIP32：默认路径 `m/44'/60'/0'/0/0`（与 `HDNodeWallet.fromPhrase` 一致）
enum BeamioBIP32 {
    struct ExtendedKey {
        var privateKey: [UInt8]
        var chainCode: [UInt8]
    }

    private static func hmacSha512(key: Data, data: Data) throws -> Data {
        let h = HMAC(key: [UInt8](key), variant: .sha2(.sha512))
        return Data(try h.authenticate([UInt8](data)))
    }

    private static func ser32BE(_ i: UInt32) -> Data {
        var v = i
        var b = [UInt8](repeating: 0, count: 4)
        b[0] = UInt8((v >> 24) & 0xff)
        b[1] = UInt8((v >> 16) & 0xff)
        b[2] = UInt8((v >> 8) & 0xff)
        b[3] = UInt8(v & 0xff)
        return Data(b)
    }

    static func master(fromSeed seed: Data) throws -> ExtendedKey {
        let I = try hmacSha512(key: Data("Bitcoin seed".utf8), data: seed)
        guard I.count == 64 else { throw BeamioBIP32Error.badMaster }
        let il = Array(I[0 ..< 32])
        let ir = Array(I[32 ..< 64])
        guard BeamioEthWallet.isValidSecretKey(il) else { throw BeamioBIP32Error.badMaster }
        return ExtendedKey(privateKey: il, chainCode: ir)
    }

    static func derivePrivateKey(parent: ExtendedKey, childIndex: UInt32, hardened: Bool) throws -> ExtendedKey {
        var data = Data()
        if hardened {
            data.append(0x00)
            data.append(contentsOf: parent.privateKey)
        } else {
            guard let pub = BeamioEthWallet.secp256k1CompressedPubkey(secret32: parent.privateKey) else {
                throw BeamioBIP32Error.derive
            }
            data.append(contentsOf: pub)
        }
        var idx = childIndex
        if hardened { idx |= 0x8000_0000 }
        data.append(ser32BE(idx))
        let I = try hmacSha512(key: Data(parent.chainCode), data: data)
        let il = Array(I[0 ..< 32])
        let ir = Array(I[32 ..< 64])
        var childPriv = parent.privateKey
        guard BeamioEthWallet.secp256k1PrivkeyTweakAdd(secret32: &childPriv, tweak32: il),
              BeamioEthWallet.isValidSecretKey(childPriv)
        else { throw BeamioBIP32Error.derive }
        return ExtendedKey(privateKey: childPriv, chainCode: ir)
    }

    /// 返回 64 hex 私钥（无 `0x`），与 `Wallet` 私钥格式一致
    static func ethereumPrivateKeyHexFromMnemonic(_ phrase: String) throws -> String {
        let seed = try BeamioBIP39.seedBytes(mnemonicPhrase: phrase)
        var k = try master(fromSeed: seed)
        k = try derivePrivateKey(parent: k, childIndex: 44, hardened: true)
        k = try derivePrivateKey(parent: k, childIndex: 60, hardened: true)
        k = try derivePrivateKey(parent: k, childIndex: 0, hardened: true)
        k = try derivePrivateKey(parent: k, childIndex: 0, hardened: false)
        k = try derivePrivateKey(parent: k, childIndex: 0, hardened: false)
        return k.privateKey.map { String(format: "%02x", $0) }.joined()
    }
}
