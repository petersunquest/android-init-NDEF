import Foundation
import ObjectivePGP

/// CoNET gossip `POST https://{domain}.conet.network/post` — message shape matches SilentPassUI `services/chat.ts` `sendMessage`.
/// Uses [ObjectivePGP](https://github.com/krzyzanowskim/ObjectivePGP) (see its license for commercial use).
enum BeamioConetGossipSend {
    /// `getAllNodes(0, n)[i].PGPKey` domain segment (16-hex), refreshed from Conet GuardianNodesInfoV6 periodically in repo scripts.
    private static let gossipPostDomainHexIds: [String] = [
        "9977E9A45187DD80", "B4CB0A41352E9BDF", "20AB90FE82D0E9E3", "AE85A2AEEC768225",
        "2CC183B62F2223FD", "221B4F18389D6AAD", "D9ADB0E1E4F342D9", "94FD3DBABD9819C2",
        "810DFC165FC60B63", "274E663C521F4889", "DED9FAA490248805", "F8117E1568EEAED7",
        "EFF609F7062B78D3", "D98C66B8211048D4", "9C0E4F8A7542CD02", "BB79725DF3CDC2BF",
        "AC27967AA3D69FF6", "DCD8C3D278AB48CB", "BB64E2DB230F4EA3", "1FDE43C9C8225B30",
        "896E1EEA0B7A5B6F", "B2F2F581BB2548E0", "2D662019CBD8EFFD", "81B39FE096AFD227",
    ]

    private static func randomPostDomains(count: Int) -> [String] {
        let n = min(count, gossipPostDomainHexIds.count)
        return Array(gossipPostDomainHexIds.shuffled().prefix(n))
    }

    private static func conetEthCall(to: String, dataHex: String) async -> String? {
        let toLower = to.hasPrefix("0x") ? to.lowercased() : "0x\(to.lowercased())"
        let data = dataHex.hasPrefix("0x") ? dataHex.lowercased() : "0x\(dataHex.lowercased())"
        guard let url = URL(string: BeamioConstants.conetMainnetRpcUrl) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 12
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

    /// `searchKey` → recipient armored public key (after base64 field decode).
    private static func fetchRecipientPublicArmored(recipientEoa: String) async -> String? {
        var h = recipientEoa.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasPrefix("0x") { h.removeFirst(2) }
        guard let dataHex = BeamioConetSearchKeyAbi.encodeSearchKeyCall(recipientEoa: h) else { return nil }
        guard let hex = await conetEthCall(to: BeamioConstants.conetAddressPgpManager, dataHex: dataHex) else { return nil }
        return BeamioConetSearchKeyAbi.decodeSearchKeyUserPublicArmored(hex: hex)
    }

    /// SilentPassUI `sendMessage`: EIP-191 sign **outer chat line** `text`, envelope `{ timestamp, text, from, signMessage }`, OpenPGP encrypt **UTF-8 of base64(JSON.stringify(envelope))**, POST `{ data: armored }`.
    static func sendTerminalPermissionRequest(
        recipientEoa: String,
        childEoa: String,
        childBeamioTag: String,
        parentBeamioTag: String,
        walletPrivateKeyHex: String
    ) async -> Bool {
        guard let armoredPub = await fetchRecipientPublicArmored(recipientEoa: recipientEoa) else { return false }
        guard let pubData = armoredPub.data(using: .utf8) else { return false }
        let keys: [Key]
        do {
            keys = try ObjectivePGP.readKeys(from: pubData)
        } catch {
            return false
        }
        guard !keys.isEmpty else { return false }

        let sendId = UUID().uuidString.lowercased()
        let createdAt = Int64(Date().timeIntervalSince1970 * 1000)
        let innerText = Self.jsonTerminalPermissionInner(sendId: sendId, createdAt: createdAt, childEoa: childEoa, childBeamioTag: childBeamioTag, parentBeamioTag: parentBeamioTag)
        let outerLine = Self.jsonChatOuterLine(sendId: sendId, createdAt: createdAt, innerText: innerText)

        let signMessage: String
        do {
            signMessage = try BeamioEthWallet.signEthereumPersonalMessage(privateKeyHex: walletPrivateKeyHex, message: outerLine)
        } catch {
            return false
        }

        let tsMs = Int64(Date().timeIntervalSince1970 * 1000)
        let envelope: [String: Any] = [
            "timestamp": tsMs,
            "text": outerLine,
            "from": childEoa.lowercased(),
            "signMessage": signMessage,
        ]
        guard let envData = try? JSONSerialization.data(withJSONObject: envelope, options: []),
              let envJson = String(data: envData, encoding: .utf8)
        else { return false }

        let b64 = Data(envJson.utf8).base64EncodedString()
        guard let literal = b64.data(using: .utf8) else { return false }

        let encryptedBin: Data
        do {
            encryptedBin = try ObjectivePGP.encrypt(literal, addSignature: false, using: keys, passphraseForKey: nil)
        } catch {
            return false
        }

        let armoredCipher = Armor.armored(encryptedBin, as: PGPArmorType.message)

        let domains = randomPostDomains(count: 2)
        guard !domains.isEmpty else { return false }

        var anyOk = false
        await withTaskGroup(of: Bool.self) { group in
            for d in domains {
                group.addTask {
                    await postGossipPayload(domainHex: d, armored: armoredCipher)
                }
            }
            for await ok in group {
                if ok { anyOk = true }
            }
        }
        return anyOk
    }

    private static func postGossipPayload(domainHex: String, armored: String) async -> Bool {
        let urlStr = "https://\(domainHex).conet.network/post"
        guard let url = URL(string: urlStr) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 12
        let body: [String: Any] = ["data": armored]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return false }
        req.httpBody = httpBody
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            return (200 ... 299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// Machine-readable line inside SilentPassUI-style `text` (UTF-8 JSON).
    private static func jsonTerminalPermissionInner(
        sendId: String,
        createdAt: Int64,
        childEoa: String,
        childBeamioTag: String,
        parentBeamioTag: String
    ) -> String {
        let o: [String: Any] = [
            "type": "beamio_pos_terminal_permission_v1",
            "sendId": sendId,
            "createdAt": createdAt,
            "childEoa": childEoa.lowercased(),
            "childBeamioTag": childBeamioTag,
            "parentBeamioTag": parentBeamioTag,
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: []),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Same shape as `chat.tsx` pending message JSON passed to `sendMessage` as `text`.
    private static func jsonChatOuterLine(sendId: String, createdAt: Int64, innerText: String) -> String {
        let o: [String: Any] = [
            "sendId": sendId,
            "from": "me",
            "text": innerText,
            "createdAt": createdAt,
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: []),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}
