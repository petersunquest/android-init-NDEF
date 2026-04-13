import Foundation

/// Android `TierRoutingDetails`：终端 admin metadata `tierRoutingDiscounts` → Charge 税与档位折扣表
struct ChargeTierRoutingDetails: Sendable {
    var taxPercent: Double
    /// Keys lowercased: `chain-tier-{i}`, `tierId` — percent 0–100 with two decimal places (e.g. 12.50).
    var discountByTierKey: [String: Double]
}

enum BeamioAPIError: Error {
    case badResponse(Int)
    case decode
}

/// `/api/myPosAddress` → `terminalMetadata.allowedTopupMethods` (keys: cash, bankCard, usdc, airdrop).
struct PosTerminalPolicy: Equatable {
    var allowTopupCash: Bool
    var allowTopupBankCard: Bool
    var allowTopupUsdc: Bool
    var allowTopupAirdrop: Bool

    static let allAllowed = PosTerminalPolicy(allowTopupCash: true, allowTopupBankCard: true, allowTopupUsdc: true, allowTopupAirdrop: true)

    /// When false, Charge treats payer wallet USDC as unavailable (same flag as merchant "USDC" top-up method).
    var allowPayerUsdcInCharge: Bool { allowTopupUsdc }

    static func parse(terminalMetadata: Any?) -> PosTerminalPolicy {
        guard let meta = terminalMetadata as? [String: Any] else { return .allAllowed }
        guard let raw = meta["allowedTopupMethods"] else { return .allAllowed }
        guard let arr = raw as? [Any] else { return .allAllowed }
        var set = Set<String>()
        for x in arr {
            if let s = x as? String, !s.isEmpty { set.insert(s) }
        }
        if set.isEmpty {
            return PosTerminalPolicy(allowTopupCash: false, allowTopupBankCard: false, allowTopupUsdc: false, allowTopupAirdrop: false)
        }
        return PosTerminalPolicy(
            allowTopupCash: set.contains("cash"),
            allowTopupBankCard: set.contains("bankCard"),
            allowTopupUsdc: set.contains("usdc"),
            allowTopupAirdrop: set.contains("airdrop")
        )
    }
}

/// `/api/nfcTopup` optional split: `card + cash + bonus == currencyAmount` (6 decimal places, server `parseUnits`).
struct NfcTopupCurrencySplit: Equatable {
    let currencyAmount: String
    let cardCurrencyAmount: String
    let cashCurrencyAmount: String
    let bonusCurrencyAmount: String
}

extension BeamioAPIClient {
    private static func formatDecimalTopupApi6(_ value: Decimal) -> String {
        let rounded = decimalRound6(value)
        let nf = NumberFormatter()
        nf.locale = Locale(identifier: "en_US_POSIX")
        nf.usesGroupingSeparator = false
        nf.minimumFractionDigits = 0
        nf.maximumFractionDigits = 6
        nf.numberStyle = .decimal
        return nf.string(from: NSDecimalNumber(decimal: rounded)) ?? "0"
    }

    private static func decimalRound6(_ value: Decimal) -> Decimal {
        var rounded = Decimal()
        var v = value
        NSDecimalRound(&rounded, &v, 6, .plain)
        return rounded
    }

