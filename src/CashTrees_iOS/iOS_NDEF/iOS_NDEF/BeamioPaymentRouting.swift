import Foundation

/// 对齐 Android `MainActivity` 中 Charge 金额与 container 拆分逻辑（oracle / prepare `unitPriceUSDC6` 点桶 / 纯基础设施点桶 / USDC）
enum BeamioPaymentRouting {
    struct OracleRates {
        var usdcad: Double = 1.35
        var usdeur: Double = 0.92
        var usdjpy: Double = 150
        var usdcny: Double = 7.2
        var usdhkd: Double = 7.8
        var usdsgd: Double = 1.35
        var usdtwd: Double = 31
    }

    static func getRateForCurrency(_ currency: String, oracle: OracleRates) -> Double {
        switch currency.uppercased() {
        case "CAD": return oracle.usdcad
        case "USD", "USDC": return 1.0
        case "EUR": return oracle.usdeur
        case "JPY": return oracle.usdjpy
        case "CNY": return oracle.usdcny
        case "HKD": return oracle.usdhkd
        case "SGD": return oracle.usdsgd
        case "TWD": return oracle.usdtwd
        default: return oracle.usdcad
        }
    }

    static func points6ToUsdc6(points6: Int64, cardCurrency: String, oracle: OracleRates) -> Int64 {
        if points6 <= 0 { return 0 }
        let rate = getRateForCurrency(cardCurrency, oracle: oracle)
        if rate <= 0 { return 0 }
        return Int64((Double(points6) / rate).rounded(.towardZero))
    }

    static func currencyToUsdc6(amount: Double, currency: String, oracle: OracleRates) -> String {
        if amount <= 0 { return "0" }
        let rate = getRateForCurrency(currency, oracle: oracle)
        if rate <= 0 { return "0" }
        let usdc = amount / rate
        return String(Int64((usdc * 1_000_000.0).rounded(.towardZero)))
    }

    /// Inverse of `currencyToUsdc6` (pay-currency amount from USDC6 micro units).
    static func usdc6ToCurrencyAmount(usdc6: Int64, currency: String, oracle: OracleRates) -> Double {
        if usdc6 <= 0 { return 0 }
        let rate = getRateForCurrency(currency, oracle: oracle)
        if rate <= 0 { return 0 }
        return (Double(usdc6) / 1_000_000.0) * rate
    }

    /// Clamp tier discount to 0–100 and two fractional digits (metadata / charge parity).
    static func normalizeTierDiscountPercent(_ v: Double) -> Double {
        let c = min(100, max(0, v))
        return (c * 100).rounded() / 100
    }

    /// Basis points for `nfcDiscountRateBps` / open-container bill (100% = 10_000 bps).
    static func tierDiscountBasisPoints(_ percent: Double) -> Int {
        let p = normalizeTierDiscountPercent(percent)
        return min(10_000, max(0, Int((p * 100.0).rounded())))
    }

    /// total = request + tax%*request - tier%*request + tip（tip 基于税前 request）
    static func chargeTotalInCurrency(requestAmount: Double, taxPercent: Double, tierDiscountPercent: Double, tipAmount: Double) -> Double {
        let tax = requestAmount * (taxPercent / 100.0)
        let p = normalizeTierDiscountPercent(tierDiscountPercent)
        let disc = requestAmount * (p / 100.0)
        return requestAmount + tax - disc + tipAmount
    }

    static func chargeTipFromRequestAndBps(requestAmount: Double, tipRateBps: Int) -> Double {
        let bps = max(0, min(10_000, tipRateBps))
        return requestAmount * (Double(bps) / 10_000.0)
    }

    struct ChargeableSplit {
        var ccsaPointsWei: Int64
        var infraPointsWei: Int64
        var usdcWei: Int64
    }

    /// 参与 Charge 的全部卡行：以服务端 `cards[]` 为准（含独立部署的 BeamioUserCard），不再按 `ccsa` 或终端 infra 地址硬筛。
    static func chargeableCards(from assets: UIDAssets, infraCard: String) -> [CardItem] {
        if let cards = assets.cards, !cards.isEmpty {
            return cards
        }
        let addr = assets.cardAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if addr.isEmpty { return [] }
        return [
            CardItem(
                cardAddress: addr,
                cardName: "Asset Card",
                cardType: "",
                points: assets.points ?? "0",
                points6: assets.points6 ?? "0",
                cardCurrency: assets.cardCurrency ?? "CAD",
                nfts: assets.nfts ?? [],
                cardBackground: nil,
                cardImage: nil,
                tierName: nil,
                tierDescription: nil,
                primaryMemberTokenId: {
                    let s = assets.primaryMemberTokenId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return s.isEmpty ? nil : s
                }(),
                tierDiscountPercent: nil
            ),
        ]
    }

