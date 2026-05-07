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

private actor BeamioEthCallFetchCache {
    private struct Entry {
        let value: String
        let fetchedAt: Date
    }

    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]
    private var tail: Task<Void, Never>?

    func fetch(key: String, ttl: TimeInterval = 30, fetcher: @Sendable @escaping () async -> String?) async -> String? {
        let now = Date()
        if let hit = cache[key], now.timeIntervalSince(hit.fetchedAt) < ttl {
            return hit.value
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let previous = tail
        let task = Task<String?, Never> {
            await previous?.value
            return await fetcher()
        }
        inFlight[key] = task
        tail = Task<Void, Never> { _ = await task.value }

        let value = await task.value
        inFlight[key] = nil
        if let value {
            cache[key] = Entry(value: value, fetchedAt: Date())
        }
        return value
    }
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

/// Terminal mint / reload budget for this POS wallet on the program card (`getAdminAirdropLimit` + `getAdminStatsFull`), same scaling as biz `amountE6ToDisplayNumber`.
struct PosTerminalReloadQuota: Equatable {
    var unlimited: Bool
    /// Remaining mint allowance in display units (program points / ~CAD when card uses CAD).
    var remainingDisplay: Double
    /// Already minted since last counter clear, display units.
    var mintedFromClearDisplay: Double
}

/// Card Issuance `shareTokenMetadata.bonusRules` (biz `Card Issuance` → Recharge Bonuses).
/// Fixed tier: credit += `bonusValue` when principal ≥ `paymentAmount`.
/// `bonusProportional` (biz “Percentage”): credit += `principal * (bonusValue / paymentAmount)` when principal ≥ `paymentAmount`.
struct BeamioRechargeBonusRule: Equatable, Sendable, Codable {
    var paymentAmount: Double
    var bonusValue: Double
    /// Same as `shareTokenMetadata.bonusProportional` / biz checkbox “Percentage”.
    var bonusProportional: Bool
}

/// GET `/api/cardActiveIssuedCouponSeries` — issued program coupon series that are still valid on-chain (`isIssuedNftValid`).
struct MerchantActiveIssuedCoupon: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let cardAddress: String
    let tokenId: String
    let couponId: String?
    let requiresRedeemCode: Bool
    let issuedNftValidAfterSec: UInt64?
    let issuedNftValidBeforeSec: UInt64?
    let issuedNftMaxSupply: String?
    let issuedNftMintedCount: String?
    let issuedNftRemainingSupply: String?
    let createdAtIso: String?
    let displayTitle: String
    let validitySummary: String
    /// Coupon metadata-driven visuals (optional).
    let subtitle: String?
    let iconUrl: String?
    let backgroundImageUrl: String?
    let backgroundColorHex: String?
}

/// `/api/nfcTopup` optional split: `card + cash + bonus == currencyAmount` (6 decimal places, server `parseUnits`).
struct NfcTopupCurrencySplit: Equatable {
    let currencyAmount: String
    let cardCurrencyAmount: String
    let cashCurrencyAmount: String
    let bonusCurrencyAmount: String
}

/// One row in the POS Transactions screen — sourced from cluster `/api/posLedger` (BeamioIndexerDiamond
/// `getAccountTransactionsPaged` filtered + bounded by `*FromClear`). Reverse-chronological for display.
struct PosLedgerItem: Equatable, Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case topUp
        case charge
        case tip
    }

    let id: String
    let originalPaymentHash: String?
    let type: Kind
    let txCategory: String
    /// Unix epoch seconds (chain `block.timestamp`).
    let timestamp: Int64
    let payer: String
    let payee: String
    /// USDC 6-dp atomic; `0` when the chain row didn't denominate in USDC (use `amountFiat6` then).
    let amountUSDC6: String
    /// Fiat 6-dp atomic (program-card currency).
    let amountFiat6: String
    /// `BeamioCurrencyType` enum int from `meta.currencyFiat` (0 = USD; biz convention).
    let currencyFiat: Int
    /// Indexer raw `displayJson` — keep as opaque string; future detail panes can parse it.
    let displayJson: String
    let topAdmin: String?
    let subordinate: String?
    let note: String?
    /** Cluster-enriched: payer `accountName` without `@`. */
    let payerBeamioTag: String?
    /** `USDC` / `Card` / `Cash` / `Bonus` for top-up/charge rows. */
    let paymentMethodLabel: String?
}

/// Latest `TX_Terminal_RESET` indexer row for this terminal (`/api/posLedger` → `lastTerminalReset`).
struct PosLedgerTerminalResetMarker: Equatable, Codable, Sendable {
    let txId: String
    let timestamp: Int64
    let payer: String
}

/// Charge rows → Sales Overview subtotals (`displayJson.title`, aligned with `salesOverviewLedger.ts`).
struct PosSalesOverviewChargeBuckets: Equatable, Sendable {
    var usdcSubtotal: Double
    var cardSubtotalsByCurrency: [String: Double]
    var cashSubtotalsByCurrency: [String: Double]

    static let empty = PosSalesOverviewChargeBuckets(
        usdcSubtotal: 0,
        cardSubtotalsByCurrency: [:],
        cashSubtotalsByCurrency: [:]
    )
}

/// POS History → Top-Up Overview buckets (aligned with cluster `paymentMethodLabel` / `displayJson.topupPaymentLeg`).
struct PosTopUpOverviewBreakdown: Equatable, Sendable {
    var cashTotal: Double
    var cardTotal: Double
    var usdcTotal: Double
    var cashCount: Int
    var cardCount: Int
    var usdcCount: Int

    var totalAmount: Double { cashTotal + cardTotal + usdcTotal }
    var totalCount: Int { cashCount + cardCount + usdcCount }
}

/// Cluster `/api/posLedger` snapshot (items + the `*FromClear` totals shown in the panel header to prove parity).
struct PosLedgerSnapshot: Equatable, Codable, Sendable {
    /// Unsigned 6-decimal atomic; bigger than `Double` precision can hit, so keep as `String` in transit.
    let topUpFromClear6: String
    let chargeFromClear6: String
    let items: [PosLedgerItem]
    /// Newest indexer settlement reset for this POS EOA; absence = no reset row (or old API). Stats use `timestamp` as exclusive lower bound.
    let lastTerminalReset: PosLedgerTerminalResetMarker?

    init(
        topUpFromClear6: String,
        chargeFromClear6: String,
        items: [PosLedgerItem],
        lastTerminalReset: PosLedgerTerminalResetMarker? = nil
    ) {
        self.topUpFromClear6 = topUpFromClear6
        self.chargeFromClear6 = chargeFromClear6
        self.items = items
        self.lastTerminalReset = lastTerminalReset
    }

    /// Business rows after the latest `TX_Terminal_RESET` (server already filters; client re-filters when marker present as a safety net).
    func itemsInTerminalStatsPeriod() -> [PosLedgerItem] {
        guard let m = lastTerminalReset else { return items }
        return items.filter { $0.timestamp > m.timestamp }
    }

    /// Display-units conversion (divide by 1e6) — sufficient up to ~9e9 with `Double`.
    var topUpFromClearDisplay: Double { Self.atomic6ToDouble(topUpFromClear6) }
    var chargeFromClearDisplay: Double { Self.atomic6ToDouble(chargeFromClear6) }

    /// 用 fallback 兜底：USDC6 为 0 时退到 fiat6（cluster 端同样的 measure6 选择）。
    static func atomic6ToDouble(_ s: String) -> Double {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let n = Double(t) else { return 0 }
        return n / 1_000_000
    }

    /// Dashboard Tips: mirror Transactions display semantics. Matched `tip` rows are counted once
    /// under their parent Charge; embedded `chargeBreakdown.tipCurrencyAmount` is used only when no
    /// separate tip row matched that Charge. Internal B-Unit service legs are ignored.
    /// Scope: **current settlement window** only (`itemsInTerminalStatsPeriod`), not calendar day.
    func tipsDisplayTotalInTerminalStatsPeriod() -> Double {
        Self.tipsDisplayTotal(from: itemsInTerminalStatsPeriod())
    }

    /// Charge buckets for Sales Overview (title-based USDC / NFC card / cash fallback); same settlement window as gross.
    func chargeSalesOverviewBucketsInTerminalStatsPeriod() -> PosSalesOverviewChargeBuckets {
        var card: [String: Double] = [:]
        var cash: [String: Double] = [:]
        var usdcSum = 0.0
        for tx in itemsInTerminalStatsPeriod() {
            guard tx.type == .charge else { continue }
            guard !Self.isHiddenInternalLedgerCategory(tx.txCategory) else { continue }
            let titleLc = Self.salesOverviewDisplayTitleLower(tx.displayJson)
            if titleLc.contains("terminal settlement") { continue }
            if titleLc == "aa to eoa" { continue }
            let fiat6 = Double(tx.amountFiat6) ?? 0
            let usdc6 = Double(tx.amountUSDC6) ?? 0
            let fiatH = fiat6 / 1_000_000
            let usdcH = usdc6 / 1_000_000
            let ccy = Self.beamioCurrencyCodeFromFiatInt(tx.currencyFiat)
            switch titleLc {
            case Self.salesOverviewTitleUsdcMerchantCharge:
                if usdcH > 0 { usdcSum += usdcH }
            case Self.salesOverviewTitleNfcMerchantPayment:
                if fiatH > 0 { Self.mergeSalesOverviewCurrencyBucket(&card, code: ccy, amt: fiatH) }
            default:
                if fiatH > 0 {
                    Self.mergeSalesOverviewCurrencyBucket(&cash, code: ccy, amt: fiatH)
                } else if usdcH > 0 {
                    if ccy == "USDC" {
                        usdcSum += usdcH
                    } else {
                        Self.mergeSalesOverviewCurrencyBucket(&cash, code: "USDC", amt: usdcH)
                    }
                }
            }
        }
        return PosSalesOverviewChargeBuckets(
            usdcSubtotal: usdcSum,
            cardSubtotalsByCurrency: card,
            cashSubtotalsByCurrency: cash
        )
    }

    func chargeUsdcSettlementTotalInTerminalStatsPeriod() -> Double {
        chargeSalesOverviewBucketsInTerminalStatsPeriod().usdcSubtotal
    }

