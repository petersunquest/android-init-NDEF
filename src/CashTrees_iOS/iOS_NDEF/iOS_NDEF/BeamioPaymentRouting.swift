import Foundation

/// 对齐 Android `MainActivity` 中 Charge 金额与 container 拆分逻辑（oracle / CCSA / 基础设施点 / USDC）
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

    /// total = request + tax%*request - tier%*request + tip（tip 基于税前 request）
    static func chargeTotalInCurrency(requestAmount: Double, taxPercent: Double, tierDiscountPercent: Int?, tipAmount: Double) -> Double {
        let tax = requestAmount * (taxPercent / 100.0)
        let disc = requestAmount * (Double(tierDiscountPercent ?? 0) / 100.0)
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

    static func chargeableCards(from assets: UIDAssets, infraCard: String) -> [CardItem] {
        let cards = assets.cards ?? []
        return cards.filter {
            $0.cardType == "ccsa" ||
                $0.cardAddress.caseInsensitiveCompare(infraCard) == .orderedSame ||
                $0.cardType == "infrastructure" ||
                $0.cardAddress.caseInsensitiveCompare(infraCard) == .orderedSame
        }
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
            var maxPointsFromAmount = (remaining * 1_000_000) / unitPriceUSDC6
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

    static func buildPayItems(
        amountUsdc6: String,
        split: ChargeableSplit,
        infraCard: String
    ) -> [[String: Any]] {
        let amountBig = Int64(amountUsdc6) ?? 0
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