    /// POS keypad string (no `,` grouping). `methodRaw`: `creditCard` | `usdc` | `cash` | `bonus` (same raw values as `TopupPaymentMethodOption`).
    ///
    /// Product rules (must match `/api/nfcTopup` sum check: `card + cash + bonus == currencyAmount`):
    /// - **Bonus** switch: entire top-up is promotional → `currencyAmount == bonusCurrencyAmount`, card/cash `0`.
    /// - **Card** or **Cash** with **Activate Bonus** on: `currencyAmount` = principal (card or cash) + `bonusCurrencyAmount`.
    static func nfcTopupCurrencySplitFromPosKeypad(
        keypadAmount: String,
        methodRaw: String,
        bonusExpanded: Bool,
        selectedBonusRate: Int
    ) -> NfcTopupCurrencySplit? {
        let raw = keypadAmount.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        guard let base = Decimal(string: raw), base > 0 else { return nil }
        let z = formatDecimalTopupApi6(0)
        switch methodRaw {
        case "creditCard", "usdc":
            if bonusExpanded {
                let rate = Decimal(selectedBonusRate) / Decimal(100)
                let bonusPart = decimalRound6(base * rate)
                let total = decimalRound6(base + bonusPart)
                let baseR = decimalRound6(base)
                let bonusR = decimalRound6(total - baseR)
                return NfcTopupCurrencySplit(
                    currencyAmount: formatDecimalTopupApi6(total),
                    cardCurrencyAmount: formatDecimalTopupApi6(baseR),
                    cashCurrencyAmount: z,
                    bonusCurrencyAmount: formatDecimalTopupApi6(bonusR)
                )
            }
            let c = formatDecimalTopupApi6(base)
            return NfcTopupCurrencySplit(currencyAmount: c, cardCurrencyAmount: c, cashCurrencyAmount: z, bonusCurrencyAmount: z)
        case "cash":
            if bonusExpanded {
                let rate = Decimal(selectedBonusRate) / Decimal(100)
                let bonusPart = decimalRound6(base * rate)
                let total = decimalRound6(base + bonusPart)
                let baseR = decimalRound6(base)
                let bonusR = decimalRound6(total - baseR)
                return NfcTopupCurrencySplit(
                    currencyAmount: formatDecimalTopupApi6(total),
                    cardCurrencyAmount: z,
                    cashCurrencyAmount: formatDecimalTopupApi6(baseR),
                    bonusCurrencyAmount: formatDecimalTopupApi6(bonusR)
                )
            }
            let c = formatDecimalTopupApi6(base)
            return NfcTopupCurrencySplit(currencyAmount: c, cardCurrencyAmount: z, cashCurrencyAmount: c, bonusCurrencyAmount: z)
        case "bonus":
            let b = formatDecimalTopupApi6(base)
            return NfcTopupCurrencySplit(currencyAmount: b, cardCurrencyAmount: z, cashCurrencyAmount: z, bonusCurrencyAmount: b)
        default:
            return nil
        }
    }

    /// Retry path after insufficient funds (USDC / card rail): full amount on card leg.
    static func nfcTopupCurrencySplitAllCard(amount: String) -> NfcTopupCurrencySplit? {
        nfcTopupCurrencySplitFromPosKeypad(
            keypadAmount: amount,
            methodRaw: "creditCard",
            bonusExpanded: false,
            selectedBonusRate: 0
        )
    }
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

    struct MyPosBinding: Sendable {
        var cardAddress: String
        var policy: PosTerminalPolicy
    }