    /// 拆分点余额：`unitPrice` 桶走 prepare 返回的 `unitPriceUSDC6`（BeamioUserCard / 程序卡行）；`oracleInfra` 桶为 **他址** 的纯 infrastructure 行（oracle 折 USDC）。
    static func partitionPointsForMerchantCharge(cards: [CardItem], merchantInfraCard: String) -> (unitPricePoints6: Int64, oracleInfraCards: [CardItem]) {
        var unitSum: Int64 = 0
        var oracle: [CardItem] = []
        let infraKey = merchantInfraCard.trimmingCharacters(in: .whitespacesAndNewlines)
        for c in cards {
            let p = Int64(c.points6) ?? 0
            if p <= 0 { continue }
            let t = c.cardType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let sameTerminalInfra = !infraKey.isEmpty && c.cardAddress.caseInsensitiveCompare(merchantInfraCard) == .orderedSame
            if t == "infrastructure", !sameTerminalInfra {
                oracle.append(c)
            } else {
                unitSum += p
            }
        }
        return (unitSum, oracle)
    }

    static func computeChargeContainerSplit(
        amountBig: Int64,
        chargeTotalInPayCurrency: Double,
        payCurrency: String,
        oracle: OracleRates,
        unitPriceUSDC6: Int64,
        ccsaPoints6: Int64,
        infraPoints6: Int64,
        infraCardCurrency: String?,
        usdcBalance6: Int64
    ) -> ChargeableSplit {
        if amountBig <= 0 { return ChargeableSplit(ccsaPointsWei: 0, infraPointsWei: 0, usdcWei: 0) }
        var remaining = amountBig
        var ccsaPointsWei: Int64 = 0

        if ccsaPoints6 > 0, unitPriceUSDC6 > 0 {
            let maxPointsFromAmount = (remaining * 1_000_000) / unitPriceUSDC6
            ccsaPointsWei = min(maxPointsFromAmount, ccsaPoints6)
            let ccsaValue = (ccsaPointsWei * unitPriceUSDC6) / 1_000_000
            remaining -= ccsaValue
            if usdcBalance6 == 0, remaining > 0, ccsaPoints6 > ccsaPointsWei {
                let ccsaPointsCeil = (amountBig * 1_000_000 + unitPriceUSDC6 - 1) / unitPriceUSDC6
                if ccsaPointsCeil <= ccsaPoints6 {
                    ccsaPointsWei = ccsaPointsCeil
                    remaining = amountBig - (ccsaPointsWei * unitPriceUSDC6) / 1_000_000
                }
            }
        }

        let remainingAfterCcsa = remaining
        let ccsaConsumedUsdc6 = amountBig - remainingAfterCcsa
        var infraPointsWei: Int64 = 0
        let payCur = payCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let infraCur = infraCardCurrency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var infraFromFiat = false

        if remainingAfterCcsa > 0, infraPoints6 > 0, let infraCur, !infraCur.isEmpty {
            if infraCur == payCur, chargeTotalInPayCurrency > 0 {
                let r = getRateForCurrency(payCur, oracle: oracle)
                if r > 0 {
                    let totalFiat6 = Int64((chargeTotalInPayCurrency * 1_000_000.0).rounded())
                    let remainingFiat6 = max(0, totalFiat6 - Int64((Double(ccsaConsumedUsdc6) * r).rounded()))
                    infraPointsWei = min(infraPoints6, remainingFiat6)
                    let infraUsdc6Equiv = points6ToUsdc6(points6: infraPointsWei, cardCurrency: payCur, oracle: oracle)
                    remaining = max(0, remainingAfterCcsa - infraUsdc6Equiv)
                    infraFromFiat = true
                }
            }
            if !infraFromFiat {
                let rate = getRateForCurrency(infraCur, oracle: oracle)
                if rate > 0 {
                    let infraValueUsdc6Total = points6ToUsdc6(points6: infraPoints6, cardCurrency: infraCur, oracle: oracle)
                    let infraValueUsdc6Needed = min(remainingAfterCcsa, infraValueUsdc6Total)
                    infraPointsWei = Int64(
                        ceil(Double(infraValueUsdc6Needed) * Double(rate))
                    )
                    infraPointsWei = max(0, min(infraPointsWei, infraPoints6))
                    let used = points6ToUsdc6(points6: infraPointsWei, cardCurrency: infraCur, oracle: oracle)
                    remaining = max(0, remainingAfterCcsa - used)
                    if remaining > 0, usdcBalance6 == 0, infraPointsWei < infraPoints6 {
                        let extra = Int64(ceil(Double(remaining) * Double(rate)))
                        let add = max(0, min(extra, infraPoints6 - infraPointsWei))
                        infraPointsWei += add
                        remaining = 0
                    }
                }
            }
        }

        var usdcWei = max(0, remaining)
        if usdcWei > 0, usdcBalance6 == 0, infraPoints6 > 0, infraPointsWei < infraPoints6 {
            let rate = getRateForCurrency(infraCardCurrency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? payCur, oracle: oracle)
            if rate > 0 {
                let extra = Int64(ceil(Double(usdcWei) * Double(rate)))
                let add = max(0, min(extra, infraPoints6 - infraPointsWei))
                infraPointsWei += add
                usdcWei = 0
            }
        }

        return ChargeableSplit(ccsaPointsWei: ccsaPointsWei, infraPointsWei: infraPointsWei, usdcWei: usdcWei)
    }