    func tipsUsdcSettlementTotalInTerminalStatsPeriod() -> Double {
        Self.tipsUsdcSettlementTotal(from: itemsInTerminalStatsPeriod())
    }

    private static func tipsDisplayTotal(from rawItems: [PosLedgerItem]) -> Double {
        let visibleItems = rawItems.filter { !isHiddenInternalLedgerCategory($0.txCategory) }
        let charges = visibleItems.filter { $0.type == .charge }
        let tips = visibleItems.filter { $0.type == .tip }
        var absorbedTipIds = Set<String>()
        var total = 0.0

        for charge in charges {
            let matched = tips.filter { tipRowMatchesChargeParent(tip: $0, charge: charge) }
            if matched.isEmpty {
                total += parseEmbeddedTipDisplayAmount(from: charge) ?? 0
            } else {
                for tip in matched {
                    absorbedTipIds.insert(tip.id.lowercased())
                    total += displayAmount(tip)
                }
            }
        }

        for tip in tips where !absorbedTipIds.contains(tip.id.lowercased()) {
            total += displayAmount(tip)
        }
        return total
    }

    private static func displayAmount(_ tx: PosLedgerItem) -> Double {
        let fiat6 = Double(tx.amountFiat6) ?? 0
        if fiat6 > 0 { return fiat6 / 1_000_000 }
        let usdc6 = Double(tx.amountUSDC6) ?? 0
        return usdc6 / 1_000_000
    }

    private static func usdcAmount(_ tx: PosLedgerItem) -> Double {
        let usdc6 = Double(tx.amountUSDC6) ?? 0
        return usdc6 / 1_000_000
    }

    private static func tipsUsdcSettlementTotal(from rawItems: [PosLedgerItem]) -> Double {
        let visibleItems = rawItems.filter { !isHiddenInternalLedgerCategory($0.txCategory) }
        let charges = visibleItems.filter { $0.type == .charge }
        let tips = visibleItems.filter { $0.type == .tip }
        var absorbedTipIds = Set<String>()
        var total = 0.0

        for charge in charges {
            let matched = tips.filter { tipRowMatchesChargeParent(tip: $0, charge: charge) }
            for tip in matched {
                absorbedTipIds.insert(tip.id.lowercased())
                if isExplicitUsdcAccountingCurrency(tip) {
                    total += usdcAmount(tip)
                }
            }
        }

        for tip in tips where !absorbedTipIds.contains(tip.id.lowercased()) {
            if isExplicitUsdcAccountingCurrency(tip) {
                total += usdcAmount(tip)
            }
        }
        return total
    }

