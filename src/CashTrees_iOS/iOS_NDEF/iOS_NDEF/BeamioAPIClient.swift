import Foundation

enum BeamioAPIError: Error {
    case badResponse(Int)
    case decode
}

final class BeamioAPIClient: @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Helpers

    private func postJson(path: String, body: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        let url = URL(string: BeamioConstants.beamioApi + path)!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = timeout
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BeamioAPIError.decode }
        guard (200 ... 299).contains(http.statusCode) else { throw BeamioAPIError.badResponse(http.statusCode) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BeamioAPIError.decode }
        return obj
    }

    private func postJsonAllowErrorBody(path: String, body: [String: Any], timeout: TimeInterval = 90) async throws -> (code: Int, json: [String: Any]?) {
        let url = URL(string: BeamioConstants.beamioApi + path)!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BeamioAPIError.decode }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (http.statusCode, obj)
    }

    private func getJson(path: String, timeout: TimeInterval = 15) async throws -> [String: Any] {
        let url = URL(string: BeamioConstants.beamioApi + path)!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = timeout
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BeamioAPIError.decode }
        guard (200 ... 299).contains(http.statusCode) else { throw BeamioAPIError.badResponse(http.statusCode) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BeamioAPIError.decode }
        return obj
    }

    // MARK: - POS infra

    func fetchMyPosAddress(wallet: String) async -> String? {
        let enc = wallet.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? wallet
        guard let url = URL(string: "\(BeamioConstants.beamioApi)/api/myPosAddress?wallet=\(enc)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return nil }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (root["ok"] as? Bool) == true
            else { return nil }
            let addr = (root["cardAddress"] as? String)?.nilIfEmpty ?? (root["myPosAddress"] as? String)?.nilIfEmpty
            return addr
        } catch {
            return nil
        }
    }

    // MARK: - Assets

    func getUIDAssets(uid: String, sun: SunParams?, merchantInfraCard: String, merchantInfraOnly: Bool) async -> UIDAssets {
        let (a, _) = await getUIDAssetsWithRawJson(uid: uid, sun: sun, merchantInfraCard: merchantInfraCard, merchantInfraOnly: merchantInfraOnly)
        return a
    }

    /// Same as `getUIDAssets` but includes pretty-printed JSON for Balance Loaded debug panel (align Android `ReadScreen`).
    func getUIDAssetsWithRawJson(uid: String, sun: SunParams?, merchantInfraCard: String, merchantInfraOnly: Bool) async -> (UIDAssets, String?) {
        var body: [String: Any] = [
            "uid": uid,
            "merchantInfraCard": merchantInfraCard,
        ]
        if merchantInfraOnly { body["merchantInfraOnly"] = true }
        if let sun {
            body["e"] = sun.e
            body["c"] = sun.c
            body["m"] = sun.m
        }
        do {
            let obj = try await postJson(path: "/api/getUIDAssets", body: body, timeout: 15)
            let raw = Self.prettyPrintedJsonString(from: obj)
            return (BeamioUIDAssetsParser.parse(root: obj), raw)
        } catch {
            return (UIDAssets(ok: false, error: error.localizedDescription), nil)
        }
    }

    func getWalletAssets(wallet: String, merchantInfraCard: String, merchantInfraOnly: Bool, forPostPayment: Bool) async -> UIDAssets {
        let (a, _) = await getWalletAssetsWithRawJson(wallet: wallet, merchantInfraCard: merchantInfraCard, merchantInfraOnly: merchantInfraOnly, forPostPayment: forPostPayment)
        return a
    }

    func getWalletAssetsWithRawJson(wallet: String, merchantInfraCard: String, merchantInfraOnly: Bool, forPostPayment: Bool) async -> (UIDAssets, String?) {
        var body: [String: Any] = [
            "wallet": wallet,
            "merchantInfraCard": merchantInfraCard,
        ]
        if merchantInfraOnly { body["merchantInfraOnly"] = true }
        if forPostPayment { body["for"] = "postPaymentBalance" }
        do {
            let obj = try await postJson(path: "/api/getWalletAssets", body: body, timeout: 15)
            let raw = Self.prettyPrintedJsonString(from: obj)
            return (BeamioUIDAssetsParser.parse(root: obj), raw)
        } catch {
            return (UIDAssets(ok: false, error: error.localizedDescription), nil)
        }
    }

    private static func prettyPrintedJsonString(from obj: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func ensureAAForEOA(eoa: String) async -> Bool {
        let enc = eoa.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? eoa
        guard let url = URL(string: "\(BeamioConstants.beamioApi)/api/ensureAAForEOA?eoa=\(enc)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 120
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return false }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            let aa = (root["aa"] as? String)?.nilIfEmpty
            return aa != nil
        } catch {
            return false
        }
    }

    // MARK: - Oracle

    struct OracleRates {
        var usdcad: Double = 1.35
        var usdeur: Double = 0.92
        var usdjpy: Double = 150
        var usdcny: Double = 7.2
        var usdhkd: Double = 7.8
        var usdsgd: Double = 1.35
        var usdtwd: Double = 31
    }

    func fetchOracle() async -> OracleRates {
        do {
            let root = try await getJson(path: "/api/getOracle", timeout: 8)
            func rate(_ k: String, _ d: Double) -> Double {
                (root[k] as? String).flatMap(Double.init) ?? d
            }
            return OracleRates(
                usdcad: rate("usdcad", 1.35),
                usdeur: rate("usdeur", 0.92),
                usdjpy: rate("usdjpy", 150),
                usdcny: rate("usdcny", 7.2),
                usdhkd: rate("usdhkd", 7.8),
                usdsgd: rate("usdsgd", 1.35),
                usdtwd: rate("usdtwd", 31)
            )
        } catch {
            return OracleRates()
        }
    }

    // MARK: - Top-up

    struct NfcTopupPrepareResult {
        var cardAddr: String?
        var data: String?
        var deadline: UInt64?
        var nonce: String?
        var wallet: String?
        var error: String?
    }

    func nfcTopupPrepare(
        uid: String?,
        wallet: String?,
        beamioTag: String?,
        amount: String,
        sun: SunParams?,
        infraCard: String
    ) async -> NfcTopupPrepareResult {
        var body: [String: Any] = [
            "amount": amount,
            "currency": "CAD",
            "cardAddress": infraCard,
            "workflow": "adminTopup",
            "topupMode": "admin",
        ]
        if let uid { body["uid"] = uid }
        if let wallet { body["wallet"] = wallet }
        if let beamioTag { body["beamioTag"] = beamioTag }
        if let sun {
            body["e"] = sun.e
            body["c"] = sun.c
            body["m"] = sun.m
        }
        do {
            let (code, obj) = try await postJsonAllowErrorBody(path: "/api/nfcTopupPrepare", body: body, timeout: 20)
            guard let obj else {
                return NfcTopupPrepareResult(error: "API response error (HTTP \(code))")
            }
            if let err = (obj["error"] as? String)?.nilIfEmpty {
                return NfcTopupPrepareResult(error: err)
            }
            let dl = (obj["deadline"] as? NSNumber)?.uint64Value
                ?? UInt64((obj["deadline"] as? String) ?? "") ?? 0
            return NfcTopupPrepareResult(
                cardAddr: (obj["cardAddr"] as? String)?.nilIfEmpty,
                data: (obj["data"] as? String)?.nilIfEmpty,
                deadline: dl > 0 ? dl : nil,
                nonce: (obj["nonce"] as? String)?.nilIfEmpty,
                wallet: (obj["wallet"] as? String)?.nilIfEmpty,
                error: nil
            )
        } catch {
            return NfcTopupPrepareResult(error: error.localizedDescription)
        }
    }

    struct SimpleTxResult {
        var success: Bool
        var txHash: String?
        var error: String?
    }

    func nfcTopup(
        uid: String?,
        wallet: String?,
        cardAddr: String,
        data: String,
        deadline: UInt64,
        nonce: String,
        adminSignature: String,
        sun: SunParams?
    ) async -> SimpleTxResult {
        var body: [String: Any] = [
            "cardAddr": cardAddr,
            "data": data,
            "deadline": deadline,
            "nonce": nonce,
            "adminSignature": adminSignature,
            "workflow": "adminTopup",
            "topupMode": "admin",
        ]
        if let uid { body["uid"] = uid }
        if let wallet { body["wallet"] = wallet }
        if let sun {
            body["e"] = sun.e
            body["c"] = sun.c
            body["m"] = sun.m
        }
        do {
            let (code, obj) = try await postJsonAllowErrorBody(path: "/api/nfcTopup", body: body, timeout: 120)
            guard let obj else {
                return SimpleTxResult(success: false, txHash: nil, error: "HTTP \(code)")
            }
            let ok = (200 ... 299).contains(code) && ((obj["success"] as? Bool) ?? true)
            return SimpleTxResult(
                success: ok,
                txHash: (obj["txHash"] as? String)?.nilIfEmpty,
                error: (obj["error"] as? String)?.nilIfEmpty
            )
        } catch {
            return SimpleTxResult(success: false, txHash: nil, error: error.localizedDescription)
        }
    }

    // MARK: - Link App

    struct LinkAppResult {
        var success: Bool
        var deepLinkUrl: String?
        var error: String?
        var errorCode: String?
    }

    func postNfcLinkApp(sun: SunParams, infraCard: String) async -> LinkAppResult {
        let body: [String: Any] = [
            "uid": sun.uid,
            "e": sun.e,
            "c": sun.c,
            "m": sun.m,
            "cardAddress": infraCard,
        ]
        do {
            let (code, obj) = try await postJsonAllowErrorBody(path: "/api/nfcLinkApp", body: body, timeout: 120)
            let root = obj ?? [:]
            let okBody = (root["success"] as? Bool) ?? false
            let deep = (root["deepLinkUrl"] as? String)?.nilIfEmpty
            let err = (root["error"] as? String)?.nilIfEmpty
            let errCode = (root["errorCode"] as? String)?.nilIfEmpty
            let httpOk = (200 ... 299).contains(code)
            let ok = httpOk && okBody && deep != nil
            return LinkAppResult(
                success: ok,
                deepLinkUrl: deep,
                error: err ?? (!httpOk || !okBody ? "Request failed (HTTP \(code))" : nil),
                errorCode: errCode
            )
        } catch {
            return LinkAppResult(success: false, deepLinkUrl: nil, error: error.localizedDescription, errorCode: nil)
        }
    }

    func postNfcLinkAppCancel(sun: SunParams) async -> SimpleTxResult {
        let body: [String: Any] = [
            "uid": sun.uid,
            "e": sun.e,
            "c": sun.c,
            "m": sun.m,
        ]
        do {
            let (code, obj) = try await postJsonAllowErrorBody(path: "/api/nfcLinkAppCancel", body: body, timeout: 120)
            guard let obj else { return SimpleTxResult(success: false, txHash: nil, error: "HTTP \(code)") }
            let ok = (200 ... 299).contains(code) && ((obj["success"] as? Bool) ?? false)
            return SimpleTxResult(success: ok, txHash: nil, error: (obj["error"] as? String)?.nilIfEmpty)
        } catch {
            return SimpleTxResult(success: false, txHash: nil, error: error.localizedDescription)
        }
    }

    // MARK: - Payment (NFC container)

    func payByNfcUidPrepare(uid: String, payee: String, amountUsdc6: String, sun: SunParams?) async -> [String: Any] {
        var body: [String: Any] = [
            "uid": uid,
            "payee": payee,
            "amountUsdc6": amountUsdc6,
        ]
        if let sun {
            body["e"] = sun.e
            body["c"] = sun.c
            body["m"] = sun.m
        }
        do {
            let (code, obj) = try await postJsonAllowErrorBody(path: "/api/payByNfcUidPrepare", body: body, timeout: 20)
            var merged = obj ?? [:]
            merged["_httpCode"] = code
            return merged
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    func payByNfcUidSignContainer(
        uid: String,
        containerPayload: [String: Any],
        amountUsdc6: String,
        sun: SunParams?,
        nfcBill: [String: Any]
    ) async -> SimpleTxResult {
        var body: [String: Any] = [
            "uid": uid,
            "containerPayload": containerPayload,
            "amountUsdc6": amountUsdc6,
        ]
        if let sun {
            body["e"] = sun.e
            body["c"] = sun.c
            body["m"] = sun.m
        }
        for (k, v) in nfcBill { body[k] = v }
        do {
            let (code, obj) = try await postJsonAllowErrorBody(path: "/api/payByNfcUidSignContainer", body: body, timeout: 120)
            guard let obj else { return SimpleTxResult(success: false, txHash: nil, error: "HTTP \(code)") }
            let ok = (200 ... 299).contains(code) && ((obj["success"] as? Bool) ?? true)
            return SimpleTxResult(
                success: ok,
                txHash: (obj["USDC_tx"] as? String)?.nilIfEmpty,
                error: (obj["error"] as? String)?.nilIfEmpty
            )
        } catch {
            return SimpleTxResult(success: false, txHash: nil, error: error.localizedDescription)
        }
    }

    // MARK: - Profiles / admin stats

    func searchUsers(keyward: String) async -> TerminalProfile? {
        let enc = keyward.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyward
        guard let url = URL(string: "\(BeamioConstants.beamioApi)/api/search-users?keyward=\(enc)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return nil }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = root["results"] as? [[String: Any]],
                  let first = results.first
            else { return nil }
            return TerminalProfile(
                accountName: (first["username"] as? String)?.nilIfEmpty ?? (first["accountName"] as? String)?.nilIfEmpty,
                firstName: (first["first_name"] as? String)?.nilIfEmpty,
                lastName: (first["last_name"] as? String)?.nilIfEmpty,
                image: (first["image"] as? String)?.nilIfEmpty,
                address: (first["address"] as? String)?.nilIfEmpty
            )
        } catch {
            return nil
        }
    }

    /// Open relay Charge（扫码动态 QR）— 对齐 Android `postAAtoEOAOpenContainer` 子集（无 chargeOwnerChildBurn）
    func postAAtoEOA(
        openContainerPayload: [String: Any],
        currency: String,
        currencyAmount: String,
        merchantInfraCard: String,
        chargeBill: [String: Any]
    ) async -> SimpleTxResult {
        var body: [String: Any] = [
            "openContainerPayload": openContainerPayload,
            "currency": currency,
            "currencyAmount": currencyAmount,
            "merchantCardAddress": merchantInfraCard,
        ]
        for (k, v) in chargeBill { body[k] = v }
        do {
            let (code, obj) = try await postJsonAllowErrorBody(path: "/api/AAtoEOA", body: body, timeout: 120)
            guard let obj else { return SimpleTxResult(success: false, txHash: nil, error: "HTTP \(code)") }
            let ok = (200 ... 299).contains(code) && ((obj["success"] as? Bool) ?? true)
            return SimpleTxResult(
                success: ok,
                txHash: (obj["USDC_tx"] as? String)?.nilIfEmpty,
                error: (obj["error"] as? String)?.nilIfEmpty
            )
        } catch {
            return SimpleTxResult(success: false, txHash: nil, error: error.localizedDescription)
        }
    }

    // MARK: - Beamio account (Verra / bizSite onboarding parity)

    /// `isAccountNameAvailable(string)` — selector `0xc2f74d22`（CoNET AccountRegistry）
    private static func encodeIsAccountNameAvailableCalldata(accountName: String) -> String {
        var sel = Data([0xc2, 0xf7, 0x4d, 0x22])
        let utf = Data(accountName.utf8)
        var body = Data()
        body.append(Self.abiWordUInt256(32))
        body.append(Self.abiWordUInt256(UInt64(utf.count)))
        body.append(utf)
        let pad = (32 - (utf.count % 32)) % 32
        body.append(Data(repeating: 0, count: pad))
        return "0x" + (sel + body).map { String(format: "%02x", $0) }.joined()
    }

    private static func abiWordUInt256(_ v: UInt64) -> Data {
        var be = [UInt8](repeating: 0, count: 32)
        var x = v
        for j in 0 ..< 8 {
            be[31 - j] = UInt8(x & 0xFF)
            x >>= 8
        }
        return Data(be)
    }

    /// `true` = 可用；`false` = 已被占用；`nil` = RPC/解析失败
    func isBeamioAccountNameAvailable(_ accountName: String) async -> Bool? {
        let trimmed = Self.normalizeBeamioAccountName(accountName)
        guard Self.isValidBeamioAccountNameFormat(trimmed) else { return false }
        let dataHex = Self.encodeIsAccountNameAvailableCalldata(accountName: trimmed)
        guard let url = URL(string: BeamioConstants.conetMainnetRpcUrl) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 12
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_call",
            "params": [[
                "to": BeamioConstants.beamioAccountRegistryAddress,
                "data": dataHex,
            ], "latest"],
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (raw, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return nil }
            guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let hex = (root["result"] as? String)?.lowercased(),
                  hex.hasPrefix("0x")
            else { return nil }
            let digits = hex.dropFirst(2)
            guard digits.count >= 2 else { return nil }
            let lastByteHex = digits.suffix(2)
            guard let b = UInt8(lastByteHex, radix: 16) else { return nil }
            return b != 0
        } catch {
            return nil
        }
    }

    struct RegisterBeamioAccountResult {
        var ok: Bool
        var error: String?
    }

    /// 与 `bizSite` `POST /api/addUser`（Cluster）一致；`recover` 空数组 = 无 Web 端恢复密包（POS 仅登记 handle）
    func registerBeamioAccount(
        accountName: String,
        walletAddress: String,
        signMessage: String,
        recover: [[String: String]]
    ) async -> RegisterBeamioAccountResult {
        let name = Self.normalizeBeamioAccountName(accountName)
        guard Self.isValidBeamioAccountNameFormat(name), walletAddress.hasPrefix("0x") else {
            return RegisterBeamioAccountResult(ok: false, error: "Invalid data format")
        }
        let recoverBox: [Any] = recover
        let body: [String: Any] = [
            "accountName": name,
            "wallet": walletAddress,
            "signMessage": signMessage,
            "recover": recoverBox,
            "image": "",
            "isUSDCFaucet": false,
            "darkTheme": false,
            "isETHFaucet": false,
            "firstName": "",
            "lastName": "",
            "pgpKeyID": "",
            "pgpKey": "",
        ]
        do {
            let (code, obj) = try await postJsonAllowErrorBody(path: "/api/addUser", body: body, timeout: 120)
            if (200 ... 299).contains(code), let o = obj, (o["ok"] as? Bool) == true {
                return RegisterBeamioAccountResult(ok: true, error: nil)
            }
            let err = (obj?["error"] as? String)?.nilIfEmpty ?? "Request failed (HTTP \(code))"
            return RegisterBeamioAccountResult(ok: false, error: err)
        } catch {
            return RegisterBeamioAccountResult(ok: false, error: error.localizedDescription)
        }
    }

    private static func normalizeBeamioAccountName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("@") { s.removeFirst() }
        return s
    }

    /// 与 Cluster `/addUser` 相同：`^[a-zA-Z0-9_\.]{3,20}$`
    private static func isValidBeamioAccountNameFormat(_ v: String) -> Bool {
        guard v.count >= 3, v.count <= 20 else { return false }
        return v.range(of: "^[a-zA-Z0-9_.]+$", options: .regularExpression) != nil
    }

    func fetchCardAdminInfo(cardAddress: String, wallet: String) async -> (upperAdmin: String?, owner: String?)? {
        guard let root = await fetchCardAdminInfoRoot(cardAddress: cardAddress, wallet: wallet) else { return nil }
        let upper = (root["upperAdmin"] as? String)?.nilIfEmpty
        let owner = (root["owner"] as? String)?.nilIfEmpty
        return (upper, owner)
    }

    /// Full `getCardAdminInfo` JSON for home routing / admin list walk (Android: `fetchGetCardAdminInfoJsonSync`).
    func fetchCardAdminInfoRoot(cardAddress: String, wallet: String) async -> [String: Any]? {
        let c = cardAddress.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cardAddress
        let w = wallet.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? wallet
        guard let url = URL(string: "\(BeamioConstants.beamioApi)/api/getCardAdminInfo?cardAddress=\(c)&wallet=\(w)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return nil }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (root["ok"] as? Bool) == true
            else { return nil }
            return root
        } catch {
            return nil
        }
    }

    // MARK: - Home dashboard (Android MainActivity: getCardStats + infra routing)

    /// `getAdminStatsFull(address,uint8,uint256,uint256)` selector `0x9abc4888`, PERIOD_DAY = 1
    func fetchAdminStatsDayChargeAndTopUp(wallet: String, infraCard: String) async -> (charge: Double?, topUp: Double?) {
        let a = wallet.replacingOccurrences(of: "0x", with: "", options: .caseInsensitive).lowercased()
        guard a.count == 40, a.allSatisfy(\.isASCIIHexDigit) else { return (nil, nil) }
        let data = Self.buildGetAdminStatsFullCalldata(adminAddrLower: a)
        guard let hex = await jsonRpcEthCallBase(to: infraCard, dataHex: data), let pair = Self.decodeGetAdminStatsFullResult(hex: hex) else {
            return (nil, nil)
        }
        return (pair.0, pair.1)
    }

    /// Tax % + discount summary line (Android: `fetchInfraRoutingForTerminalWalletSync` + cardMetadata fallback).
    func fetchInfraRoutingSummary(wallet: String, infraCard: String) async -> (tax: Double, discountSummary: String)? {
        let wNorm = wallet.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let infraNorm = infraCard.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let root = await fetchCardAdminInfoRoot(cardAddress: infraCard, wallet: wallet) else { return nil }
        let admins = root["admins"] as? [Any] ?? []
        let metadatas = root["metadatas"] as? [Any] ?? []
        let parents = root["parents"] as? [Any]
        var idx = -1
        for i in 0 ..< admins.count {
            let s = String(describing: admins[i]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s == wNorm { idx = i; break }
        }
        guard idx >= 0 else { return (0, "Not on admin list") }

        func adminIndex(for addr: String) -> Int {
            let x = addr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if x.isEmpty || x == "0x0000000000000000000000000000000000000000" { return -1 }
            for i in 0 ..< admins.count {
                let s = String(describing: admins[i]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if s == x { return i }
            }
            return -1
        }

        func parseRow(_ rowIdx: Int) -> (Double, String)? {
            guard rowIdx >= 0, rowIdx < metadatas.count else { return nil }
            let metaStr = String(describing: metadatas[rowIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            if metaStr.isEmpty { return nil }
            return Self.parseTierRoutingDiscounts(fromMetadataJson: metaStr, expectedInfrastructureCard: infraNorm)
        }

        if let p = parseRow(idx) { return p }
        var walk = idx
        for _ in 0 ..< 8 {
            guard let parents, walk >= 0, walk < parents.count else { break }
            let pRaw = String(describing: parents[walk]).trimmingCharacters(in: .whitespacesAndNewlines)
            let pIdx = adminIndex(for: pRaw)
            if pIdx < 0 { break }
            if let p = parseRow(pIdx) { return p }
            walk = pIdx
        }

        if let fallback = await fetchTierRoutingFromCardMetadataApi(cardAddress: infraCard) {
            return fallback
        }

        let hadMeta = idx < metadatas.count && !String(describing: metadatas[idx]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (0, hadMeta ? "No tier routing block" : "No routing metadata")
    }

    func fetchCardMetadataRoot(cardAddress: String) async -> [String: Any]? {
        let enc = cardAddress.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cardAddress
        guard let url = URL(string: "\(BeamioConstants.beamioApi)/api/cardMetadata?cardAddress=\(enc)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private func fetchTierRoutingFromCardMetadataApi(cardAddress: String) async -> (tax: Double, discountSummary: String)? {
        guard let resp = await fetchCardMetadataRoot(cardAddress: cardAddress),
              let meta = resp["metadata"] as? [String: Any]
        else { return nil }
        let fullInfra = cardAddress.hasPrefix("0x") ? cardAddress.lowercased() : "0x\(cardAddress.lowercased())"
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: []),
           let json = String(data: data, encoding: .utf8),
           let tr = Self.parseTierRoutingDiscounts(fromMetadataJson: json, expectedInfrastructureCard: fullInfra) {
            return tr
        }
        return Self.parseMembershipTierDiscountSummaryFromMetadata(meta: meta)
    }

    // MARK: - Base JSON-RPC

    private func jsonRpcEthCallBase(to: String, dataHex: String) async -> String? {
        let toLower = to.hasPrefix("0x") ? to.lowercased() : "0x\(to.lowercased())"
        let data = dataHex.hasPrefix("0x") ? dataHex.lowercased() : "0x\(dataHex.lowercased())"
        guard let url = URL(string: BeamioConstants.baseRpcUrl) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        let payload: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "eth_call",
            "params": [["to": toLower, "data": data], "latest"],
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (raw, resp) = try await session.data(for: req)
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

    private static func buildGetAdminStatsFullCalldata(adminAddrLower: String) -> String {
        let addrPadded = String(repeating: "0", count: 24) + adminAddrLower.lowercased()
        let periodDay = String(repeating: "0", count: 63) + "1"
        let z = String(repeating: "0", count: 64)
        return "0x9abc4888" + addrPadded + periodDay + z + z
    }

    /// periodTransferAmount word hex [768:832), periodMint [576:640)
    private static func decodeGetAdminStatsFullResult(hex: String) -> (Double, Double)? {
        var raw = hex
        if raw.hasPrefix("0x") { raw = String(raw.dropFirst(2)) }
        guard raw.count >= 832 else { return nil }
        let topUpStart = raw.index(raw.startIndex, offsetBy: 576)
        let topUpEnd = raw.index(raw.startIndex, offsetBy: 640)
        let chargeStart = raw.index(raw.startIndex, offsetBy: 768)
        let chargeEnd = raw.index(raw.startIndex, offsetBy: 832)
        let topUpHex = String(raw[topUpStart ..< topUpEnd])
        let chargeHex = String(raw[chargeStart ..< chargeEnd])
        let topUp = abiUInt256HexToDouble(topUpHex)
        let charge = abiUInt256HexToDouble(chargeHex)
        return (charge / 1_000_000, topUp / 1_000_000)
    }

    private static func abiUInt256HexToDouble(_ hex64: String) -> Double {
        var result: Double = 0
        for c in hex64.lowercased() {
            result *= 16
            switch c {
            case "0" ... "9": result += Double(c.asciiValue! - 48)
            case "a" ... "f": result += Double(c.asciiValue! - 87)
            default: break
            }
        }
        return result
    }

    private static func parseTierRoutingDiscounts(fromMetadataJson metaJson: String, expectedInfrastructureCard: String) -> (Double, String)? {
        guard let data = metaJson.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tr = root["tierRoutingDiscounts"] as? [String: Any]
        else { return nil }
        if let sv = tr["schemaVersion"], !(sv is NSNull) {
            let v: Int? = {
                if let n = sv as? NSNumber { return n.intValue }
                if let s = sv as? String { return Int(s) }
                return nil
            }()
            if let v, v != 1 { return nil }
        }
        let infra = (tr["infrastructureCard"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if infra.isEmpty { return nil }
        if infra.lowercased() != expectedInfrastructureCard.lowercased() { return nil }
        var tax = 0.0
        if let n = tr["taxRatePercent"] as? NSNumber { tax = n.doubleValue } else if let s = tr["taxRatePercent"] as? String { tax = Double(s) ?? 0 }
        tax = min(100, max(0, tax))
        tax = (tax * 100).rounded() / 100
        var discParts: [Int] = []
        if let tiers = tr["tiers"] as? [Any] {
            for row in tiers {
                guard let row = row as? [String: Any] else { continue }
                let d: Int? = {
                    if let n = row["discountPercent"] as? NSNumber { return n.intValue.clamped(to: 0 ... 100) }
                    if let s = row["discountPercent"] as? String, let v = Int(s) { return v.clamped(to: 0 ... 100) }
                    return nil
                }()
                if let d { discParts.append(d) }
            }
        }
        let discLabel = discParts.isEmpty ? "—" : discParts.map { "\($0)%" }.joined(separator: " · ")
        return (tax, discLabel)
    }

    private static func parseMembershipTierDiscountSummaryFromMetadata(meta: [String: Any]) -> (tax: Double, discountSummary: String)? {
        guard let tiersArr = meta["tiers"] as? [Any], !tiersArr.isEmpty else { return nil }
        struct Row { let chainIndex: Int; let pct: Int }
        var rows: [Row] = []
        for i in 0 ..< tiersArr.count {
            guard let row = tiersArr[i] as? [String: Any] else { continue }
            let chainIndex: Int = {
                if let n = row["index"] as? NSNumber { return n.intValue }
                if let s = row["index"] as? String { return Int(s) ?? i }
                return i
            }()
            let desc = (row["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let pct = firstPercentInText(desc) else { continue }
            rows.append(Row(chainIndex: chainIndex, pct: pct))
        }
        guard !rows.isEmpty else { return nil }
        let summary = rows.sorted { $0.chainIndex < $1.chainIndex }.map { "\($0.pct)%" }.joined(separator: " · ")
        return (0, summary)
    }

    private static func firstPercentInText(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        guard let r = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)\\s*%"),
              let m = r.firstMatch(in: t, range: NSRange(t.startIndex ..< t.endIndex, in: t)),
              m.numberOfRanges > 1,
              let rg = Range(m.range(at: 1), in: t)
        else { return nil }
        let num = Double(t[rg]) ?? 0
        return Int(num.rounded()).clamped(to: 0 ... 100)
    }
}

private extension Int {
    func clamped(to r: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, r.lowerBound), r.upperBound)
    }
}

private extension Character {
    var isASCIIHexDigit: Bool {
        ("0" ... "9").contains(self) || ("a" ... "f").contains(self) || ("A" ... "F").contains(self)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