    // MARK: - fiat6-only Charge Protocol (see .cursor/rules/beamio-charge-fiat-only-protocol.mdc)

    /// 把账单 currency（如 "50.00" CAD）按 6 位定点直接换成 fiat6 字符串；不做任何 oracle / USDC 换算。
    /// 客户端在 fiat6-only 协议下，唯一获取 amountFiat6 的入口。
    static func currencyToFiat6(amount: Double) -> String {
        if amount <= 0 { return "0" }
        return String(Int64((amount * 1_000_000.0).rounded()))
    }

    /// fiat6-only Charge 路由：当 `payCurrency == cardCurrency` 时，CCSA / 程序卡桶直接以
    /// `ceil(amountFiat6 * 1e6 / pointsUnitPriceInCurrencyE6)` 为 `items[].amount`，零 oracle / 零除回 USDC 漂移。
    /// 跨币种或跨基础设施卡仍走 oracle（未消的 oracle 漂移由 fiat6-only 协议明确不接受 — 调用方应在 UI 层拒绝跨币种 charge）。
    /// - Parameters:
    ///   - amountFiat6: 账单总额（卡币种 6 位定点）
    ///   - payCurrency: UI 输入币种
    ///   - cardCurrency: prepare 返回的 BeamioUserCard.currency()
    ///   - pointsUnitPriceInCurrencyE6: prepare 返回的 BeamioUserCard.pointsUnitPriceInCurrencyE6()
    ///   - ccsaPoints6 / infraPoints6 / infraCardCurrency / usdcBalance6: 与 `computeChargeContainerSplit` 同
    ///   - oracle: 仅用于跨币种基础设施卡 / USDC 等价折算（fiat6-only 协议下当 ccsa 路径完整覆盖时不会被命中）
    ///   - unitPriceUSDC6Fallback: 旧 `unitPriceUSDC6`，当 prepare 未返回 `pointsUnitPriceInCurrencyE6` 时回退使用（向后兼容）
    static func computeChargeContainerSplitFiat6(
        amountFiat6: Int64,
        payCurrency: String,
        cardCurrency: String?,
        pointsUnitPriceInCurrencyE6: Int64,
        ccsaPoints6: Int64,
        infraPoints6: Int64,
        infraCardCurrency: String?,
        usdcBalance6: Int64,
        oracle: OracleRates,
        unitPriceUSDC6Fallback: Int64
    ) -> ChargeableSplit {
        if amountFiat6 <= 0 { return ChargeableSplit(ccsaPointsWei: 0, infraPointsWei: 0, usdcWei: 0) }
        let payCur = payCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let cardCur = (cardCurrency ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let priceE6 = pointsUnitPriceInCurrencyE6 > 0 ? pointsUnitPriceInCurrencyE6 : unitPriceUSDC6Fallback

        var remainingFiat6 = amountFiat6
        var ccsaPointsWei: Int64 = 0
        if ccsaPoints6 > 0, priceE6 > 0, !cardCur.isEmpty, payCur == cardCur {
            let needCeil = (remainingFiat6 * 1_000_000 + priceE6 - 1) / priceE6
            ccsaPointsWei = min(needCeil, ccsaPoints6)
            let consumedFiat6 = (ccsaPointsWei * priceE6) / 1_000_000
            remainingFiat6 = max(0, remainingFiat6 - consumedFiat6)
        }

        var infraPointsWei: Int64 = 0
        let infraCur = infraCardCurrency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if remainingFiat6 > 0, infraPoints6 > 0, let infraCur, !infraCur.isEmpty {
            if infraCur == payCur, priceE6 > 0 {
                let needCeil = (remainingFiat6 * 1_000_000 + priceE6 - 1) / priceE6
                infraPointsWei = min(needCeil, infraPoints6)
                let consumedFiat6 = (infraPointsWei * priceE6) / 1_000_000
                remainingFiat6 = max(0, remainingFiat6 - consumedFiat6)
            } else {
                let payRate = getRateForCurrency(payCur, oracle: oracle)
                let infraRate = getRateForCurrency(infraCur, oracle: oracle)
                if payRate > 0, infraRate > 0 {
                    let remainingUsdc6 = Int64((Double(remainingFiat6) / payRate).rounded(.towardZero))
                    let infraValueUsdc6 = points6ToUsdc6(points6: infraPoints6, cardCurrency: infraCur, oracle: oracle)
                    let needUsdc6 = min(remainingUsdc6, infraValueUsdc6)
                    infraPointsWei = Int64(ceil(Double(needUsdc6) * infraRate))
                    infraPointsWei = max(0, min(infraPointsWei, infraPoints6))
                    let usedUsdc6 = points6ToUsdc6(points6: infraPointsWei, cardCurrency: infraCur, oracle: oracle)
                    let usedFiat6 = Int64((Double(usedUsdc6) * payRate).rounded(.towardZero))
                    remainingFiat6 = max(0, remainingFiat6 - usedFiat6)
                }
            }
        }

        var usdcWei: Int64 = 0
        if remainingFiat6 > 0 {
            let payRate = getRateForCurrency(payCur, oracle: oracle)
            if payRate > 0 {
                usdcWei = Int64((Double(remainingFiat6) / payRate).rounded(.up))
                usdcWei = max(0, min(usdcWei, max(0, usdcBalance6)))
            }
        }

        return ChargeableSplit(ccsaPointsWei: ccsaPointsWei, infraPointsWei: infraPointsWei, usdcWei: usdcWei)
    }

    /// 与 `buildPayItems` 形参一致，但不再要求 `amountUsdc6`（fiat6-only 协议下兜底 USDC 项需服务端从 fiat 折算填入）。
    static func buildPayItemsFiat6(
        split: ChargeableSplit,
        infraCard: String
    ) -> [[String: Any]] {
        var items: [[String: Any]] = []
        if split.usdcWei > 0 {
            items.append([
                "kind": 0,
                "asset": BeamioConstants.usdcBase,
                "amount": String(split.usdcWei),
                "tokenId": "0",
                "data": "0x",
            ])
        }
        if split.ccsaPointsWei > 0 {
            items.append([
                "kind": 1,
                "asset": infraCard,
                "amount": String(split.ccsaPointsWei),
                "tokenId": "0",
                "data": "0x",
            ])
        }
        if split.infraPointsWei > 0 {
            items.append([
                "kind": 1,
                "asset": infraCard,
                "amount": String(split.infraPointsWei),
                "tokenId": "0",
                "data": "0x",
            ])
        }
        return items
    }

    static func buildPayItems(
        amountUsdc6: String,
        split: ChargeableSplit,
        infraCard: String
    ) -> [[String: Any]] {
        var items: [[String: Any]] = []
        if split.usdcWei > 0 {
            items.append([
                "kind": 0,
                "asset": BeamioConstants.usdcBase,
                "amount": String(split.usdcWei),
                "tokenId": "0",
                "data": "0x",
            ])
        }
        if split.ccsaPointsWei > 0 {
            items.append([
                "kind": 1,
                "asset": infraCard,
                "amount": String(split.ccsaPointsWei),
                "tokenId": "0",
                "data": "0x",
            ])
        }
        if split.infraPointsWei > 0 {
            items.append([
                "kind": 1,
                "asset": infraCard,
                "amount": String(split.infraPointsWei),
                "tokenId": "0",
                "data": "0x",
            ])
        }
        if items.isEmpty {
            items.append([
                "kind": 0,
                "asset": BeamioConstants.usdcBase,
                "amount": amountUsdc6,
                "tokenId": "0",
                "data": "0x",
            ])
        }
        return items
    }

    /// 与 Android NFC 路径一致：拆成两条 kind 1 时合并为单条 kind 1（避免双条同 asset）
    static func mergeInfraKind1Items(_ items: [[String: Any]], infraCard: String) -> [[String: Any]] {
        var usdc: [String: Any]?
        var infraSum: Int64 = 0
        var others: [[String: Any]] = []
        for it in items {
            let kind = (it["kind"] as? Int) ?? 0
            let asset = (it["asset"] as? String) ?? ""
            if kind == 0 {
                usdc = it
                continue
            }
            if kind == 1, asset.caseInsensitiveCompare(infraCard) == .orderedSame {
                let a = Int64((it["amount"] as? String) ?? "0") ?? 0
                infraSum += max(0, a)
            } else {
                others.append(it)
            }
        }
        var out: [[String: Any]] = []
        if let usdc { out.append(usdc) }
        if infraSum > 0 {
            out.append([
                "kind": 1,
                "asset": infraCard,
                "amount": String(infraSum),
                "tokenId": "0",
                "data": "0x",
            ])
        }
        out.append(contentsOf: others)
        return out.isEmpty ? items : out
    }

    /// Android `totalBalanceCadFromAssets`：USDC + 各卡 points6 折 USDC6 后换算为 CAD 展示额
    static func totalBalanceCad(from assets: UIDAssets, oracle: OracleRates) -> Double {
        let usdcBalance6 = Int64(((Double(assets.usdcBalance ?? "0") ?? 0) * 1_000_000.0).rounded())
        let cardsValueUsdc6: Int64
        if let cards = assets.cards, !cards.isEmpty {
            cardsValueUsdc6 = cards.reduce(0) { partial, card in
                partial + points6ToUsdc6(points6: Int64(card.points6) ?? 0, cardCurrency: card.cardCurrency, oracle: oracle)
            }
        } else {
            let pts6 = Int64(assets.points6 ?? "0") ?? 0
            let cur = assets.cardCurrency ?? "CAD"
            cardsValueUsdc6 = points6ToUsdc6(points6: pts6, cardCurrency: cur, oracle: oracle)
        }
        let totalBalance6 = usdcBalance6 + cardsValueUsdc6
        let rCad = getRateForCurrency("CAD", oracle: oracle)
        return (Double(totalBalance6) / 1_000_000.0) * rCad
    }

    /// Android QR 成功页：扣款含基础设施点数时用该卡 points 折 CAD；否则用 `totalBalanceCad`
    static func postPaymentBalanceCad(
        from assets: UIDAssets,
        oracle: OracleRates,
        infraCard: String,
        useInfraCardRow: Bool
    ) -> Double? {
        guard assets.ok else { return nil }
        if useInfraCardRow,
           let card = assets.cards?.first(where: { $0.cardAddress.caseInsensitiveCompare(infraCard) == .orderedSame })
        {
            let pts6 = Int64(card.points6) ?? 0
            let rCard = getRateForCurrency(card.cardCurrency, oracle: oracle)
            let rCad = getRateForCurrency("CAD", oracle: oracle)
            guard rCard > 0 else { return nil }
            return (Double(pts6) / 1_000_000.0) * rCad / rCard
        }
        return totalBalanceCad(from: assets, oracle: oracle)
    }

    // MARK: - Tier discount (Android `pickChargeTierDiscountPercentForPaymentCard` / metadata.tiers)

    struct MetadataTierRow: Equatable {
        var minUsdc6: Int64
        var chainTierIndex: Int?
        var discountPercent: Double?
        var name: String?
        var description: String?
        /// Card-level `metadata.tiers[].backgroundColor`（与 getUIDAssets 卡行 `cardBackground` 同源补全）
        var backgroundColor: String?
        var image: String?
    }

    static func parseMetadataTierRows(metadataTiersArray: [Any]) -> [MetadataTierRow] {
        var out: [MetadataTierRow] = []
        for any in metadataTiersArray {
            guard let t = any as? [String: Any] else { continue }
            let minU: Int64 = {
                if let n = t["minUsdc6"] as? NSNumber { return n.int64Value }
                if let s = t["minUsdc6"] as? String, let v = Int64(s) { return v }
                return 0
            }()
            let chainIdx: Int? = {
                if let n = t["index"] as? NSNumber { return n.intValue }
                if let s = t["index"] as? String { return Int(s) }
                return nil
            }()
            let disc: Double? = {
                if t["discountPercent"] == nil || t["discountPercent"] is NSNull { return nil }
                if let n = t["discountPercent"] as? NSNumber { return normalizeTierDiscountPercent(n.doubleValue) }
                if let s = t["discountPercent"] as? String, let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return normalizeTierDiscountPercent(v)
                }
                return nil
            }()
            let name = (t["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let desc = (t["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let bgRaw = (t["backgroundColor"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let imgRaw = (t["image"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            out.append(MetadataTierRow(
                minUsdc6: max(0, minU),
                chainTierIndex: chainIdx,
                discountPercent: disc,
                name: name,
                description: desc,
                backgroundColor: bgRaw,
                image: imgRaw
            ))
        }
        return out.sorted { $0.minUsdc6 < $1.minUsdc6 }
    }

    private static func chainTierIndexCandidates(from nft: NftItem) -> [Int] {
        var ordered: [Int] = []
        let tierRaw = nft.tier.trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = Int(tierRaw) { ordered.append(v) }
        if let r = try? NSRegularExpression(pattern: "(?i)chain-tier-(\\d+)"),
           let m = r.firstMatch(in: tierRaw, range: NSRange(tierRaw.startIndex ..< tierRaw.endIndex, in: tierRaw)),
           m.numberOfRanges > 1,
           let rg = Range(m.range(at: 1), in: tierRaw),
           let idx = Int(tierRaw[rg])
        {
            ordered.append(idx)
        }
        let attr = nft.attribute.trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = Int(attr) { ordered.append(v) }
        var seen = Set<Int>()
        var uniq: [Int] = []
        for i in ordered where !seen.contains(i) {
            seen.insert(i)
            uniq.append(i)
        }
        return uniq
    }

    /// Android `selectMetadataTierForPrimaryMembership`
    static func selectMetadataTierForPrimaryMembership(card: CardItem, tiers: [MetadataTierRow]) -> MetadataTierRow? {
        if tiers.isEmpty { return nil }
        let primaryTid: String? = {
            let p = card.primaryMemberTokenId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !p.isEmpty, (Int64(p) ?? 0) > 0 { return p }
            let best = card.nfts
                .filter { (Int64($0.tokenId) ?? 0) > 0 }
                .max(by: { (Int64($0.tokenId) ?? 0) < (Int64($1.tokenId) ?? 0) })?
                .tokenId
            if let best, (Int64(best) ?? 0) > 0 { return best }
            return nil
        }()
        guard let tid = primaryTid,
              let primaryNft = card.nfts.first(where: { $0.tokenId == tid || $0.tokenId.caseInsensitiveCompare(tid) == .orderedSame })
        else { return nil }
        for idx in chainTierIndexCandidates(from: primaryNft) {
            if let row = tiers.first(where: { $0.chainTierIndex == idx }) { return row }
        }
        let tierLabel = primaryNft.tier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tierLabel.isEmpty, Int(tierLabel) == nil,
           tierLabel.range(of: "(?i)chain-tier-\\d+", options: .regularExpression) == nil,
           let row = tiers.first(where: { ($0.name ?? "").caseInsensitiveCompare(tierLabel) == .orderedSame })
        {
            return row
        }
        return nil
    }

    private static func discountPercentFromMetadataRow(_ row: MetadataTierRow) -> Double {
        if let d = row.discountPercent { return normalizeTierDiscountPercent(d) }
        return firstPercentInDescription(row.description) ?? 0
    }

    private static func firstPercentInDescription(_ text: String?) -> Double? {
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty { return nil }
        guard let r = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)\\s*%"),
              let m = r.firstMatch(in: t, range: NSRange(t.startIndex ..< t.endIndex, in: t)),
              m.numberOfRanges > 1,
              let rg = Range(m.range(at: 1), in: t)
        else { return nil }
        let num = Double(t[rg]) ?? 0
        return normalizeTierDiscountPercent(num)
    }

    /// Android `pickTierDiscountPercentFromAssets`
    static func pickTierDiscountPercentFromAssets(assets: UIDAssets, tierKeyToDiscount: [String: Double]) -> Double {
        if tierKeyToDiscount.isEmpty { return 0 }
        var keys = Set<String>()
        for c in assets.cards ?? [] {
            for n in c.nfts {
                let t = n.tier.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    keys.insert(t)
                    keys.insert(t.lowercased())
                }
            }
        }
        for n in assets.nfts ?? [] {
            let t = n.tier.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                keys.insert(t)
                keys.insert(t.lowercased())
            }
        }
        var best = 0.0
        for k in keys {
            if let v = tierKeyToDiscount[k] { best = max(best, v) }
            if let v = tierKeyToDiscount[k.lowercased()] { best = max(best, v) }
        }
        for k in keys {
            if let idx = Int(k) {
                if let v = tierKeyToDiscount["chain-tier-\(idx)".lowercased()] { best = max(best, v) }
            }
        }
        return normalizeTierDiscountPercent(best)
    }

    private static func normalizeMetadataBackgroundHex(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        if !s.hasPrefix("#") { s = "#\(s.replacingOccurrences(of: "#", with: ""))" }
        return s
    }

    /// 主会员档在 `metadata.tiers` 中命中行的视觉字段（Top-up 后 API 可能仍带旧 NFT 底色，需与档名对齐覆盖）。
    static func primaryTierMetadataVisuals(card: CardItem, tiers: [MetadataTierRow]) -> (backgroundHex: String?, imageUrl: String?) {
        guard !tiers.isEmpty, let row = selectMetadataTierForPrimaryMembership(card: card, tiers: tiers) else {
            return (nil, nil)
        }
        let bg = normalizeMetadataBackgroundHex(row.backgroundColor)
        let img = row.image?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return (bg, img)
    }

    static func mergePrimaryTierStyleFromCardMetadata(card: CardItem, tiers: [MetadataTierRow]) -> CardItem {
        let v = primaryTierMetadataVisuals(card: card, tiers: tiers)
        var bgOut = card.cardBackground
        var imgOut = card.cardImage
        if let bg = v.backgroundHex { bgOut = bg }
        if let img = v.imageUrl { imgOut = img }
        if bgOut == card.cardBackground && imgOut == card.cardImage { return card }
        return CardItem(
            cardAddress: card.cardAddress,
            cardName: card.cardName,
            cardType: card.cardType,
            points: card.points,
            points6: card.points6,
            cardCurrency: card.cardCurrency,
            nfts: card.nfts,
            cardBackground: bgOut,
            cardImage: imgOut,
            tierName: card.tierName,
            tierDescription: card.tierDescription,
            primaryMemberTokenId: card.primaryMemberTokenId,
            tierDiscountPercent: card.tierDiscountPercent
        )
    }

    /// Android `pickChargeTierDiscountPercentForPaymentCard`
    static func pickChargeTierDiscountPercent(
        paymentCard: CardItem?,
        assets: UIDAssets,
        discountByTierKey: [String: Double],
        metadataTiers: [MetadataTierRow],
        metadataTiersFromApi: Bool
    ) -> Double {
        let addr = paymentCard?.cardAddress.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !addr.isEmpty, let paymentCard, metadataTiersFromApi {
            if let row = selectMetadataTierForPrimaryMembership(card: paymentCard, tiers: metadataTiers) {
                return discountPercentFromMetadataRow(row)
            }
        }
        return pickTierDiscountPercentFromAssets(assets: assets, tierKeyToDiscount: discountByTierKey)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

extension BeamioAPIClient.OracleRates {
    func toPaymentOracle() -> BeamioPaymentRouting.OracleRates {
        BeamioPaymentRouting.OracleRates(
            usdcad: usdcad,
            usdeur: usdeur,
            usdjpy: usdjpy,
            usdcny: usdcny,
            usdhkd: usdhkd,
            usdsgd: usdsgd,
            usdtwd: usdtwd
        )
    }
}
