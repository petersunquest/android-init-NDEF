import Foundation
import CryptoKit
import ObjectivePGP
import Security

/// Parity with bizSite `chat.ts` `initChat` + `regiestChatRoute`: register sender PGP on AddressPGP so `getKeysFromCoNETPGPSC(sender)` returns `publicArmored` and `App.tsx` can open a new chat thread.
enum BeamioConetChatRouteRegister {
    private static func conetEthCall(to: String, dataHex: String) async -> String? {
        let toLower = to.hasPrefix("0x") ? to.lowercased() : "0x\(to.lowercased())"
        let data = dataHex.hasPrefix("0x") ? dataHex.lowercased() : "0x\(dataHex.lowercased())"
        guard let url = URL(string: BeamioConstants.conetMainnetRpcUrl) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 25
        let payload: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "eth_call",
            "params": [["to": toLower, "data": data], "latest"],
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (raw, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return nil }
            guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  root["error"] == nil,
                  let result = root["result"] as? String,
                  result.hasPrefix("0x"), result.count > 2
            else { return nil }
            return result
        } catch {
            return nil
        }
    }

    /// Same as bizSite `aesGcmEncrypt` (`beamio.ts`): SHA-256(password), AES-GCM, IV 12 bytes prepended, then ciphertext+tag; result base64.
    private static func aesGcmEncryptBeamioStyle(plaintext: String, password: String) throws -> String {
        let pwData = Data(password.utf8)
        let digest = SHA256.hash(data: pwData)
        let symKey = SymmetricKey(data: Data(digest))
        var iv = Data(count: 12)
        let st = iv.withUnsafeMutableBytes { buf -> OSStatus in
            guard let base = buf.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, 12, base)
        }
        guard st == errSecSuccess else {
            throw NSError(domain: "BeamioConetChatRouteRegister", code: 1, userInfo: [NSLocalizedDescriptionKey: "IV random failed"])
        }
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: symKey, nonce: nonce)
        var combined = Data()
        combined.append(iv)
        combined.append(sealed.ciphertext)
        combined.append(sealed.tag)
        return combined.base64EncodedString()
    }

    /// `toBase64` parity with bizSite `beamio.ts` (UTF-8 → binary string → base64).
    private static func beamioToBase64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    private static func randomRouteDomainHex() -> String {
        [
            "9977E9A45187DD80", "B4CB0A41352E9BDF", "20AB90FE82D0E9E3", "AE85A2AEEC768225",
            "2CC183B62F2223FD", "221B4F18389D6AAD", "D9ADB0E1E4F342D9", "94FD3DBABD9819C2",
        ].randomElement() ?? "9977E9A45187DD80"
    }

    private static func hasOnChainUserPgpPublic(walletLower0x: String) async -> Bool {
        var h = walletLower0x.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasPrefix("0x") { h.removeFirst(2) }
        guard h.count == 40 else { return false }
        guard let dataHex = BeamioConetSearchKeyAbi.encodeSearchKeyCall(recipientEoa: h) else { return false }
        guard let hex = await conetEthCall(to: BeamioConstants.conetAddressPgpManager, dataHex: dataHex) else { return false }
        return BeamioConetSearchKeyAbi.decodeSearchKeyUserPublicArmored(hex: hex) != nil
    }

    private static func postRegiestChatRoute(
        walletChecksummed: String,
        keyIDUpperHex: String,
        publicKeyArmoredUtf8: String,
        secretKeyArmoredUtf8: String,
        walletPrivateKeyForAesPassword: String,
        routeKeyID: String
    ) async -> Bool {
        let enc: String
        do {
            enc = try aesGcmEncryptBeamioStyle(plaintext: secretKeyArmoredUtf8, password: walletPrivateKeyForAesPassword)
        } catch {
            return false
        }
        let body: [String: Any] = [
            "wallet": walletChecksummed,
            "keyID": keyIDUpperHex,
            "publicKeyArmored": beamioToBase64(publicKeyArmoredUtf8),
            "encrypKeyArmored": enc,
            "routeKeyID": routeKeyID,
        ]
        guard let url = URL(string: "\(BeamioConstants.beamioApi)/api/regiestChatRoute") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 45
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return false }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return (json["ok"] as? Bool) == true
        } catch {
            return false
        }
    }

    /// Ed25519 primary + Curve25519 ECDH subkey (ObjectivePGP `generateFor` when algorithm is EdDSA), same family as bizSite `openpgp.generateKey` `{ type: 'ecc', curve: 'curve25519' }` stack.
    private static func generateEdEccKeyPair(userID: String) throws -> (pubArmor: String, secArmor: String, subkeyIdHexUpper: String) {
        let gen = KeyGenerator(
            algorithm: .edDSA,
            keyBitsLength: 0,
            cipherAlgorithm: PGPSymmetricAlgorithm.AES256,
            hashAlgorithm: PGPHashAlgorithm.SHA512
        )
        let key = gen.generate(for: userID, passphrase: "")
        let pubData = try key.export(keyType: PGPKeyType.public)
        let secData = try key.export(keyType: PGPKeyType.secret)
        let pubArmor = Armor.armored(pubData, as: PGPArmorType.publicKey)
        let secArmor = Armor.armored(secData, as: PGPArmorType.secretKey)
        let subId = key.publicKey?.subKeys.first?.keyID.longIdentifier ?? key.keyID.longIdentifier
        let subUpper = subId.uppercased()
        return (pubArmor, secArmor, subUpper)
    }

    /// Call before `BeamioConetGossipSend.sendTerminalPermissionRequest` so web `addNewMessage` can `getKeysFromCoNETPGPSC(signAddr, ...)`.
    static func ensureRegisteredForSenderGossip(walletPrivateKeyHex: String) async -> Bool {
        var pk = walletPrivateKeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if pk.hasPrefix("0x") || pk.hasPrefix("0X") { pk.removeFirst(2) }
        guard pk.count == 64, pk.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else { return false }
        let pkWith0x = "0x" + pk.lowercased()
        let addrLower: String
        do {
            addrLower = try BeamioEthWallet.address(fromPrivateKeyHex: pkWith0x)
        } catch {
            return false
        }
        if await hasOnChainUserPgpPublic(walletLower0x: addrLower) {
            return true
        }
        let checksummed: String
        do {
            checksummed = try BeamioEIP55.checksumAddress(lowercaseHex40: String(addrLower.dropFirst(2)))
        } catch {
            return false
        }
        let userIdForPgp = checksummed
        let keys: (pubArmor: String, secArmor: String, subkeyIdHexUpper: String)
        do {
            keys = try generateEdEccKeyPair(userID: userIdForPgp)
        } catch {
            return false
        }
        let route = randomRouteDomainHex()
        let ok = await postRegiestChatRoute(
            walletChecksummed: checksummed,
            keyIDUpperHex: keys.subkeyIdHexUpper,
            publicKeyArmoredUtf8: keys.pubArmor,
            secretKeyArmoredUtf8: keys.secArmor,
            walletPrivateKeyForAesPassword: pkWith0x,
            routeKeyID: route
        )
        if !ok { return false }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return await hasOnChainUserPgpPublic(walletLower0x: addrLower)
    }
}