    private static func isHiddenInternalLedgerCategory(_ raw: String) -> Bool {
        hiddenInternalLedgerCategories.contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func isExplicitUsdcAccountingCurrency(_ tx: PosLedgerItem) -> Bool {
        tx.currencyFiat == 4
    }

    private static let salesOverviewTitleUsdcMerchantCharge = "usdc merchant charge"
    private static let salesOverviewTitleNfcMerchantPayment = "nfc merchant payment"

    private static func salesOverviewDisplayTitleLower(_ displayJson: String) -> String {
        guard
            let data = displayJson.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let t = obj["title"] as? String
        else { return "" }
        return t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func mergeSalesOverviewCurrencyBucket(_ map: inout [String: Double], code: String, amt: Double) {
        guard amt > 0, amt.isFinite else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let key = trimmed.isEmpty ? "CAD" : trimmed
        map[key, default: 0] += amt
    }

    private static let hiddenInternalLedgerCategories: Set<String> = [
        "0x02d119b2041653c3b6f7aef339e2560da8ba867b022a04aaa150d062e5212bb7",
        "0x7067fa2b19fb81129d35576ad5fe635356a1405044d1c080a5ab341df6445776",
    ]

    private static func tipRowMatchesChargeParent(tip: PosLedgerItem, charge: PosLedgerItem) -> Bool {
        let tipKeys = tipParentLinkKeys(tip)
        guard !tipKeys.isEmpty else { return false }
        let chargeKeys = chargeParentKeys(charge)
        return tipKeys.contains { chargeKeys.contains($0) }
    }

    private static func chargeParentKeys(_ tx: PosLedgerItem) -> Set<String> {
        var out = Set<String>()
        addNormalized(tx.id, to: &out)
        addNormalized(tx.originalPaymentHash, to: &out)
        for h in displayJsonHashes(tx.displayJson, keys: ["finishedHash", "baseRelayTxHash", "requestHash", "originalPaymentHash"]) {
            addNormalized(h, to: &out)
        }
        return out
    }

    private static func tipParentLinkKeys(_ tx: PosLedgerItem) -> Set<String> {
        var out = Set<String>()
        addNormalized(tx.originalPaymentHash, to: &out)
        for h in displayJsonHashes(tx.displayJson, keys: ["finishedHash", "originalPaymentHash", "baseRelayTxHash"]) {
            addNormalized(h, to: &out)
        }
        return out
    }

    private static func addNormalized(_ raw: String?, to out: inout Set<String>) {
        guard let n = normalizeBytes32HexLower(raw) else { return }
        out.insert(n)
    }

    private static func normalizeBytes32HexLower(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if !s.hasPrefix("0x"), s.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil {
            s = "0x" + s
        }
        guard s.range(of: #"^0x[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil else { return nil }
        let lower = s.lowercased()
        return lower == "0x" + String(repeating: "0", count: 64) ? nil : lower
    }

    private static func displayJsonHashes(_ displayJson: String, keys: [String]) -> [String] {
        guard
            let data = displayJson.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return keys.compactMap { obj[$0] as? String }
    }

    private static func parseEmbeddedTipDisplayAmount(from tx: PosLedgerItem) -> Double? {
        guard
            let data = tx.displayJson.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let breakdown = obj["chargeBreakdown"] as? [String: Any]
        else { return nil }
        let rawTip = String(describing: breakdown["tipCurrencyAmount"] ?? "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tip = Double(rawTip), tip > 0 else { return nil }
        return tip
    }

    /// Matches `POSTransactionRowView.amountLine`: charge base (`preferredLedgerDisplay`) + tips in **base currency**
    /// (merged TX_TIP rows and/or embedded `chargeBreakdown` when no separate tips matched).
    private static func grossChargeRowDisplayTotal(charge: PosLedgerItem, matchedTips: [PosLedgerItem]) -> Double {
        let base = preferredLedgerDisplay(charge)
        var tipByCurrency: [String: Double] = [:]
        for t in matchedTips {
            let a = preferredLedgerDisplay(t)
            tipByCurrency[a.code, default: 0] += a.value
        }
        if matchedTips.isEmpty, let emb = embeddedTipValueAndCurrency(from: charge) {
            tipByCurrency[emb.code, default: 0] += emb.value
        }
        return base.value + (tipByCurrency[base.code] ?? 0)
    }

    private static func preferredLedgerDisplay(_ tx: PosLedgerItem) -> (value: Double, code: String) {
        let fiat6 = Double(tx.amountFiat6) ?? 0
        let usd6 = Double(tx.amountUSDC6) ?? 0
        if fiat6 > 0 {
            return (fiat6 / 1_000_000, beamioCurrencyCodeFromFiatInt(tx.currencyFiat))
        }
        return (usd6 / 1_000_000, "USDC")
    }

    /// Same mapping as `ContentView.POSTransactionRowView.beamioCurrencyCodeForCurrencyFiat`.
    private static func beamioCurrencyCodeFromFiatInt(_ id: Int) -> String {
        switch id {
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

    private static func embeddedTipValueAndCurrency(from tx: PosLedgerItem) -> (value: Double, code: String)? {
        guard
            let data = tx.displayJson.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let breakdown = obj["chargeBreakdown"] as? [String: Any]
        else { return nil }
        let rawTip = String(describing: breakdown["tipCurrencyAmount"] ?? "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tip = Double(rawTip), tip > 0 else { return nil }
        let cur = (breakdown["requestCurrency"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let code = (cur?.isEmpty == false) ? cur! : "CAD"
        return (tip, code)
    }

    /// Home **Total Due** (card-currency display): sum of Transactions-style Charge row totals for the
    /// **current settlement window** (`itemsInTerminalStatsPeriod` after `lastTerminalReset`). Standalone tip rows add their face amount
    /// so `Total Due − Tip` stays aligned with subtotal semantics.
    func chargeAndTipGrossDisplayTotalInTerminalStatsPeriod() -> Double {
        let window = itemsInTerminalStatsPeriod()
        let visible = window.filter { !Self.isHiddenInternalLedgerCategory($0.txCategory) }
        let charges = visible.filter { $0.type == .charge }
        let tips = visible.filter { $0.type == .tip }
        var absorbedTipIds = Set<String>()
        var gross = 0.0
        for charge in charges {
            let matched = tips.filter { Self.tipRowMatchesChargeParent(tip: $0, charge: charge) }
            for t in matched { absorbedTipIds.insert(t.id.lowercased()) }
            gross += Self.grossChargeRowDisplayTotal(charge: charge, matchedTips: matched)
        }
        for tip in tips where !absorbedTipIds.contains(tip.id.lowercased()) {
            gross += Self.preferredLedgerDisplay(tip).value
        }
        return gross
    }

    /// Home **Top-Ups** total for the **current settlement window** (same rows as Transactions after `*FromClear`).
    func topUpDisplayTotalInTerminalStatsPeriod() -> Double {
        var sum = 0.0
        for tx in itemsInTerminalStatsPeriod() where tx.type == .topUp {
            guard !Self.isHiddenInternalLedgerCategory(tx.txCategory) else { continue }
            sum += Self.preferredLedgerDisplay(tx).value
        }
        return sum
    }

    /// Sales Overview **Gross Sales**: charge face amounts only (no merged tip roll-up), settlement window.
    func chargeBaseDisplayTotalForSalesOverviewInTerminalStatsPeriod() -> Double {
        itemsInTerminalStatsPeriod()
            .filter { $0.type == .charge && !Self.isHiddenInternalLedgerCategory($0.txCategory) }
            .reduce(0) { $0 + Self.preferredLedgerDisplay($1).value }
    }

    /// Count of charge rows in the settlement window (Sales Overview **TRANSACTIONS** chip).
    func chargeTransactionCountInTerminalStatsPeriod() -> Int {
        itemsInTerminalStatsPeriod()
            .filter { $0.type == .charge && !Self.isHiddenInternalLedgerCategory($0.txCategory) }
            .count
    }

    /// Header line: latest Settlement → `now` (matches Android `posSalesOverviewSelectedPeriodLine`).
    func overviewSelectedPeriodLine(now: Date = Date()) -> String {
        let nowSec = Int64(now.timeIntervalSince1970)
        let endPart = Self.formatEpochSecondsForOverviewPeriod(nowSec)
        let resetSec = lastTerminalReset?.timestamp
        let periodItems = itemsInTerminalStatsPeriod()
        let startSec: Int64? = resetSec ?? periodItems.map(\.timestamp).min()
        guard let startSec else { return "— \(endPart)" }
        return "\(Self.formatEpochSecondsForOverviewPeriod(startSec)) — \(endPart)"
    }

    private static func formatEpochSecondsForOverviewPeriod(_ epochSeconds: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMM. d, yyyy"
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "h:mm a"
        return "\(df.string(from: d)) \(tf.string(from: d).lowercased())"
    }

    func topUpOverviewBreakdownInTerminalStatsPeriod() -> PosTopUpOverviewBreakdown {
        var cashT = 0.0, cardT = 0.0, usdcT = 0.0
        var cashC = 0, cardC = 0, usdcC = 0
        for tx in itemsInTerminalStatsPeriod() where tx.type == .topUp {
            guard !Self.isHiddenInternalLedgerCategory(tx.txCategory) else { continue }
            let amt = Self.preferredLedgerDisplay(tx).value
            switch Self.topUpOverviewBucket(tx) {
            case .cash:
                cashT += amt
                cashC += 1
            case .card:
                cardT += amt
                cardC += 1
            case .usdc:
                usdcT += amt
                usdcC += 1
            }
        }
        return PosTopUpOverviewBreakdown(
            cashTotal: cashT,
            cardTotal: cardT,
            usdcTotal: usdcT,
            cashCount: cashC,
            cardCount: cardC,
            usdcCount: usdcC
        )
    }

    private enum TopUpOverviewBucket {
        case cash, card, usdc
    }

    private static func topUpOverviewBucket(_ tx: PosLedgerItem) -> TopUpOverviewBucket {
        guard tx.type == .topUp else { return .card }
        let label = tx.paymentMethodLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch label {
        case "cash": return .cash
        case "usdc": return .usdc
        case "card", "bonus": return .card
        default: break
        }
        if !label.isEmpty { return .card }

        let leg = topUpPaymentLeg(from: tx.displayJson)
        switch leg {
        case "cash": return .cash
        case "credit", "bonus": return .card
        default: break
        }

        let fiat6 = Double(tx.amountFiat6) ?? 0
        let usdc6 = Double(tx.amountUSDC6) ?? 0
        if fiat6 <= 0, usdc6 > 0 { return .usdc }
        return .card
    }

    private static func topUpPaymentLeg(from displayJson: String) -> String {
        guard
            let data = displayJson.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let leg = obj["topupPaymentLeg"] as? String
        else { return "" }
        return leg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
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
    private static let ethCallFetchCache = BeamioEthCallFetchCache()

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

    /// Reload / mint cap for the POS EOA on the program card (Terminal Onboarding mint limit). `nil` if RPC/layout parse fails — caller may still rely on server checks.
    func fetchPosTerminalReloadQuota(posWallet: String, programCard: String) async -> PosTerminalReloadQuota? {
        let w = posWallet.replacingOccurrences(of: "0x", with: "", options: .caseInsensitive).lowercased()
        guard w.count == 40, w.allSatisfy(\.isASCIIHexDigit) else { return nil }
        let card = programCard.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard card.hasPrefix("0x"), card.count == 42 else { return nil }

        let limitData = Self.buildGetAdminAirdropLimitCalldata(adminAddrLower: w)
        guard let limitHex = await jsonRpcEthCallBase(to: card, dataHex: limitData),
              let limitParsed = Self.decodeGetAdminAirdropLimitResult(hex: limitHex)
        else { return nil }

        let statsData = Self.buildGetAdminStatsFullAllTimeCalldata(adminAddrLower: w)
        guard let statsHex = await jsonRpcEthCallBase(to: card, dataHex: statsData),
              let mintRaw = Self.parseMintCounterFromClearFromGetAdminStatsFull(hex: statsHex)
        else { return nil }

        let mintedDisplay = mintRaw / 1_000_000.0
        if limitParsed.unlimited {
            return PosTerminalReloadQuota(unlimited: true, remainingDisplay: 0, mintedFromClearDisplay: mintedDisplay)
        }
        return PosTerminalReloadQuota(
            unlimited: false,
            remainingDisplay: limitParsed.remainingRaw / 1_000_000.0,
            mintedFromClearDisplay: mintedDisplay
        )
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
        var factoryGateway: String?
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
                return NfcTopupPrepareResult(
                    cardAddr: nil, data: nil, deadline: nil, nonce: nil, wallet: nil,
                    factoryGateway: nil, error: "API response error (HTTP \(code))"
                )
            }
            if let err = (obj["error"] as? String)?.nilIfEmpty {
                return NfcTopupPrepareResult(
                    cardAddr: nil, data: nil, deadline: nil, nonce: nil, wallet: nil,
                    factoryGateway: nil, error: err
                )
            }
            let dl = (obj["deadline"] as? NSNumber)?.uint64Value
                ?? UInt64((obj["deadline"] as? String) ?? "") ?? 0
            return NfcTopupPrepareResult(
                cardAddr: (obj["cardAddr"] as? String)?.nilIfEmpty,
                data: (obj["data"] as? String)?.nilIfEmpty,
                deadline: dl > 0 ? dl : nil,
                nonce: (obj["nonce"] as? String)?.nilIfEmpty,
                wallet: (obj["wallet"] as? String)?.nilIfEmpty,
                factoryGateway: (obj["factoryGateway"] as? String)?.nilIfEmpty,
                error: nil
            )
        } catch {
            return NfcTopupPrepareResult(
                cardAddr: nil, data: nil, deadline: nil, nonce: nil, wallet: nil,
                factoryGateway: nil, error: error.localizedDescription
            )
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
        currencySplit: NfcTopupCurrencySplit? = nil,
        usdcTopupSessionId: String? = nil
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
        if let sid = usdcTopupSessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !sid.isEmpty {
            body["usdcTopupSessionId"] = sid.lowercased()
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

    /// fiat6-only Charge 协议（推荐）：传 `amountFiat6` + `currency`。`amountUsdc6` 仅作向后兼容存在期内传递，
    /// 服务端会在 `amountFiat6` + `currency` 都齐全时使用 fiat6 路径并打 deprecation 日志。
    /// prepare 响应附带 `cardCurrency` 与 `pointsUnitPriceInCurrencyE6`，供客户端做 fiat6 直算。
    /// 见 `.cursor/rules/beamio-charge-fiat-only-protocol.mdc`。
    func payByNfcUidPrepare(
        uid: String,
        payee: String,
        amountUsdc6: String? = nil,
        amountFiat6: String? = nil,
        currency: String? = nil,
        sun: SunParams?
    ) async -> [String: Any] {
        var body: [String: Any] = [
            "uid": uid,
            "payee": payee,
        ]
        if let amountFiat6, !amountFiat6.isEmpty { body["amountFiat6"] = amountFiat6 }
        if let currency, !currency.isEmpty { body["currency"] = currency.uppercased() }
        if let amountUsdc6, !amountUsdc6.isEmpty { body["amountUsdc6"] = amountUsdc6 }
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

    /// fiat6-only Charge 协议：传 `amountFiat6` + `currency`；`amountUsdc6` 仅向后兼容传递。
    /// `nfcBill` 仍承载小计/小费/税/折扣 fiat 字段，与 `amountFiat6` 同口径。
    func payByNfcUidSignContainer(
        uid: String,
        containerPayload: [String: Any],
        amountUsdc6: String? = nil,
        amountFiat6: String? = nil,
        currency: String? = nil,
        sun: SunParams?,
        nfcBill: [String: Any]
    ) async -> SimpleTxResult {
        var body: [String: Any] = [
            "uid": uid,
            "containerPayload": containerPayload,
        ]
        if let amountFiat6, !amountFiat6.isEmpty { body["amountFiat6"] = amountFiat6 }
        if let currency, !currency.isEmpty { body["currency"] = currency.uppercased() }
        if let amountUsdc6, !amountUsdc6.isEmpty { body["amountUsdc6"] = amountUsdc6 }
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

    /// Cluster `GET /api/nfcUsdcChargePreCheck`: iOS POS USDC charge QR 出图前的 fast-fail 预检 ——
    /// cardOwner 是否有足够 B-Unit 覆盖 topup 腿手续费。失败 ⇒ POS 不出 QR，避免顾客付完 USDC 才被卡在中段。
    /// `nil` = 网络/解析失败（trusted endpoint 失败按 untrusted 处理：调用方应将其当作 "unknown"，可选择继续或放弃）。
    /// 非 nil 的 `ok=false` 是后端拒绝的明确信号，应直接展示 `error` 给商户。
    struct UsdcChargePreCheckResult: Sendable {
        let ok: Bool
        let error: String?
        let cardOwner: String?
        let cardCurrency: String?
        let totalCurrency: String?
        let quotedUsdc6: String?
        let estPoints6: String?
        let requiredBUnits6: String?
    }

    func fetchUsdcChargePreCheck(
        cardAddress: String,
        pos: String?,
        subtotal: String,
        tipBps: Int,
        taxBps: Int,
        discountBps: Int,
        currency: String?
    ) async -> UsdcChargePreCheckResult? {
        let cardTrim = cardAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let subTrim = subtotal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cardTrim.hasPrefix("0x"), cardTrim.count == 42 else { return nil }
        guard !subTrim.isEmpty, (Double(subTrim) ?? 0.0) > 0.0 else { return nil }
        let cardEnc = cardTrim.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cardTrim
        var query = "card=\(cardEnc)&subtotal=\(subTrim)&tipBps=\(max(0, tipBps))&taxBps=\(max(0, taxBps))&discountBps=\(max(0, discountBps))"
        if let p = pos?.trimmingCharacters(in: .whitespacesAndNewlines), p.hasPrefix("0x"), p.count == 42 {
            let pEnc = p.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? p
            query += "&pos=\(pEnc)"
        }
        if let cur = currency?.trimmingCharacters(in: .whitespacesAndNewlines), !cur.isEmpty {
            let curEnc = cur.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cur
            query += "&currency=\(curEnc)"
        }
        guard let url = URL(string: "\(BeamioConstants.beamioApi)/api/nfcUsdcChargePreCheck?\(query)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return nil }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let okFlag = (root["ok"] as? Bool) ?? false
            let err = root["error"] as? String
            // 4xx with ok=false ⇒ 明确的业务拒绝；5xx 或 ok=true 都正常解析
            if !(200 ... 299).contains(http.statusCode) && !okFlag && (err == nil || err!.isEmpty) {
                return nil
            }
            return UsdcChargePreCheckResult(
                ok: okFlag,
                error: err,
                cardOwner: root["cardOwner"] as? String,
                cardCurrency: root["currency"] as? String,
                totalCurrency: root["total"] as? String,
                quotedUsdc6: root["quotedUsdc6"] as? String,
                estPoints6: root["estPoints6"] as? String,
                requiredBUnits6: root["requiredBUnits6"] as? String
            )
        } catch {
            return nil
        }
    }

    /// Cluster `GET /api/nfcUsdcChargeSession?sid=<uuid v4>`: PR #3 — POS 出 USDC charge QR 后单飞轮询此端点，
    /// 拉取顾客在 verra-home 的支付进度。语义：
    /// - `nil` ⇒ 网络/解析失败（trusted endpoint 失败按 untrusted 处理：调用方应当作 "unknown"，下一轮再拉，绝不当 error 切 UI）
    /// - `state == awaitingPayment` ⇒ 顾客尚未到达 POST 阶段或 sid 还没有 session record，继续轮询
    /// - `state == verifying / settling` ⇒ 顾客已经触发 charge，正在 x402 verify 或 USDC settle，继续轮询并可在 UI 上提示进度
    /// - `state == topupPending / topupConfirmed / chargePending` ⇒ PR #4 编排器中间态；仅 UI 提示推进，**不要**当 success/error 处理
    /// - `state == success` ⇒ terminal：USDC 已到 cardOwner（NFC 模式）或编排器 L2 charge 已上链（no-NFC 模式），POS 切 `chargeApprovedInline` UI，停止轮询
    /// - `state == error` ⇒ terminal：把 `error` 文案直接灌进 `paymentTerminalError`，停止轮询
    enum UsdcChargeSessionState: String, Sendable {
        case awaitingPayment = "awaiting_payment"
        case verifying
        case settling
        case topupPending = "topup_pending"
        /// PR #4 v2: 编排器已生成 tmpEOA + nfcTopupPreparePayload，等 POS 用 admin EOA 离线签 ExecuteForAdmin。
        /// POS 轮询命中此态 ⇒ 读 `pendingTopup*` 字段 → `BeamioEthWallet.signExecuteForAdmin` → POST `/api/nfcUsdcChargeTopupAuth`。
        case awaitingTopupAuth = "awaiting_topup_auth"
        /// USDC settled; customer must tap card on terminal (`nfcTopup` phase 2).
        case awaitingBeneficiary = "awaiting_beneficiary"
        case topupConfirmed = "topup_confirmed"
        case chargePending = "charge_pending"
        case success
        case error
        case unknown
    }

    struct UsdcChargeSessionResult: Sendable {
        let ok: Bool
        let sid: String?
        let state: UsdcChargeSessionState
        let error: String?
        let cardAddr: String?
        let cardOwner: String?
        let pos: String?
        let currency: String?
        let subtotal: String?
        let discount: String?
        let tax: String?
        let tip: String?
        let total: String?
        let usdcAmount6: String?
        let USDC_tx: String?
        let payer: String?
        /// PR #4 编排器扩展字段（NFC mode 缺省 nil）
        let tmpEOA: String?
        let tmpAA: String?
        let pointsMinted6: String?
        let topupTxHash: String?
        let chargeTxHash: String?
        /// PR #4 v2 (POS-signed admin path)：state==awaitingTopupAuth 时由 cluster 暴露给 POS 终端的
        /// ExecuteForAdmin 全部签名输入。POS 必须用这些 *exact* 值签名（hash mismatch ⇒ recover 不到 POS EOA ⇒ cluster 拒收）。
        let pendingTopupCardAddr: String?
        let pendingTopupRecipientEOA: String?
        let pendingTopupData: String?
        let pendingTopupDeadline: UInt64?
        let pendingTopupNonce: String?
        let pendingTopupPoints6: String?
        let pendingTopupBUnitFee: String?
        /// EIP-712 ExecuteForAdmin.domain.verifyingContract：卡 `factoryGateway()`，与 cluster 验签一致。
        let pendingTopupVerifyingContract: String?

        var isTerminal: Bool { state == .success || state == .error }
    }

    func fetchUsdcChargeSession(sid: String) async -> UsdcChargeSessionResult? {
        let sidTrim = sid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !sidTrim.isEmpty, sidTrim.count == 36 else { return nil }
        let sidEnc = sidTrim.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sidTrim
        guard let url = URL(string: "\(BeamioConstants.beamioApi)/api/nfcUsdcChargeSession?sid=\(sidEnc)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return nil }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let okFlag = (root["ok"] as? Bool) ?? false
            let err = root["error"] as? String
            // 4xx with ok=false ⇒ 明确的拒绝（如 invalid sid 格式）；其他失败按 untrusted 返回 nil
            if !(200 ... 299).contains(http.statusCode) {
                return UsdcChargeSessionResult(
                    ok: false, sid: sidTrim, state: .unknown, error: err,
                    cardAddr: nil, cardOwner: nil, pos: nil, currency: nil,
                    subtotal: nil, discount: nil, tax: nil, tip: nil, total: nil,
                    usdcAmount6: nil, USDC_tx: nil, payer: nil,
                    tmpEOA: nil, tmpAA: nil, pointsMinted6: nil,
                    topupTxHash: nil, chargeTxHash: nil,
                    pendingTopupCardAddr: nil, pendingTopupRecipientEOA: nil,
                    pendingTopupData: nil, pendingTopupDeadline: nil,
                    pendingTopupNonce: nil, pendingTopupPoints6: nil,
                    pendingTopupBUnitFee: nil,
                    pendingTopupVerifyingContract: nil
                )
            }
            let stateRaw = (root["state"] as? String) ?? ""
            let parsedState = UsdcChargeSessionState(rawValue: stateRaw) ?? .unknown
            // pendingTopupDeadline 后端用 number；JSONSerialization 给 NSNumber，需要安全 cast
            let deadlineN = (root["pendingTopupDeadline"] as? NSNumber)?.uint64Value
            return UsdcChargeSessionResult(
                ok: okFlag,
                sid: (root["sid"] as? String) ?? sidTrim,
                state: parsedState,
                error: err,
                cardAddr: root["cardAddr"] as? String,
                cardOwner: root["cardOwner"] as? String,
                pos: root["pos"] as? String,
                currency: root["currency"] as? String,
                subtotal: root["subtotal"] as? String,
                discount: root["discount"] as? String,
                tax: root["tax"] as? String,
                tip: root["tip"] as? String,
                total: root["total"] as? String,
                usdcAmount6: root["usdcAmount6"] as? String,
                USDC_tx: root["USDC_tx"] as? String,
                payer: root["payer"] as? String,
                tmpEOA: root["tmpEOA"] as? String,
                tmpAA: root["tmpAA"] as? String,
                pointsMinted6: root["pointsMinted6"] as? String,
                topupTxHash: root["topupTxHash"] as? String,
                chargeTxHash: root["chargeTxHash"] as? String,
                pendingTopupCardAddr: root["pendingTopupCardAddr"] as? String,
                pendingTopupRecipientEOA: root["pendingTopupRecipientEOA"] as? String,
                pendingTopupData: root["pendingTopupData"] as? String,
                pendingTopupDeadline: deadlineN,
                pendingTopupNonce: root["pendingTopupNonce"] as? String,
                pendingTopupPoints6: root["pendingTopupPoints6"] as? String,
                pendingTopupBUnitFee: root["pendingTopupBUnitFee"] as? String,
                pendingTopupVerifyingContract: root["pendingTopupVerifyingContract"] as? String
            )
        } catch {
            return nil
        }
    }

    /// PR #4 v2 (POS-signed admin path): POS 端在 `state == awaitingTopupAuth` 时，本地用 `BeamioEthWallet.signExecuteForAdmin`
    /// 签出 ExecuteForAdmin 65-byte sig，POST 给 cluster `/api/nfcUsdcChargeTopupAuth`。
    /// - returns:
    ///   - `(ok: true, errorMessage: nil)` 签名已被 cluster 接受（也可能是 idempotent 重提）。POSViewModel 应继续轮询拉 charge 进度。
    ///   - `(ok: false, errorMessage: <reason>)` HTTP 4xx/5xx：写到 `paymentTerminalError` 让用户看到（如 "Signature does not recover to bound POS operator"）。
    ///   - `nil` ⇒ untrusted 网络/解析失败（按 untrusted fetch protocol 处理：调用方继续下一拍轮询，不要切 UI）。
    func submitUsdcChargeTopupAuth(sid: String, signature: String) async -> (ok: Bool, errorMessage: String?)? {
        let sidTrim = sid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sigTrim = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sidTrim.isEmpty, sidTrim.count == 36, sigTrim.hasPrefix("0x"), sigTrim.count == 132 else { return nil }
        guard let url = URL(string: "\(BeamioConstants.beamioApi)/api/nfcUsdcChargeTopupAuth") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let body: [String: Any] = ["sid": sidTrim, "signature": sigTrim]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: []) else { return nil }
        req.httpBody = data
        do {
            let (respData, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return nil }
            let root = (try? JSONSerialization.jsonObject(with: respData) as? [String: Any]) ?? [:]
            let success = (root["success"] as? Bool) ?? false
            let errMsg = root["error"] as? String
            if (200 ... 299).contains(http.statusCode), success {
                return (ok: true, errorMessage: nil)
            }
            return (ok: false, errorMessage: errMsg ?? "HTTP \(http.statusCode)")
        } catch {
            return nil
        }
    }

    /// WC v2 / 任意第三方钱包签到的 EIP-3009 USDC raw sig 提交。
    ///
    /// 与 `submitUsdcChargeTopupAuth` 区别：那个是 PR #4 双腿 orchestrator 路径下 POS 自签的 ExecuteForAdmin 授权；
    /// 这个是**纯第三方钱包顾客**通过 WC 会话签的 USDC.transferWithAuthorization (EIP-3009)，由 cluster `/api/nfcUsdcChargeRawSig`
    /// 走 Master 直接在 Base 链上提交（**不走 x402**、**不走 orchestrator 双腿**），结算成功后 session 直接进 `success`。
    ///
    /// - parameters:
    ///   - sid: UUID v4 lowercased，POS 端在出 QR 前生成的 charge session id（与 charge poll 同源）。
    ///   - card: BeamioUserCard 合约地址（0x… 42 长）。
    ///   - pos: POS 终端 EOA 地址（0x… 42 长，可选；建议传以便后端记账归属 POS operator）。
    ///   - subtotal: 顾客单据小计（人类可读两位小数，如 `"10.00"`）。
    ///   - tipBps / taxBps / discountBps: 与 NFC charge / verra-home /usdc-charge 同口径的 bps；省略 = 0。
    ///   - currency: 三字母大写（如 `"CAD"`）；省略时 cluster 用 `card.currency()` 链上权威值。
    ///   - payer: EIP-3009 `from`（顾客钱包地址，0x… 42 长）。
    ///   - usdcAmount6: 顾客在签名中授权的 USDC value（atomic E6 uint256 decimal 字符串，应 ≥ 后端报价）。
    ///   - validAfter / validBefore: EIP-3009 时间窗 (uint256 decimal seconds since epoch)。
    ///   - nonce: EIP-3009 nonce (32-byte hex `0x...`)。
    ///   - signature: 65-byte `r||s||v` ECDSA hex（`0x` + 130 hex 字符）。
    /// - returns:
    ///   - `(ok: true, ...)` USDC tx 已上链确认；POSViewModel 切到 `chargeApprovedInline`，session 已进 `success`。
    ///   - `(ok: false, ...)` HTTP 4xx/5xx：写到 `paymentTerminalError` 让 POS 看到。
    ///   - `nil` ⇒ untrusted 网络/解析失败（按 untrusted fetch protocol：调用方继续轮询 session，不要切 UI）。
    func submitUsdcChargeRawSig(
        sid: String,
        card: String,
        pos: String?,
        subtotal: String,
        tipBps: Int,
        taxBps: Int,
        discountBps: Int,
        currency: String?,
        payer: String,
        usdcAmount6: String,
        validAfter: String,
        validBefore: String,
        nonce: String,
        signature: String
    ) async -> (ok: Bool, USDC_tx: String?, errorMessage: String?)? {
        let sidTrim = sid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cardTrim = card.trimmingCharacters(in: .whitespacesAndNewlines)
        let payerTrim = payer.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonceTrim = nonce.trimmingCharacters(in: .whitespacesAndNewlines)
        let sigTrim = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sidTrim.isEmpty, sidTrim.count == 36 else { return nil }
        guard cardTrim.hasPrefix("0x"), cardTrim.count == 42 else { return nil }
        guard payerTrim.hasPrefix("0x"), payerTrim.count == 42 else { return nil }
        guard nonceTrim.hasPrefix("0x"), nonceTrim.count == 66 else { return nil }
        guard sigTrim.hasPrefix("0x"), sigTrim.count == 132 else { return nil }
        guard let _ = UInt64(usdcAmount6) ?? UInt64(usdcAmount6, radix: 10) else { return nil }
        guard let url = URL(string: "\(BeamioConstants.beamioApi)/api/nfcUsdcChargeRawSig") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // USDC.transferWithAuthorization 上链等待 1 个 confirmation（Base ~2s/block），保守给 30s。
        req.timeoutInterval = 30
        var body: [String: Any] = [
            "sid": sidTrim,
            "card": cardTrim,
            "subtotal": subtotal,
            "discountBps": discountBps,
            "taxBps": taxBps,
            "tipBps": tipBps,
            "payer": payerTrim,
            "value": usdcAmount6,
            "validAfter": validAfter,
            "validBefore": validBefore,
            "nonce": nonceTrim,
            "signature": sigTrim,
        ]
        if let p = pos?.trimmingCharacters(in: .whitespacesAndNewlines), p.hasPrefix("0x"), p.count == 42 {
            body["pos"] = p
        }
        if let cur = currency?.trimmingCharacters(in: .whitespacesAndNewlines), !cur.isEmpty {
            body["currency"] = cur.uppercased()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: []) else { return nil }
        req.httpBody = data
        do {
            let (respData, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return nil }
            let root = (try? JSONSerialization.jsonObject(with: respData) as? [String: Any]) ?? [:]
            let success = (root["success"] as? Bool) ?? false
            let txHash = root["USDC_tx"] as? String
            let errMsg = root["error"] as? String
            if (200 ... 299).contains(http.statusCode), success {
                return (ok: true, USDC_tx: txHash, errorMessage: nil)
            }
            return (ok: false, USDC_tx: txHash, errorMessage: errMsg ?? "HTTP \(http.statusCode)")
        } catch {
            return nil
        }
    }

    /// Base: read `owner()` on a `BeamioUserCard` via `eth_call` (authoritative vs DB `cardMetadata.cardOwner`,
    /// which can drift if ownership transferred on chain). Returns checksummed `0x...` (EIP-55-ish: lowercased
    /// hex; backend only checks normalized equality with `ethers.getAddress`). `nil` = RPC/parse failure.
    func fetchBeamioUserCardOwner(cardAddress: String) async -> String? {
        let cardRaw = cardAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cardRaw.hasPrefix("0x"), cardRaw.count == 42 else { return nil }
        let cardHex = cardRaw.lowercased()
        guard let ownerRes = await jsonRpcEthCallBase(to: cardHex, dataHex: Self.ethCallOwnerSelector),
              let owner40 = Self.decodeAbiAddressWordHex(ownerRes)
        else { return nil }
        return "0x" + owner40
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

    // MARK: - POS Transactions screen (cluster `/api/posLedger` proxy of BeamioIndexerDiamond)

    /// Cluster proxy `/api/posLedger?eoa=&infraCard=`：每个 POS 终端只看到 *自己* EOA 的 Top-Up + Charge 流水，
    /// items 总和按 chain 上 `mintCounterFromClear` / `transferAmountFromClear` 严格 bound（与 admin/owner 清零后
    /// 显示值对账）。返回 `nil` ⇒ untrusted 失败：调用方**绝不**因此清空本地缓存（见
    /// `beamio-trusted-vs-untrusted-fetch.mdc`）。
    func fetchPosLedger(eoa: String, infraCard: String) async -> PosLedgerSnapshot? {
        let eoaTrim = eoa.trimmingCharacters(in: .whitespacesAndNewlines)
        let cardTrim = infraCard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !eoaTrim.isEmpty, !cardTrim.isEmpty else { return nil }
        let eoaEnc = eoaTrim.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? eoaTrim
        let cardEnc = cardTrim.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cardTrim
        guard let url = URL(string: "\(BeamioConstants.beamioApi)/api/posLedger?eoa=\(eoaEnc)&infraCard=\(cardEnc)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return nil }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (root["ok"] as? Bool) == true
            else { return nil }
            let fromClear = root["fromClear"] as? [String: Any] ?? [:]
            let topUp6 = (fromClear["topUp6"] as? String) ?? String(describing: fromClear["topUp6"] ?? "0")
            let charge6 = (fromClear["charge6"] as? String) ?? String(describing: fromClear["charge6"] ?? "0")
            let rawItems = (root["items"] as? [[String: Any]]) ?? []
            var items: [PosLedgerItem] = []
            items.reserveCapacity(rawItems.count)
            for raw in rawItems {
                guard
                    let id = raw["id"] as? String, !id.isEmpty,
                    let typeRaw = raw["type"] as? String,
                    let kind = PosLedgerItem.Kind(rawValue: typeRaw)
                else { continue }
                let oph = (raw["originalPaymentHash"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let cat = (raw["txCategory"] as? String) ?? ""
                let ts = Self.coerceInt64(raw["timestamp"]) ?? 0
                let payer = (raw["payer"] as? String) ?? ""
                let payee = (raw["payee"] as? String) ?? ""
                let usdc6 = Self.coerceAtomicString(raw["amountUSDC6"]) ?? "0"
                let fiat6 = Self.coerceAtomicString(raw["amountFiat6"]) ?? "0"
                let curFiat = Int(Self.coerceInt64(raw["currencyFiat"]) ?? 0)
                let displayJson = (raw["displayJson"] as? String) ?? ""
                let topAdmin = (raw["topAdmin"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let subordinate = (raw["subordinate"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let note = (raw["note"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let payerBeamioTag = (raw["payerBeamioTag"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let paymentMethodLabel = (raw["paymentMethodLabel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                items.append(PosLedgerItem(
                    id: id,
                    originalPaymentHash: oph,
                    type: kind,
                    txCategory: cat,
                    timestamp: ts,
                    payer: payer,
                    payee: payee,
                    amountUSDC6: usdc6,
                    amountFiat6: fiat6,
                    currencyFiat: curFiat,
                    displayJson: displayJson,
                    topAdmin: topAdmin,
                    subordinate: subordinate,
                    note: note,
                    payerBeamioTag: payerBeamioTag,
                    paymentMethodLabel: paymentMethodLabel
                ))
            }
            // Server already sorted newest-first; re-sort defensively (untrusted ordering is cheap to fix client-side).
            items.sort { $0.timestamp > $1.timestamp }
            var resetMarker: PosLedgerTerminalResetMarker?
            if let rawReset = root["lastTerminalReset"] as? [String: Any], !rawReset.isEmpty {
                let txId = (rawReset["txId"] as? String) ?? ""
                let ts = Self.coerceInt64(rawReset["timestamp"]) ?? 0
                let payer = (rawReset["payer"] as? String) ?? ""
                if !txId.isEmpty, ts >= 0 {
                    resetMarker = PosLedgerTerminalResetMarker(txId: txId, timestamp: ts, payer: payer)
                }
            }
            return PosLedgerSnapshot(
                topUpFromClear6: topUp6,
                chargeFromClear6: charge6,
                items: items,
                lastTerminalReset: resetMarker
            )
        } catch {
            return nil
        }
    }

    private static func coerceInt64(_ v: Any?) -> Int64? {
        if let n = v as? Int64 { return n }
        if let n = v as? Int { return Int64(n) }
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String { return Int64(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func coerceAtomicString(_ v: Any?) -> String? {
        if let s = v as? String { return s.trimmingCharacters(in: .whitespaces) }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
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

    /// CoNET L1 BUint `balanceOf(address)` for the POS upstream admin/owner EOA. Raw token precision is 6 decimals.
    func fetchBUnitBalanceOnConet(account: String) async -> Double? {
        let a = account.replacingOccurrences(of: "0x", with: "", options: .caseInsensitive).lowercased()
        guard a.count == 40, a.allSatisfy(\.isASCIIHexDigit) else { return nil }
        let data = Self.buildErc20BalanceOfCalldata(addressLower: a)
        let token = BeamioConstants.buintConet.lowercased()
        let key = "conet:eoa:\(a):token:\(token):balanceOf"
        guard let hex = await Self.ethCallFetchCache.fetch(key: key, ttl: 30, fetcher: { [session] in
            await Self.jsonRpcEthCallConet(session: session, to: token, dataHex: data)
        }) else { return nil }
        guard var word = Self.jsonRpcLastUint256WordHex(from: hex) else { return nil }
        while word.first == "0" { word.removeFirst() }
        if word.isEmpty { return 0 }
        let raw = Self.abiUInt256HexToDouble(word)
        return raw / 1_000_000.0
    }

    /// Base CADD (`0x16F93eBC...`) ERC20 balance for the provided wallet.
    /// Returns human-readable token amount (scaled by on-chain `decimals()`).
    func fetchCaddBalanceOnBase(account: String) async -> Double? {
        await fetchErc20BalanceOnBase(account: account, tokenAddress: BeamioConstants.caddBase)
    }

    /// Generic Base ERC20 balance reader with trusted cache semantics.
    /// - `nil`: RPC/parse failure (untrusted)
    /// - value: trusted on-chain amount (including trusted empty `0`)
    func fetchErc20BalanceOnBase(account: String, tokenAddress: String) async -> Double? {
        let a = account.replacingOccurrences(of: "0x", with: "", options: .caseInsensitive).lowercased()
        let t = tokenAddress.replacingOccurrences(of: "0x", with: "", options: .caseInsensitive).lowercased()
        guard a.count == 40, a.allSatisfy(\.isASCIIHexDigit), t.count == 40, t.allSatisfy(\.isASCIIHexDigit) else { return nil }
        let session = session
        let token = "0x\(t)"
        let balData = Self.buildErc20BalanceOfCalldata(addressLower: a)
        let balKey = "base:eoa:\(a):token:\(t):balanceOf"
        guard let balHex = await Self.ethCallFetchCache.fetch(key: balKey, ttl: 30, fetcher: { [session] in
            await Self.jsonRpcEthCallBase(session: session, to: token, dataHex: balData)
        }) else { return nil }
        guard var balWord = Self.jsonRpcLastUint256WordHex(from: balHex) else { return nil }
        while balWord.first == "0" { balWord.removeFirst() }
        let raw = balWord.isEmpty ? 0 : Self.abiUInt256HexToDouble(balWord)

        let decKey = "base:token:\(t):decimals"
        let decData = Self.ethCallErc20DecimalsSelector
        let decimalsWord = await Self.ethCallFetchCache.fetch(key: decKey, ttl: 3600, fetcher: { [session] in
            await Self.jsonRpcEthCallBase(session: session, to: token, dataHex: decData)
        }).flatMap { Self.jsonRpcLastUint256WordHex(from: $0) }
        let decimalsU64 = decimalsWord.flatMap(Self.jsonRpcUInt64FromHexWord) ?? 18
        guard decimalsU64 <= 30 else { return nil }
        return raw / pow(10, Double(decimalsU64))
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

    /// `metadata.bonusRules` / `metadata.bonusRule`, or nested `metadata.shareTokenMetadata.*` (card issuance share token).
    /// Returns `nil` for **untrusted** outcomes (HTTP / JSON error, missing `metadata` field) so callers (e.g. POS Home) can keep the
    /// previous trusted value instead of clearing the panel — see `beamio-trusted-vs-untrusted-fetch.mdc`.
    /// Returns `[]` only for the **trusted-empty** case where the metadata is parseable but contains no `bonusRules` entries.
    func fetchProgramRechargeBonusRules(cardAddress: String) async -> [BeamioRechargeBonusRule]? {
        guard let root = await fetchCardMetadataRoot(cardAddress: cardAddress),
              let meta = root["metadata"] as? [String: Any]
        else { return nil }
        return Self.parseRechargeBonusRules(fromMetadata: meta)
    }

    /// Active program coupons on the merchant **program** BeamioUserCard (`/api/cardActiveIssuedCouponSeries`).
    /// - Returns: `nil` if the response is untrusted (network / non-JSON / malformed); caller must not clear cached rows.
    /// - Returns: `[]` only when HTTP 200 and `items` is a valid empty array.
    func fetchMerchantActiveIssuedCoupons(cardAddress: String, limit: Int = 50) async -> [MerchantActiveIssuedCoupon]? {
        let trimmed = cardAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPlausibleEvmAddress(trimmed) else { return [] }
        let enc = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        let lim = max(1, min(limit, 50))
        guard let url = URL(string: "\(BeamioConstants.beamioApi)/api/cardActiveIssuedCouponSeries?card=\(enc)&limit=\(lim)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 12
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return nil }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            guard let items = root["items"] as? [Any] else { return nil }
            var out: [MerchantActiveIssuedCoupon] = []
            out.reserveCapacity(items.count)
            for any in items {
                guard let d = any as? [String: Any], let row = Self.parseMerchantActiveIssuedCouponRow(d) else { continue }
                out.append(row)
            }
            return out
        } catch {
            return nil
        }
    }

    struct CouponClaimResult {
        var success: Bool
        var txHash: String?
        var error: String?
    }

    struct CouponConsumePrepareResult {
        var success: Bool
        var cardAddress: String?
        var data: String?
        var deadline: UInt64?
        var nonce: String?
        var factoryGateway: String?
        var tokenId: String?
        var amount: String?
        var targetAddress: String?
        var error: String?
    }

    struct CouponConsumeResult {
        var success: Bool
        var txHash: String?
        var error: String?
    }

    /// POS one-tap claim for open coupons (NFC card flow): cluster signs with NFC card key and forwards to Master.
    func cardCouponPosClaim(
        cardAddress: String,
        couponId: String,
        userEOA: String,
        uid: String?,
        tagIdHex: String?,
        tokenId: String?
    ) async -> CouponClaimResult {
        let card = cardAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let coupon = couponId.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userEOA.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPlausibleEvmAddress(card), Self.isPlausibleEvmAddress(user), !coupon.isEmpty else {
            return CouponClaimResult(success: false, txHash: nil, error: "Invalid claim payload.")
        }
        var body: [String: Any] = [
            "cardAddress": card,
            "couponId": coupon,
            "userEOA": user,
        ]
        if let uid, !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["uid"] = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let tagIdHex, !tagIdHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["tagIdHex"] = tagIdHex.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let tokenId, !tokenId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["tokenId"] = tokenId.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            let (code, obj) = try await postJsonAllowErrorBody(path: "/api/cardCouponPosClaim", body: body, timeout: 45)
            guard let obj else {
                return CouponClaimResult(success: false, txHash: nil, error: "HTTP \(code)")
            }
            let ok = (200 ... 299).contains(code) && ((obj["success"] as? Bool) ?? true)
            return CouponClaimResult(
                success: ok,
                txHash: (obj["tx"] as? String)?.nilIfEmpty,
                error: (obj["error"] as? String)?.nilIfEmpty
            )
        } catch {
            return CouponClaimResult(success: false, txHash: nil, error: error.localizedDescription)
        }
    }

    /// POS balance coupon consume prepare: cluster pre-checks ownership/balance and returns executeForOwner payload.
    func cardCouponPosConsumePrepare(
        cardAddress: String,
        couponId: String,
        userEOA: String,
        signerEOA: String?,
        tokenId: String?,
        amount: String = "1"
    ) async -> CouponConsumePrepareResult {
        let card = cardAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let coupon = couponId.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userEOA.trimmingCharacters(in: .whitespacesAndNewlines)
        let amt = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPlausibleEvmAddress(card), Self.isPlausibleEvmAddress(user), !coupon.isEmpty, !amt.isEmpty else {
            return CouponConsumePrepareResult(success: false, cardAddress: nil, data: nil, deadline: nil, nonce: nil, factoryGateway: nil, tokenId: nil, amount: nil, targetAddress: nil, error: "Invalid consume payload.")
        }
        var body: [String: Any] = [
            "cardAddress": card,
            "couponId": coupon,
            "userEOA": user,
            "amount": amt,
        ]
        if let signerEOA, Self.isPlausibleEvmAddress(signerEOA.trimmingCharacters(in: .whitespacesAndNewlines)) {
            body["signerEOA"] = signerEOA.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let tokenId, !tokenId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["tokenId"] = tokenId.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            let (code, obj) = try await postJsonAllowErrorBody(path: "/api/cardCouponPosConsumePrepare", body: body, timeout: 45)
            guard let obj else {
                return CouponConsumePrepareResult(success: false, cardAddress: nil, data: nil, deadline: nil, nonce: nil, factoryGateway: nil, tokenId: nil, amount: nil, targetAddress: nil, error: "HTTP \(code)")
            }
            let ok = (200 ... 299).contains(code) && ((obj["success"] as? Bool) ?? true)
            let dl = (obj["deadline"] as? NSNumber)?.uint64Value
                ?? UInt64((obj["deadline"] as? String) ?? "") ?? 0
            return CouponConsumePrepareResult(
                success: ok,
                cardAddress: (obj["cardAddress"] as? String)?.nilIfEmpty,
                data: (obj["data"] as? String)?.nilIfEmpty,
                deadline: dl > 0 ? dl : nil,
                nonce: (obj["nonce"] as? String)?.nilIfEmpty,
                factoryGateway: (obj["factoryGateway"] as? String)?.nilIfEmpty,
                tokenId: (obj["tokenId"] as? String)?.nilIfEmpty,
                amount: (obj["amount"] as? String)?.nilIfEmpty,
                targetAddress: (obj["targetAddress"] as? String)?.nilIfEmpty,
                error: (obj["error"] as? String)?.nilIfEmpty
            )
        } catch {
            return CouponConsumePrepareResult(success: false, cardAddress: nil, data: nil, deadline: nil, nonce: nil, factoryGateway: nil, tokenId: nil, amount: nil, targetAddress: nil, error: error.localizedDescription)
        }
    }

    /// Submit owner-signed ExecuteForOwner transaction for coupon consume.
    func cardCouponPosConsumeSubmit(
        cardAddress: String,
        data: String,
        deadline: UInt64,
        nonce: String,
        ownerSignature: String
    ) async -> CouponConsumeResult {
        let card = cardAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let dat = data.trimmingCharacters(in: .whitespacesAndNewlines)
        let nn = nonce.trimmingCharacters(in: .whitespacesAndNewlines)
        let sig = ownerSignature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPlausibleEvmAddress(card), !dat.isEmpty, !nn.isEmpty, !sig.isEmpty else {
            return CouponConsumeResult(success: false, txHash: nil, error: "Invalid consume submit payload.")
        }
        let body: [String: Any] = [
            "cardAddress": card,
            "data": dat,
            "deadline": deadline,
            "nonce": nn,
            "ownerSignature": sig,
        ]
        do {
            let (code, obj) = try await postJsonAllowErrorBody(path: "/api/executeForOwner", body: body, timeout: 90)
            guard let obj else {
                return CouponConsumeResult(success: false, txHash: nil, error: "HTTP \(code)")
            }
            let ok = (200 ... 299).contains(code) && ((obj["success"] as? Bool) ?? true)
            return CouponConsumeResult(
                success: ok,
                txHash: ((obj["txHash"] as? String) ?? (obj["tx"] as? String))?.nilIfEmpty,
                error: (obj["error"] as? String)?.nilIfEmpty
            )
        } catch {
            return CouponConsumeResult(success: false, txHash: nil, error: error.localizedDescription)
        }
    }

    /// Card issuance stores recharge tiers under `metadata.shareTokenMetadata` (biz `createBeamioCard`); some responses also duplicate at `metadata` root.
    private static func parseRechargeBonusRules(fromMetadata meta: [String: Any]) -> [BeamioRechargeBonusRule] {
        let direct = parseRechargeBonusRulesDirect(from: meta)
        if !direct.isEmpty { return direct }
        if let stm = meta["shareTokenMetadata"] as? [String: Any] {
            return parseRechargeBonusRulesDirect(from: stm)
        }
        if let s = meta["shareTokenMetadata"] as? String,
           let data = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return parseRechargeBonusRulesDirect(from: obj)
        }
        return []
    }

    private static func parseRechargeBonusRulesDirect(from meta: [String: Any]) -> [BeamioRechargeBonusRule] {
        var out: [BeamioRechargeBonusRule] = []
        if let arr = meta["bonusRules"] as? [Any] {
            for x in arr {
                if let r = parseOneRechargeBonusRule(x) { out.append(r) }
            }
        }
        if out.isEmpty, let one = meta["bonusRule"] {
            if let r = parseOneRechargeBonusRule(one) { out.append(r) }
        }
        return out
    }

    private static func parseBonusProportionalFlag(_ d: [String: Any]) -> Bool {
        let keys = ["bonusProportional", "bonusIsProportional", "percentBased", "proportionalBonus", "percentage"]
        for k in keys {
            guard let v = d[k] else { continue }
            if let b = v as? Bool, b { return true }
            if let n = v as? NSNumber, n.boolValue { return true }
            if let s = v as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if t == "true" || t == "1" { return true }
            }
        }
        return false
    }

    private static func parseOneRechargeBonusRule(_ any: Any) -> BeamioRechargeBonusRule? {
        guard let d = any as? [String: Any] else { return nil }
        guard let pay = parsePositiveMoneyField(d["paymentAmount"]),
              let bonus = parseNonNegativeMoneyField(d["bonusValue"]),
              bonus > 0
        else { return nil }
        let prop = parseBonusProportionalFlag(d)
        return BeamioRechargeBonusRule(paymentAmount: pay, bonusValue: bonus, bonusProportional: prop)
    }

    private static func parsePositiveMoneyField(_ v: Any?) -> Double? {
        let x: Double? = {
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String {
                let t = s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                return Double(t)
            }
            return nil
        }()
        guard let x, x.isFinite, x > 0 else { return nil }
        return (x * 100).rounded() / 100
    }

    private static func parseNonNegativeMoneyField(_ v: Any?) -> Double? {
        let x: Double? = {
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String {
                let t = s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                return Double(t)
            }
            return nil
        }()
        guard let x, x.isFinite, x >= 0 else { return nil }
        return (x * 100).rounded() / 100
    }

    private static let couponListDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }()

    private static func isPlausibleEvmAddress(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.hasPrefix("0x"), s.count == 42 else { return false }
        return s.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    private static func parseCouponMetaU64(_ any: Any?) -> UInt64? {
        if let n = any as? NSNumber {
            if n.doubleValue < 0 || n.doubleValue > Double(UInt64.max) { return nil }
            return n.uint64Value
        }
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t.allSatisfy(\.isNumber), let v = UInt64(t) else { return nil }
            return v
        }
        return nil
    }

    private static func couponDisplayTitle(metadata: Any?, tokenId: String) -> String {
        guard let meta = metadata as? [String: Any] else { return Self.couponUntitledLabel(tokenId: tokenId) }
        for key in ["name", "title"] {
            if let s = meta[key] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        if let s = meta["couponId"] as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if let props = meta["properties"] as? [String: Any],
           let bc = props["beamioCoupon"] as? [String: Any]
        {
            if let s = bc["couponId"] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return Self.couponUntitledLabel(tokenId: tokenId)
    }

    private static func couponIdFromMetadata(_ metadata: Any?) -> String? {
        guard let meta = metadata as? [String: Any] else { return nil }
        if let s = meta["couponId"] as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if let props = meta["properties"] as? [String: Any],
           let bc = props["beamioCoupon"] as? [String: Any],
           let s = bc["couponId"] as? String
        {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }

    private static func parseTruthyFlag(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return t == "true" || t == "1"
        }
        return false
    }

    private static func couponRequiresRedeemCode(metadata: Any?) -> Bool {
        guard let meta = metadata as? [String: Any] else { return false }
        if parseTruthyFlag(meta["requiresRedeemCode"]) || parseTruthyFlag(meta["redeemCodeRequired"]) {
            return true
        }
        if let props = meta["properties"] as? [String: Any],
           let bc = props["beamioCoupon"] as? [String: Any]
        {
            if parseTruthyFlag(bc["requiresRedeemCode"]) || parseTruthyFlag(bc["redeemCodeRequired"]) {
                return true
            }
        }
        return false
    }

    private static func couponVisualSubtitle(metadata: Any?) -> String? {
        guard let meta = metadata as? [String: Any] else { return nil }
        let pick: ([String: Any], [String]) -> String? = { src, keys in
            for k in keys {
                if let s = src[k] as? String {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { return t }
                }
            }
            return nil
        }
        if let direct = pick(meta, ["subtitle", "merchantName", "brandName", "storeName"]) { return direct }
        if let props = meta["properties"] as? [String: Any],
           let bc = props["beamioCoupon"] as? [String: Any]
        {
            if let nested = pick(bc, ["subtitle", "merchantName", "brandName", "storeName"]) { return nested }
        }
        return nil
    }

    private static func couponVisualIconUrl(metadata: Any?) -> String? {
        guard let meta = metadata as? [String: Any] else { return nil }
        let pick: ([String: Any], [String]) -> String? = { src, keys in
            for k in keys {
                if let s = src[k] as? String {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") { return t }
                }
            }
            return nil
        }
        if let direct = pick(meta, ["icon", "iconUrl", "logo", "logoUrl", "image"]) { return direct }
        if let props = meta["properties"] as? [String: Any],
           let bc = props["beamioCoupon"] as? [String: Any]
        {
            if let nested = pick(bc, ["icon", "iconUrl", "logo", "logoUrl", "image"]) { return nested }
        }
        return nil
    }

    private static func couponVisualBackgroundImageUrl(metadata: Any?) -> String? {
        guard let meta = metadata as? [String: Any] else { return nil }
        let pick: ([String: Any], [String]) -> String? = { src, keys in
            for k in keys {
                if let s = src[k] as? String {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") { return t }
                }
            }
            return nil
        }
        if let direct = pick(meta, ["background", "backgroundImage", "backgroundImageUrl", "cover", "coverImage"]) { return direct }
        if let props = meta["properties"] as? [String: Any],
           let bc = props["beamioCoupon"] as? [String: Any]
        {
            if let nested = pick(bc, ["background", "backgroundImage", "backgroundImageUrl", "cover", "coverImage"]) { return nested }
        }
        return nil
    }

    private static func couponVisualBackgroundColorHex(metadata: Any?) -> String? {
        guard let meta = metadata as? [String: Any] else { return nil }
        let pick: ([String: Any], [String]) -> String? = { src, keys in
            for k in keys {
                if let s = src[k] as? String {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { return t }
                }
            }
            return nil
        }
        if let direct = pick(meta, ["backgroundColor", "bgColor", "color"]) { return direct }
        if let props = meta["properties"] as? [String: Any],
           let bc = props["beamioCoupon"] as? [String: Any]
        {
            if let nested = pick(bc, ["backgroundColor", "bgColor", "color"]) { return nested }
        }
        return nil
    }

    private static func couponUntitledLabel(tokenId: String) -> String {
        let t = tokenId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 6 else { return "Program coupon" }
        let tail = String(t.suffix(6))
        return "Program coupon #\(tail)"
    }

    private static func couponValiditySummary(afterSec: UInt64?, beforeSec: UInt64?) -> String {
        let df = couponListDateFormatter
        let fmt: (UInt64) -> String = { s in
            df.string(from: Date(timeIntervalSince1970: TimeInterval(s)))
        }
        let va = afterSec.flatMap { $0 > 0 ? $0 : nil }
        let vb = beforeSec.flatMap { $0 > 0 ? $0 : nil }
        switch (va, vb) {
        case (nil, nil):
            return "Open-ended validity"
        case (nil, let b?):
            return "Valid until \(fmt(b))"
        case (let a?, nil):
            return "Valid from \(fmt(a))"
        case (let a?, let b?):
            return "Valid \(fmt(a)) – \(fmt(b))"
        }
    }

    /// API may emit `tokenId` as JSON string or number; both must parse or every row becomes empty → no POS coupon icon.
    private static func couponTokenIdString(from any: Any?) -> String? {
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = any as? NSNumber {
            let t = n.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    private static func couponFirstNonEmptyNumericString(_ map: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if let v = couponTokenIdString(from: map[k]) { return v }
        }
        return nil
    }

    private static func couponMetadataBeamioCoupon(_ metadata: Any?) -> [String: Any]? {
        guard let meta = metadata as? [String: Any] else { return nil }
        if let props = meta["properties"] as? [String: Any],
           let beamioCoupon = props["beamioCoupon"] as? [String: Any]
        {
            return beamioCoupon
        }
        return nil
    }

    private static func couponMetadataRoot(_ metadata: Any?) -> [String: Any]? {
        metadata as? [String: Any]
    }

    private static func couponRemainingFromMaxAndMinted(maxSupply: String?, mintedCount: String?) -> String? {
        guard let maxSupply, let mintedCount,
              let maxDec = Decimal(string: maxSupply),
              let mintedDec = Decimal(string: mintedCount)
        else { return nil }
        let remain = maxDec - mintedDec
        if remain <= 0 { return "0" }
        return NSDecimalNumber(decimal: remain).stringValue
    }

    private static func parseMerchantActiveIssuedCouponRow(_ d: [String: Any]) -> MerchantActiveIssuedCoupon? {
        let card = (d["cardAddress"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard isPlausibleEvmAddress(card) else { return nil }
        guard let tokenId = couponTokenIdString(from: d["tokenId"]), !tokenId.isEmpty else { return nil }
        let metadata = d["metadata"]
        let couponId = couponIdFromMetadata(metadata)
        let requiresRedeem = couponRequiresRedeemCode(metadata: metadata)
        let after = parseCouponMetaU64(d["issuedNftValidAfter"])
        let before = parseCouponMetaU64(d["issuedNftValidBefore"])
        let metadataRoot = couponMetadataRoot(metadata)
        let beamioCoupon = couponMetadataBeamioCoupon(metadata)
        let maxSupply = couponFirstNonEmptyNumericString(
            d,
            keys: ["issuedNftMaxSupply", "maxSupply", "issuedNftSupply", "totalSupply", "supply"]
        )
            ?? (metadataRoot.flatMap { couponFirstNonEmptyNumericString($0, keys: ["issueTotal", "maxSupply", "totalSupply", "supply"]) })
            ?? (beamioCoupon.flatMap { couponFirstNonEmptyNumericString($0, keys: ["issueTotal", "maxSupply", "totalSupply", "supply"]) })
        let mintedCount = couponFirstNonEmptyNumericString(
            d,
            keys: ["issuedNftMintedCount", "mintedCount", "issuedCount", "claimedCount", "minted"]
        )
            ?? (metadataRoot.flatMap { couponFirstNonEmptyNumericString($0, keys: ["mintedCount", "issuedCount", "claimedCount", "minted", "issued"]) })
            ?? (beamioCoupon.flatMap { couponFirstNonEmptyNumericString($0, keys: ["mintedCount", "issuedCount", "claimedCount", "minted", "issued"]) })
        let remainingSupply = couponFirstNonEmptyNumericString(
            d,
            keys: ["issuedNftRemainingSupply", "remainingSupply", "leftSupply", "remaining", "availableSupply"]
        )
            ?? (metadataRoot.flatMap { couponFirstNonEmptyNumericString($0, keys: ["remainingSupply", "remaining", "leftSupply", "availableSupply", "issueLeft"]) })
            ?? (beamioCoupon.flatMap { couponFirstNonEmptyNumericString($0, keys: ["remainingSupply", "remaining", "leftSupply", "availableSupply", "issueLeft"]) })
            ?? couponRemainingFromMaxAndMinted(maxSupply: maxSupply, mintedCount: mintedCount)
        let createdAt = (d["createdAt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let title = couponDisplayTitle(metadata: metadata, tokenId: tokenId)
        let summary = couponValiditySummary(afterSec: after, beforeSec: before)
        let subtitle = couponVisualSubtitle(metadata: metadata)
        let iconUrl = couponVisualIconUrl(metadata: metadata)
        let backgroundImageUrl = couponVisualBackgroundImageUrl(metadata: metadata)
        let backgroundColorHex = couponVisualBackgroundColorHex(metadata: metadata)
        let id = "\(card.lowercased()):\(tokenId)"
        return MerchantActiveIssuedCoupon(
            id: id,
            cardAddress: card,
            tokenId: tokenId,
            couponId: couponId,
            requiresRedeemCode: requiresRedeem,
            issuedNftValidAfterSec: after,
            issuedNftValidBeforeSec: before,
            issuedNftMaxSupply: maxSupply,
            issuedNftMintedCount: mintedCount,
            issuedNftRemainingSupply: remainingSupply,
            createdAtIso: createdAt,
            displayTitle: title,
            validitySummary: summary,
            subtitle: subtitle,
            iconUrl: iconUrl,
            backgroundImageUrl: backgroundImageUrl,
            backgroundColorHex: backgroundColorHex
        )
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
        await Self.jsonRpcEthCallBase(session: session, to: to, dataHex: dataHex)
    }

    private static func jsonRpcEthCallBase(session: URLSession, to: String, dataHex: String) async -> String? {
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

    private static func jsonRpcEthCallConet(session: URLSession, to: String, dataHex: String) async -> String? {
        let toLower = to.hasPrefix("0x") ? to.lowercased() : "0x\(to.lowercased())"
        let data = dataHex.hasPrefix("0x") ? dataHex.lowercased() : "0x\(dataHex.lowercased())"
        guard let url = URL(string: BeamioConstants.conetMainnetRpcUrl) else { return nil }
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

    private static func buildErc20BalanceOfCalldata(addressLower: String) -> String {
        "0x70a08231" + String(repeating: "0", count: 24) + addressLower.lowercased()
    }

    private static let ethCallErc20DecimalsSelector = "0x313ce567"

    /// Cumulative stats: `periodType = 0`, `anchorTs = 0`, `cumulativeStartTs = 0` (biz `fetchBizTerminalChainStats`).
    private static func buildGetAdminStatsFullAllTimeCalldata(adminAddrLower: String) -> String {
        let addrPadded = String(repeating: "0", count: 24) + adminAddrLower.lowercased()
        let z = String(repeating: "0", count: 64)
        return "0x9abc4888" + addrPadded + z + z + z
    }

    private static let ethCallGetAdminAirdropLimitSelector = "0xd1d32620"

    private static func buildGetAdminAirdropLimitCalldata(adminAddrLower: String) -> String {
        let addrPadded = String(repeating: "0", count: 24) + adminAddrLower.lowercased()
        return ethCallGetAdminAirdropLimitSelector + addrPadded
    }

    /// `AdminAirdropLimitView`: words 4–5 are `remainingAvailable`, `unlimited`.
    private static func decodeGetAdminAirdropLimitResult(hex: String) -> (unlimited: Bool, remainingRaw: Double)? {
        var raw = hex
        if raw.hasPrefix("0x") { raw = String(raw.dropFirst(2)) }
        guard raw.count >= 64 * 6 else { return nil }
        let w4 = wordHex64(from: raw, index: 4)
        let w5 = wordHex64(from: raw, index: 5)
        let remainingRaw = abiUInt256HexToDouble(w4)
        let unlimited = !isAllZeroHex64(w5)
        return (unlimited, remainingRaw)
    }

    /// biz `parseGetAdminStatsFullReturnHex`: first word = byte offset to struct; `mintCounterFromClear` at `base + 16`.
    private static func parseMintCounterFromClearFromGetAdminStatsFull(hex: String) -> Double? {
        var raw = hex
        if raw.hasPrefix("0x") { raw = String(raw.dropFirst(2)) }
        guard raw.count >= 64 else { return nil }
        let offWord = wordHex64(from: raw, index: 0)
        let structOffset = abiUInt256HexToDouble(offWord)
        guard structOffset >= 0, structOffset.truncatingRemainder(dividingBy: 32) == 0 else { return nil }
        let base = Int(structOffset / 32)
        let idx = base + 16
        guard raw.count >= (idx + 1) * 64 else { return nil }
        let mintW = wordHex64(from: raw, index: idx)
        return abiUInt256HexToDouble(mintW)
    }

    private static func wordHex64(from rawNo0x: String, index: Int) -> String {
        let start = rawNo0x.index(rawNo0x.startIndex, offsetBy: index * 64)
        let end = rawNo0x.index(start, offsetBy: 64)
        return String(rawNo0x[start ..< end])
    }

    private static func isAllZeroHex64(_ hex64: String) -> Bool {
        hex64.allSatisfy { $0 == "0" }
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
