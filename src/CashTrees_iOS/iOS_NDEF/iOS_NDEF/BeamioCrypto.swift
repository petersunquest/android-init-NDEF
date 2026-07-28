import CryptoSwift
import Foundation
import secp256k1

enum BeamioCryptoError: Error {
    case invalidPrivateKey
    case secp256k1
    case invalidHex
}

enum BeamioEthWallet {
    private static var ctxSign: OpaquePointer = {
        guard let c = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN)) else {
            fatalError("secp256k1_context_create")
        }
        return c
    }()

    static func normalizePrivateKeyHex(_ hex: String) throws -> Data {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
        guard s.count == 64, let bytes = try? s.bytesFromHex() else { throw BeamioCryptoError.invalidHex }
        let data = Data(bytes)
        guard data.count == 32 else { throw BeamioCryptoError.invalidPrivateKey }
        guard isValidSecretKey([UInt8](data)) else { throw BeamioCryptoError.invalidPrivateKey }
        return data
    }

    static func isValidSecretKey(_ secret32: [UInt8]) -> Bool {
        guard secret32.count == 32 else { return false }
        return secp256k1_ec_seckey_verify(ctxSign, secret32) == 1
    }

    /// Ethereum address `0x` + 40 hex, derived from private key (matches web3j Keys.getAddress)
    static func address(fromPrivateKeyHex hex: String) throws -> String {
        let sk = try normalizePrivateKeyHex(hex)
        var pubkey = secp256k1_pubkey()
        guard sk.withUnsafeBytes({ raw in
            secp256k1_ec_pubkey_create(ctxSign, &pubkey, raw.bindMemory(to: UInt8.self).baseAddress!)
        }) == 1 else { throw BeamioCryptoError.secp256k1 }

        var out = [UInt8](repeating: 0, count: 65)
        var outlen = 65
        guard withUnsafeMutablePointer(to: &pubkey, { pk in
            secp256k1_ec_pubkey_serialize(
                ctxSign,
                &out,
                &outlen,
                pk,
                UInt32(SECP256K1_EC_UNCOMPRESSED)
            )
        }) == 1, outlen == 65 else { throw BeamioCryptoError.secp256k1 }

        let pubNoPrefix = Data(out.dropFirst())
        let h = keccak256(pubNoPrefix)
        let addr20 = h.suffix(20)
        return "0x" + addr20.map { String(format: "%02x", $0) }.joined()
    }

    static func keccak256(_ data: Data) -> Data {
        Data([UInt8](data).sha3(.keccak256))
    }

    /// 与 `ethers.Wallet.signMessage(message)`（EIP-191）一致，供 `/api/addUser` 的 `signMessage`。
    static func signEthereumPersonalMessage(privateKeyHex: String, message: String) throws -> String {
        let sk = try normalizePrivateKeyHex(privateKeyHex)
        let msgBytes = Data(message.utf8)
        var prefixed = Data()
        prefixed.append(0x19)
        prefixed.append(Data("Ethereum Signed Message:\n".utf8))
        prefixed.append(Data(String(msgBytes.count).utf8))
        prefixed.append(msgBytes)
        let digest = keccak256(prefixed)

        var sig = secp256k1_ecdsa_recoverable_signature()
        let okSign: Int32 = sk.withUnsafeBytes { skRaw in
            digest.withUnsafeBytes { digRaw in
                secp256k1_ecdsa_sign_recoverable(
                    ctxSign,
                    &sig,
                    digRaw.bindMemory(to: UInt8.self).baseAddress!,
                    skRaw.bindMemory(to: UInt8.self).baseAddress!,
                    nil,
                    nil
                )
            }
        }
        guard okSign == 1 else { throw BeamioCryptoError.secp256k1 }

        var recid: Int32 = 0
        var compact = [UInt8](repeating: 0, count: 64)
        guard secp256k1_ecdsa_recoverable_signature_serialize_compact(ctxSign, &compact, &recid, &sig) == 1 else {
            throw BeamioCryptoError.secp256k1
        }

        let r = compact[0 ..< 32]
        let s = compact[32 ..< 64]
        let v = UInt8(recid + 27)
        return "0x" +
            r.map { String(format: "%02x", $0) }.joined() +
            s.map { String(format: "%02x", $0) }.joined() +
            String(format: "%02x", v)
    }

    /// `ethers.solidityPackedKeccak256`：参数为若干 UTF-8 字符串，按顺序直接拼接字节后 Keccak-256。
    static func solidityPackedKeccak256(utf8Parts: [String]) -> String {
        var d = Data()
        for p in utf8Parts { d.append(Data(p.utf8)) }
        let h = keccak256(d)
        return "0x" + h.map { String(format: "%02x", $0) }.joined()
    }

    /// BIP32：`seckey = seckey + tweak (mod n)`
    static func secp256k1PrivkeyTweakAdd(secret32: inout [UInt8], tweak32: [UInt8]) -> Bool {
        guard secret32.count == 32, tweak32.count == 32 else { return false }
        return secret32.withUnsafeMutableBytes { sk in
            tweak32.withUnsafeBytes { tw in
                secp256k1_ec_privkey_tweak_add(ctxSign, sk.baseAddress!, tw.baseAddress!) == 1
            }
        }
    }

    /// 压缩公钥 33 字节（BIP32 非强化子钥推导）
    static func secp256k1CompressedPubkey(secret32: [UInt8]) -> [UInt8]? {
        guard secret32.count == 32 else { return nil }
        var pubkey = secp256k1_pubkey()
        guard secp256k1_ec_pubkey_create(ctxSign, &pubkey, secret32) == 1 else { return nil }
        var out = [UInt8](repeating: 0, count: 33)
        var outlen = 33
        // `SECP256K1_EC_COMPRESSED`（0x102）— 与 libsecp256k1 一致
        let fl = secp256k1_ec_pubkey_serialize(
            ctxSign,
            &out,
            &outlen,
            &pubkey,
            UInt32(0x02 | (1 << 8))
        )
        guard fl == 1, outlen == 33 else { return nil }
        return out
    }

    /// EIP-712 `ExecuteForAdmin` — 对齐 `BeamioWeb3Wallet.signExecuteForAdmin`
    /// - Parameter verifyingContractHex: 卡链上 `factoryGateway()`；缺省时回退 `BeamioConstants.baseCardFactory`（仅限旧服务端）。
    static func signExecuteForAdmin(
        privateKeyHex: String,
        cardAddr: String,
        dataHex: String,
        deadline: UInt64,
        nonceHex: String,
        verifyingContractHex: String? = nil
    ) throws -> String {
        let sk = try normalizePrivateKeyHex(privateKeyHex)
        let dataBytes = try decodeHexData(dataHex)
        let dataHash = keccak256(dataBytes)

        var nh = nonceHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nh.hasPrefix("0x") { nh = "0x" + nh }
        let nonceWords = try abiWordsFromHex32(nh)

        let gwTrim = verifyingContractHex?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let gw = gwTrim.nilIfEmpty ?? BeamioConstants.baseCardFactory
        let domainSep = try eip712DomainSeparator(verifyingContractHex: gw)
        let structHash = try eip712ExecuteForAdminStructHash(
            cardAddress: cardAddr,
            dataHash32: dataHash,
            deadline: deadline,
            nonce32: nonceWords
        )
        var preamble = Data([0x19, 0x01])
        preamble.append(domainSep)
        preamble.append(structHash)
        let digest = keccak256(preamble)

        var sig = secp256k1_ecdsa_recoverable_signature()
        let okSign: Int32 = sk.withUnsafeBytes { skRaw in
            digest.withUnsafeBytes { digRaw in
                secp256k1_ecdsa_sign_recoverable(
                    ctxSign,
                    &sig,
                    digRaw.bindMemory(to: UInt8.self).baseAddress!,
                    skRaw.bindMemory(to: UInt8.self).baseAddress!,
                    nil,
                    nil
                )
            }
        }
        guard okSign == 1 else { throw BeamioCryptoError.secp256k1 }

        var recid: Int32 = 0
        var compact = [UInt8](repeating: 0, count: 64)
        guard secp256k1_ecdsa_recoverable_signature_serialize_compact(ctxSign, &compact, &recid, &sig) == 1 else {
            throw BeamioCryptoError.secp256k1
        }

        let r = compact[0 ..< 32]
        let s = compact[32 ..< 64]
        let v = UInt8(recid + 27)
        let sigHex =
            "0x" +
            r.map { String(format: "%02x", $0) }.joined() +
            s.map { String(format: "%02x", $0) }.joined() +
            String(format: "%02x", v)
        return sigHex
    }

    /// EIP-712 `ExecuteForOwner` signature for `/api/executeForOwner`.
    static func signExecuteForOwner(
        privateKeyHex: String,
        cardAddr: String,
        dataHex: String,
        deadline: UInt64,
        nonceHex: String,
        verifyingContractHex: String? = nil
    ) throws -> String {
        let sk = try normalizePrivateKeyHex(privateKeyHex)
        let dataBytes = try decodeHexData(dataHex)
        let dataHash = keccak256(dataBytes)

        var nh = nonceHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nh.hasPrefix("0x") { nh = "0x" + nh }
        let nonceWords = try abiWordsFromHex32(nh)

        let gwTrim = verifyingContractHex?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let gw = gwTrim.nilIfEmpty ?? BeamioConstants.baseCardFactory
        let domainSep = try eip712DomainSeparator(verifyingContractHex: gw)
        let structHash = try eip712ExecuteForOwnerStructHash(
            cardAddress: cardAddr,
            dataHash32: dataHash,
            deadline: deadline,
            nonce32: nonceWords
        )
        var preamble = Data([0x19, 0x01])
        preamble.append(domainSep)
        preamble.append(structHash)
        let digest = keccak256(preamble)

        var sig = secp256k1_ecdsa_recoverable_signature()
        let okSign: Int32 = sk.withUnsafeBytes { skRaw in
            digest.withUnsafeBytes { digRaw in
                secp256k1_ecdsa_sign_recoverable(
                    ctxSign,
                    &sig,
                    digRaw.bindMemory(to: UInt8.self).baseAddress!,
                    skRaw.bindMemory(to: UInt8.self).baseAddress!,
                    nil,
                    nil
                )
            }
        }
        guard okSign == 1 else { throw BeamioCryptoError.secp256k1 }

        var recid: Int32 = 0
        var compact = [UInt8](repeating: 0, count: 64)
        guard secp256k1_ecdsa_recoverable_signature_serialize_compact(ctxSign, &compact, &recid, &sig) == 1 else {
            throw BeamioCryptoError.secp256k1
        }

        let r = compact[0 ..< 32]
        let s = compact[32 ..< 64]
        let v = UInt8(recid + 27)
        let sigHex =
            "0x" +
            r.map { String(format: "%02x", $0) }.joined() +
            s.map { String(format: "%02x", $0) }.joined() +
            String(format: "%02x", v)
        return sigHex
    }

    private static func eip712DomainSeparator(verifyingContractHex: String) throws -> Data {
        let type =
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        let typeHash = keccak256(Data(type.utf8))
        let nameHash = keccak256(Data("BeamioUserCardFactory".utf8))
        let versionHash = keccak256(Data("1".utf8))
        var enc = Data()
        enc.append(typeHash)
        enc.append(nameHash)
        enc.append(versionHash)
        enc.append(abiUInt256(BeamioConstants.baseChainId))
        enc.append(try abiAddressWords(verifyingContractHex))
        return keccak256(enc)
    }

    private static func eip712ExecuteForAdminStructHash(
        cardAddress: String,
        dataHash32: Data,
        deadline: UInt64,
        nonce32: Data
    ) throws -> Data {
        let type = "ExecuteForAdmin(address cardAddress,bytes32 dataHash,uint256 deadline,bytes32 nonce)"
        let typeHash = keccak256(Data(type.utf8))
        var enc = Data()
        enc.append(typeHash)
        enc.append(try abiAddressWords(cardAddress))
        guard dataHash32.count == 32 else { throw BeamioCryptoError.invalidHex }
        enc.append(dataHash32)
        enc.append(abiUInt256(deadline))
        guard nonce32.count == 32 else { throw BeamioCryptoError.invalidHex }
        enc.append(nonce32)
        return keccak256(enc)
    }

    private static func eip712ExecuteForOwnerStructHash(
        cardAddress: String,
        dataHash32: Data,
        deadline: UInt64,
        nonce32: Data
    ) throws -> Data {
        let type = "ExecuteForOwner(address cardAddress,bytes32 dataHash,uint256 deadline,bytes32 nonce)"
        let typeHash = keccak256(Data(type.utf8))
        var enc = Data()
        enc.append(typeHash)
        enc.append(try abiAddressWords(cardAddress))
        guard dataHash32.count == 32 else { throw BeamioCryptoError.invalidHex }
        enc.append(dataHash32)
        enc.append(abiUInt256(deadline))
        guard nonce32.count == 32 else { throw BeamioCryptoError.invalidHex }
        enc.append(nonce32)
        return keccak256(enc)
    }

    private static func abiUInt256(_ v: UInt64) -> Data {
        var be = [UInt8](repeating: 0, count: 32)
        var x = v
        for j in 0 ..< 8 {
            be[31 - j] = UInt8(x & 0xFF)
            x >>= 8
        }
        return Data(be)
    }

    /// `0x` 地址 → 左填充 32 字节
    private static func abiAddressWords(_ addr: String) throws -> Data {
        var s = addr.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
        guard s.count == 40, let raw = try? s.bytesFromHex(), raw.count == 20 else { throw BeamioCryptoError.invalidHex }
        return Data(repeating: 0, count: 12) + Data(raw)
    }

    private static func abiWordsFromHex32(_ hex32: String) throws -> Data {
        var s = hex32.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
        guard s.count == 64, let raw = try? s.bytesFromHex(), raw.count == 32 else { throw BeamioCryptoError.invalidHex }
        return Data(raw)
    }

    private static func decodeHexData(_ hex: String) throws -> Data {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
        guard s.count % 2 == 0, let b = try? s.bytesFromHex() else { throw BeamioCryptoError.invalidHex }
        return Data(b)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func bytesFromHex() throws -> [UInt8] {
        var data = [UInt8]()
        var idx = startIndex
        while idx < endIndex {
            let next = index(idx, offsetBy: 2, limitedBy: endIndex) ?? endIndex
            let byteStr = self[idx ..< next]
            guard byteStr.count == 2, let b = UInt8(byteStr, radix: 16) else { throw BeamioCryptoError.invalidHex }
            data.append(b)
            idx = next
        }
        return data
    }
}