    /// Trusted cluster binding + terminal metadata. On network/parse failure returns `nil` (keep last policy).
    func fetchMyPosBinding(wallet: String) async -> MyPosBinding? {
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
            guard let addr else { return nil }
            let policy = PosTerminalPolicy.parse(terminalMetadata: root["terminalMetadata"])
            return MyPosBinding(cardAddress: addr, policy: policy)
        } catch {
            return nil
        }
    }

    func fetchMyPosAddress(wallet: String) async -> String? {
        await fetchMyPosBinding(wallet: wallet)?.cardAddress
    }

    /// `GET /api/myCards?owner=0x...` → `items[].cardAddress`（与 bizSite `fetchMyCardsFromApi` 一致）
    func fetchMyCardAddresses(ownerEoa: String) async -> [String] {
        let enc = ownerEoa.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ownerEoa
        guard let url = URL(string: "\(BeamioConstants.beamioApi)/api/myCards?owner=\(enc)") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 16
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return [] }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = root["items"] as? [[String: Any]]
            else { return [] }
            var out: [String] = []
            for it in items {
                guard let raw = (it["cardAddress"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      raw.hasPrefix("0x"), raw.count == 42
                else { continue }
                let hex = String(raw.dropFirst(2))
                guard hex.count == 40, hex.allSatisfy(\.isASCIIHexDigit) else { continue }
                out.append(raw.lowercased())
            }
            return out
        } catch {
            return []
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
        infraCard: String,
        currency: String = "CAD"
    ) async -> NfcTopupPrepareResult {
        let curNorm = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let curSend = curNorm.isEmpty ? "CAD" : curNorm
        var body: [String: Any] = [
            "amount": amount,
            "currency": curSend,
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
        sun: SunParams?,
        currencySplit: NfcTopupCurrencySplit? = nil
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
        if let s = currencySplit {
            body["currencyAmount"] = s.currencyAmount
            body["cardCurrencyAmount"] = s.cardCurrencyAmount
            body["cashCurrencyAmount"] = s.cashCurrencyAmount
            body["bonusCurrencyAmount"] = s.bonusCurrencyAmount
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

    /// Full `results[]` from `GET /api/search-users` (SilentPassUI `searchUsername` / `SearchBarWithResults`).
    func searchUsersList(keyward: String) async -> [TerminalProfile] {
        let trimmed = keyward.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lower = trimmed.lowercased()
        let enc = lower.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? lower
        guard let url = URL(string: "\(BeamioConstants.beamioApi)/api/search-users?keyward=\(enc)") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return [] }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = root["results"] as? [[String: Any]]
            else { return [] }
            return results.compactMap { Self.terminalProfileFromSearchUserDict($0) }
        } catch {
            return []
        }
    }

    private static func looksLikeEthereumAddress(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("0x"), t.count == 42 else { return false }
        let hex = t.dropFirst(2)
        return hex.allSatisfy { ch in
            ch.isASCII && ((ch >= "0" && ch <= "9") || (ch >= "a" && ch <= "f") || (ch >= "A" && ch <= "F"))
        }
    }

    /// POS / workspace picker: `GET /api/search-users-by-card-owner-or-admin` — server filters by `beamio_cards` issuers and by owner/admin on `wallet`’s linked cards plus `merchantInfraCard` (as `extraCardAddresses`).
    /// When `wallet` is nil (pre-wallet splash), only `extraCardAddresses` is sent if `merchantInfraCard` looks like an address (program card tree + issuers).
    func searchUsersListForPOS(keyward: String, wallet: String?, merchantInfraCard: String) async -> [TerminalProfile] {
        let trimmed = keyward.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let base = BeamioConstants.beamioApi.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: "\(base)/api/search-users-by-card-owner-or-admin") else { return [] }
        var items: [URLQueryItem] = [URLQueryItem(name: "keyward", value: trimmed.lowercased())]
        let wTrim = wallet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if Self.looksLikeEthereumAddress(wTrim) {
            items.append(URLQueryItem(name: "wallet", value: wTrim))
        }
        let infra = merchantInfraCard.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.looksLikeEthereumAddress(infra) {
            items.append(URLQueryItem(name: "extraCardAddresses", value: infra))
        }
        components.queryItems = items
        guard let url = components.url else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return [] }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = root["results"] as? [[String: Any]]
            else { return [] }
            return results.compactMap { Self.terminalProfileFromSearchUserDict($0) }
        } catch {
            return []
        }
    }

    func searchUsers(keyward: String) async -> TerminalProfile? {
        let list = await searchUsersList(keyward: keyward)
        return list.first
    }

    private static func terminalProfileFromSearchUserDict(_ row: [String: Any]) -> TerminalProfile? {
        let acc = (row["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? (row["accountName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let addr = (row["address"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let hasAcc = acc.map { !$0.isEmpty } ?? false
        let hasAddr = addr.map { !$0.isEmpty } ?? false
        guard hasAcc || hasAddr else { return nil }
        return TerminalProfile(
            accountName: acc,
            firstName: (row["first_name"] as? String)?.nilIfEmpty,
            lastName: (row["last_name"] as? String)?.nilIfEmpty,
            image: (row["image"] as? String)?.nilIfEmpty,
            address: addr
        )
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
        let sel = Data([0xc2, 0xf7, 0x4d, 0x22])
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

    /// `getBase64ByAccountName(string)` selector `0x1556d139` — same layout as `isAccountNameAvailable(string)`.
    private static func encodeGetBase64ByAccountNameCalldata(accountName: String) -> String {
        let sel = Data([0x15, 0x56, 0xd1, 0x39])
        let utf = Data(accountName.utf8)
        var body = Data()
        body.append(Self.abiWordUInt256(32))
        body.append(Self.abiWordUInt256(UInt64(utf.count)))
        body.append(utf)
        let pad = (32 - (utf.count % 32)) % 32
        body.append(Data(repeating: 0, count: pad))
        return "0x" + (sel + body).map { String(format: "%02x", $0) }.joined()
    }

    private static func rpcHexToData(_ hex: String) -> Data? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
        guard s.count % 2 == 0, !s.isEmpty else { return nil }
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
            guard j > i, let b = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    private static func abiReadUint256BE(_ data: Data, offset: Int) -> UInt? {
        guard offset >= 0, offset + 32 <= data.count else { return nil }
        var v: UInt = 0
        for i in 0 ..< 32 {
            v = (v << 8) | UInt(data[offset + i])
        }
        return v
    }

    /// ABI-decode a top-level dynamic `string` from `eth_call` `result` hex.
    private static func decodeAbiEncodedStringReturn(hex: String) -> String? {
        guard let data = rpcHexToData(hex), data.count >= 64 else { return nil }
        guard let strRel = abiReadUint256BE(data, offset: 0) else { return nil }
        let strOffset = Int(strRel)
        guard strOffset + 32 <= data.count else { return nil }
        guard let lenU = abiReadUint256BE(data, offset: strOffset) else { return nil }
        let n = Int(lenU)
        guard n >= 0, strOffset + 32 + n <= data.count else { return nil }
        return String(data: data[(strOffset + 32) ..< (strOffset + 32 + n)], encoding: .utf8)
    }

    /// `getBase64ByNameHash(bytes32)` selector `0x88a06434` — `hashHex` is 32-byte value as 64 hex chars (optional `0x`).
    private static func encodeGetBase64ByNameHashCalldata(hashHex: String) -> String? {
        var h = hashHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasPrefix("0x") { h.removeFirst(2) }
        guard h.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
        guard let hashData = rpcHexToData("0x" + h), hashData.count == 32 else { return nil }
        let sel = Data([0x88, 0xa0, 0x64, 0x34])
        return "0x" + (sel + hashData).map { String(format: "%02x", $0) }.joined()
    }

    /// `beamio.ts` `getRecoverPayloadByHash` / `beamioAccountSC.getBase64ByNameHash(hash)`.
    func getRecoverBase64ByNameHash(hashHex: String) async -> String? {
        guard let dataHex = Self.encodeGetBase64ByNameHashCalldata(hashHex: hashHex) else { return nil }
        guard let url = URL(string: BeamioConstants.conetMainnetRpcUrl) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 25
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
            guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return nil }
            if root["error"] != nil { return nil }
            guard let hex = root["result"] as? String else { return nil }
            let decoded = Self.decodeAbiEncodedStringReturn(hex: hex)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return decoded.isEmpty ? nil : decoded
        } catch {
            return nil
        }
    }

    /// `beamio.ts` `beamioAccountSC.getBase64ByAccountName(username)` — base64 of `{ stored, img }`.
    func getRecoverBase64ByAccountName(_ accountName: String) async -> String? {
        let trimmed = Self.normalizeBeamioAccountName(accountName)
        guard Self.isValidBeamioAccountNameFormat(trimmed) else { return nil }
        let dataHex = Self.encodeGetBase64ByAccountNameCalldata(accountName: trimmed)
        guard let url = URL(string: BeamioConstants.conetMainnetRpcUrl) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 25
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
            guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return nil }
            if root["error"] != nil { return nil }
            guard let hex = root["result"] as? String else { return nil }
            let decoded = Self.decodeAbiEncodedStringReturn(hex: hex)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return decoded.isEmpty ? nil : decoded
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

    private static let ethCallOwnerSelector = "0x8da5cb5b"
    private static let ethCallIsAdminAddressSelector = "0x24d7806c"

    private static func decodeAbiAddressWordHex(_ hex: String) -> String? {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.hasPrefix("0x") { raw.removeFirst(2) }
        guard raw.count >= 64 else { return nil }
        let addr = String(raw.suffix(40))
        guard addr.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { return nil }
        if addr == String(repeating: "0", count: 40) { return nil }
        return addr
    }

    private static func decodeAbiBoolWordHex(_ hex: String) -> Bool? {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.hasPrefix("0x") { raw.removeFirst(2) }
        guard raw.count >= 64 else { return nil }
        let suffix = String(raw.suffix(2))
        guard let b = UInt8(suffix, radix: 16) else { return nil }
        return b != 0
    }

    /// Base: program card `owner()==wallet` or `isAdmin(wallet)` via `eth_call` (authoritative vs HTTP JSON). `nil` = RPC/parse failure.
    func fetchPosProgramCardHomeAccessAllowed(cardAddress: String, wallet: String) async -> Bool? {
        let cardRaw = cardAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let walRaw = wallet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cardRaw.hasPrefix("0x"), cardRaw.count == 42,
              walRaw.hasPrefix("0x"), walRaw.count == 42 else { return nil }
        let cardHex = cardRaw.lowercased()
        let walBody = String(walRaw.dropFirst(2)).lowercased()
        guard walBody.count == 40, walBody.allSatisfy(\.isASCIIHexDigit) else { return nil }

        guard let ownerRes = await jsonRpcEthCallBase(to: cardHex, dataHex: Self.ethCallOwnerSelector),
              let owner40 = Self.decodeAbiAddressWordHex(ownerRes) else { return nil }
        if owner40 == walBody { return true }

        let isAdminData = Self.ethCallIsAdminAddressSelector + String(repeating: "0", count: 24) + walBody
        guard let iaRes = await jsonRpcEthCallBase(to: cardHex, dataHex: isAdminData),
              let isAdm = Self.decodeAbiBoolWordHex(iaRes) else { return nil }
        return isAdm
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

    /// Android `fetchTierRoutingDetailsForTerminalWalletSync`：税 + `discountByTierKey`（用于客户档位匹配）
    func fetchChargeTierRoutingDetails(wallet: String, infraCard: String) async -> ChargeTierRoutingDetails? {
        let wNorm = wallet.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let infraNorm = infraCard.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let root = await fetchCardAdminInfoRoot(cardAddress: infraCard, wallet: wallet) else {
            return await fetchChargeTierRoutingFallbackFromCardMetadata(infraCard: infraCard)
        }
        let admins = root["admins"] as? [Any] ?? []
        let metadatas = root["metadatas"] as? [Any] ?? []
        let parents = root["parents"] as? [Any]
        var idx = -1
        for i in 0 ..< admins.count {
            let s = String(describing: admins[i]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s == wNorm { idx = i; break }
        }
        guard idx >= 0 else {
            return await fetchChargeTierRoutingFallbackFromCardMetadata(infraCard: infraCard)
        }

        func adminIndex(for addr: String) -> Int {
            let x = addr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if x.isEmpty || x == "0x0000000000000000000000000000000000000000" { return -1 }
            for i in 0 ..< admins.count {
                let s = String(describing: admins[i]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if s == x { return i }
            }
            return -1
        }

        func rowHasTierRouting(_ rowIdx: Int) -> Bool {
            guard rowIdx >= 0, rowIdx < metadatas.count else { return false }
            let metaStr = String(describing: metadatas[rowIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            if metaStr.isEmpty { return false }
            return Self.parseTierRoutingDetailsFromMetadataJson(metaStr, expectedInfrastructureCard: infraNorm) != nil
        }

        func parseAtRow(_ rowIdx: Int) -> ChargeTierRoutingDetails? {
            guard rowIdx >= 0, rowIdx < metadatas.count else { return nil }
            let metaStr = String(describing: metadatas[rowIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            if metaStr.isEmpty { return nil }
            return Self.parseTierRoutingDetailsFromMetadataJson(metaStr, expectedInfrastructureCard: infraNorm)
        }

        if let d = parseAtRow(idx) { return d }
        var walk = idx
        for _ in 0 ..< 8 {
            guard let parents, walk >= 0, walk < parents.count else { break }
            let pRaw = String(describing: parents[walk]).trimmingCharacters(in: .whitespacesAndNewlines)
            let pIdx = adminIndex(for: pRaw)
            if pIdx < 0 { break }
            if rowHasTierRouting(pIdx), let d = parseAtRow(pIdx) { return d }
            walk = pIdx
        }

        return await fetchChargeTierRoutingFallbackFromCardMetadata(infraCard: infraCard)
    }

    /// `/api/cardMetadata` 的 `metadata.tiers`（非空则视为 API tiers，与 Android `cardMetadataTierFromApiCache` 一致）
    func fetchCardMetadataTiersBundle(cardAddress: String?) async -> (rows: [BeamioPaymentRouting.MetadataTierRow], fromApi: Bool) {
        let addr = cardAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !addr.isEmpty else { return ([], false) }
        guard let resp = await fetchCardMetadataRoot(cardAddress: addr),
              let meta = resp["metadata"] as? [String: Any],
              let tiersArr = meta["tiers"] as? [Any],
              !tiersArr.isEmpty
        else { return ([], false) }
        let rows = BeamioPaymentRouting.parseMetadataTierRows(metadataTiersArray: tiersArr)
        return (rows, !rows.isEmpty)
    }

    private func fetchChargeTierRoutingFallbackFromCardMetadata(infraCard: String) async -> ChargeTierRoutingDetails? {
        guard let resp = await fetchCardMetadataRoot(cardAddress: infraCard),
              let meta = resp["metadata"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: meta, options: []),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        let fullInfra = infraCard.hasPrefix("0x") ? infraCard.lowercased() : "0x\(infraCard.lowercased())"
        return Self.parseTierRoutingDetailsFromMetadataJson(json, expectedInfrastructureCard: fullInfra)
            ?? Self.parseTierRoutingDetailsFromMetadataJson(json, expectedInfrastructureCard: infraCard.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Android `parseTierRoutingDetailsFromTerminalMetadata`
    private static func parseTierRoutingDetailsFromMetadataJson(_ metaJson: String, expectedInfrastructureCard: String) -> ChargeTierRoutingDetails? {
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
        let exp = expectedInfrastructureCard.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if infra.lowercased() != exp { return nil }
        var tax = 0.0
        if let n = tr["taxRatePercent"] as? NSNumber { tax = n.doubleValue } else if let s = tr["taxRatePercent"] as? String { tax = Double(s) ?? 0 }
        tax = min(100, max(0, tax))
        tax = (tax * 100).rounded() / 100
        var map: [String: Double] = [:]
        if let tiers = tr["tiers"] as? [Any] {
            for rowAny in tiers {
                guard let row = rowAny as? [String: Any] else { continue }
                let d: Double? = {
                    if row["discountPercent"] == nil || row["discountPercent"] is NSNull { return nil }
                    if let n = row["discountPercent"] as? NSNumber {
                        return BeamioPaymentRouting.normalizeTierDiscountPercent(n.doubleValue)
                    }
                    if let s = row["discountPercent"] as? String,
                       let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
                    {
                        return BeamioPaymentRouting.normalizeTierDiscountPercent(v)
                    }
                    return nil
                }()
                guard let disc = d else { continue }
                let idx: Int? = {
                    if let n = row["chainTierIndex"] as? NSNumber { return n.intValue }
                    if let s = row["chainTierIndex"] as? String { return Int(s) }
                    return nil
                }()
                let tid = (row["tierId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let idx {
                    map["chain-tier-\(idx)".lowercased()] = disc
                }
                if !tid.isEmpty {
                    map[tid.lowercased()] = disc
                }
            }
        }
        return ChargeTierRoutingDetails(taxPercent: tax, discountByTierKey: map)
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

    /// Aligns with on-chain `_hasValidCard` when getWallet/getUID assets omit membership NFT rows.
    func chainHasValidMembershipForTopup(programCard: String, userAa: String) async -> Bool {
        let card = Self.jsonRpcNormalizeHexAddress(programCard)
        let aa = Self.jsonRpcNormalizeHexAddress(userAa)
        guard card.count == 42, aa.count == 42 else { return false }
        let aaBody = String(aa.dropFirst(2))
        let addrPadded = String(repeating: "0", count: 24) + aaBody
        let dataAm = "0x671395c8" + addrPadded
        guard let resAm = await jsonRpcEthCallBase(to: card, dataHex: dataAm),
              let tidWord = Self.jsonRpcLastUint256WordHex(from: resAm),
              !Self.jsonRpcIsAllZeroHex64(tidWord)
        else { return false }
        let dataBal = "0x00fdd58e" + addrPadded + tidWord
        guard let resBal = await jsonRpcEthCallBase(to: card, dataHex: dataBal),
              let balWord = Self.jsonRpcLastUint256WordHex(from: resBal),
              !Self.jsonRpcIsAllZeroHex64(balWord)
        else { return false }
        let dataExp = "0x17c95709" + tidWord
        guard let resExp = await jsonRpcEthCallBase(to: card, dataHex: dataExp),
              let expWord = Self.jsonRpcLastUint256WordHex(from: resExp)
        else { return true }
        if Self.jsonRpcIsAllZeroHex64(expWord) { return true }
        guard let expSec = Self.jsonRpcUInt64FromHexWord(expWord), expSec > 0 else { return true }
        let now = UInt64(Date().timeIntervalSince1970)
        return now <= expSec
    }

    /// `BeamioUserCard.currency()` + `pointsUnitPriceInCurrencyE6()` — same as `MemberCard.nfcTopupPreparePayload` direct points path.
    func fetchBeamioUserCardCurrencyCodeAndPointsUnitPriceE6(cardAddress: String) async -> (code: String, priceE6: UInt64)? {
        let card = Self.jsonRpcNormalizeHexAddress(cardAddress)
        guard card.count == 42 else { return nil }
        guard let curHex = await jsonRpcEthCallBase(to: card, dataHex: Self.ethCallCurrencySelector),
              let curWord = Self.jsonRpcLastUint256WordHex(from: curHex),
              let curNum = Self.jsonRpcUInt64FromHexWord(curWord)
        else { return nil }
        guard curNum <= 8 else { return nil }
        let code = Self.beamioCurrencyTypeCode(UInt8(truncatingIfNeeded: curNum))
        guard let priceHex = await jsonRpcEthCallBase(to: card, dataHex: Self.ethCallPointsUnitPriceInCurrencyE6Selector),
              let priceWord = Self.jsonRpcLastUint256WordHex(from: priceHex),
              let priceE6 = Self.jsonRpcUInt256WordToUInt64(priceWord), priceE6 > 0
        else { return nil }
        return (code, priceE6)
    }

    private static let ethCallCurrencySelector = "0xe5a6b10f"
    private static let ethCallPointsUnitPriceInCurrencyE6Selector = "0x4dda2215"

    private static func beamioCurrencyTypeCode(_ id: UInt8) -> String {
        switch id {
        case 0: return "CAD"
        case 1: return "USD"
        case 2: return "JPY"
        case 3: return "CNY"
        case 4: return "USDC"
        case 5: return "HKD"
        case 6: return "EUR"
        case 7: return "SGD"
        case 8: return "TWD"
        default: return "CAD"
        }
    }

    /// Last 32-byte ABI word as `UInt64` when it fits; otherwise `nil` (caller should fall back).
    private static func jsonRpcUInt256WordToUInt64(_ word64: String) -> UInt64? {
        if let v = jsonRpcUInt64FromHexWord(word64) { return v }
        let d = abiUInt256HexToDouble(word64)
        if !d.isFinite || d <= 0 || d > Double(UInt64.max) { return nil }
        return UInt64(d)
    }

    private static func jsonRpcNormalizeHexAddress(_ a: String) -> String {
        let t = a.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("0x") { return t.lowercased() }
        return "0x\(t.lowercased())"
    }

    private static func jsonRpcLastUint256WordHex(from hex: String) -> String? {
        var raw = hex
        if raw.hasPrefix("0x") { raw = String(raw.dropFirst(2)) }
        guard raw.count >= 64 else { return nil }
        let i = raw.index(raw.endIndex, offsetBy: -64)
        return String(raw[i...])
    }

    private static func jsonRpcIsAllZeroHex64(_ w: String) -> Bool {
        w.allSatisfy { $0 == "0" }
    }

    private static func jsonRpcUInt64FromHexWord(_ w64: String) -> UInt64? {
        var t = w64.lowercased()
        while t.first == "0" { t.removeFirst() }
        if t.isEmpty { return 0 }
        guard t.count <= 16 else { return nil }
        return UInt64(t, radix: 16)
    }

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
        var discParts: [Double] = []
        if let tiers = tr["tiers"] as? [Any] {
            for row in tiers {
                guard let row = row as? [String: Any] else { continue }
                let d: Double? = {
                    if row["discountPercent"] == nil || row["discountPercent"] is NSNull { return nil }
                    if let n = row["discountPercent"] as? NSNumber {
                        return BeamioPaymentRouting.normalizeTierDiscountPercent(n.doubleValue)
                    }
                    if let s = row["discountPercent"] as? String,
                       let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
                    {
                        return BeamioPaymentRouting.normalizeTierDiscountPercent(v)
                    }
                    return nil
                }()
                if let d { discParts.append(d) }
            }
        }
        let discLabel = discParts.isEmpty ? "—" : discParts.map { String(format: "%.2f", $0) + "%" }.joined(separator: " · ")
        return (tax, discLabel)
    }

    private static func parseMembershipTierDiscountSummaryFromMetadata(meta: [String: Any]) -> (tax: Double, discountSummary: String)? {
        guard let tiersArr = meta["tiers"] as? [Any], !tiersArr.isEmpty else { return nil }
        struct Row { let chainIndex: Int; let pct: Double }
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
        let summary = rows.sorted { $0.chainIndex < $1.chainIndex }.map { String(format: "%.2f", $0.pct) + "%" }.joined(separator: " · ")
        return (0, summary)
    }

    private static func firstPercentInText(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        guard let r = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)\\s*%"),
              let m = r.firstMatch(in: t, range: NSRange(t.startIndex ..< t.endIndex, in: t)),
              m.numberOfRanges > 1,
              let rg = Range(m.range(at: 1), in: t)
        else { return nil }
        let num = Double(t[rg]) ?? 0
        return BeamioPaymentRouting.normalizeTierDiscountPercent(num)
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
