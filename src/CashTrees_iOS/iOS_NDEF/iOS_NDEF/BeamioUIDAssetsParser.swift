import Foundation

enum BeamioUIDAssetsParser {
    /// JSON may send numeric or string (align Android `optBeamioAmountString` / token fields).
    private static func coerceOptionalString(_ any: Any?) -> String? {
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

    private static func coerceOptionalInt(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    /// `tierDiscountPercent` from API — supports decimals; normalized to two fractional digits.
    private static func coerceOptionalTierDiscountPercent(_ any: Any?) -> Double? {
        if let n = any as? NSNumber {
            let v = n.doubleValue
            guard v > 0 else { return nil }
            return BeamioPaymentRouting.normalizeTierDiscountPercent(v)
        }
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let v = Double(t), v > 0 else { return nil }
            return BeamioPaymentRouting.normalizeTierDiscountPercent(v)
        }
        return nil
    }

    private static func coerceBool(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.intValue != 0 }
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return t == "true" || t == "1" || t == "yes"
        }
        return false
    }

    static func parse(data: Data) -> UIDAssets {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return UIDAssets(ok: false, error: "Failed to parse response")
        }
        return parse(root: obj)
    }

    static func parse(root: [String: Any]) -> UIDAssets {
        func s(_ k: String) -> String? {
            (root[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        let nfts: [NftItem]? = (root["nfts"] as? [[String: Any]]).map { arr in
            arr.map { o in
                NftItem(
                    tokenId: coerceOptionalString(o["tokenId"]) ?? "",
                    attribute: (o["attribute"] as? String) ?? "",
                    tier: (o["tier"] as? String) ?? "",
                    expiry: (o["expiry"] as? String) ?? "",
                    isExpired: (o["isExpired"] as? Bool) ?? false
                )
            }
        }

        let rawCards: [CardItem]? = {
            guard let cardsArr = root["cards"] as? [[String: Any]], !cardsArr.isEmpty else { return nil }
            func nonEmpty(_ any: Any?) -> String? {
                guard let s = any as? String else { return nil }
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            return cardsArr.compactMap { c -> CardItem? in
                let cnfts = c["nfts"] as? [[String: Any]] ?? []
                let nftList = cnfts.map { o in
                    NftItem(
                        tokenId: coerceOptionalString(o["tokenId"]) ?? "",
                        attribute: (o["attribute"] as? String) ?? "",
                        tier: (o["tier"] as? String) ?? "",
                        expiry: (o["expiry"] as? String) ?? "",
                        isExpired: (o["isExpired"] as? Bool) ?? false
                    )
                }
                let addr = (c["cardAddress"] as? String) ?? ""
                guard !addr.isEmpty else { return nil }
                let pointsStr = coerceOptionalString(c["points"]) ?? "0"
                let points6Str = coerceOptionalString(c["points6"]) ?? "0"
                return CardItem(
                    cardAddress: addr,
                    cardName: nonEmpty(c["cardName"]) ?? "Card",
                    cardType: (c["cardType"] as? String) ?? "",
                    points: pointsStr,
                    points6: points6Str,
                    cardCurrency: nonEmpty(c["cardCurrency"]) ?? "CAD",
                    nfts: nftList,
                    cardBackground: nonEmpty(c["cardBackground"]),
                    cardImage: nonEmpty(c["cardImage"]),
                    tierName: nonEmpty(c["tierName"]),
                    tierDescription: nonEmpty(c["tierDescription"]),
                    primaryMemberTokenId: coerceOptionalString(c["primaryMemberTokenId"]),
                    tierDiscountPercent: coerceOptionalTierDiscountPercent(c["tierDiscountPercent"])
                )
            }
        }()

        let cardsFromArr = rawCards?
            .filter { !$0.cardAddress.caseInsensitiveEquals(BeamioConstants.deprecatedCardAddress) }

        let unitPriceUSDC6 = s("unitPriceUSDC6")
        let beamioUserCard = s("beamioUserCard")
        let caddBalance = coerceOptionalString(root["caddBalance"])
        let posLastTopupAt = s("posLastTopupAt")
        let posLastTopupUsdcE6 = coerceOptionalString(root["posLastTopupUsdcE6"])
        let posLastTopupPointsE6 = coerceOptionalString(root["posLastTopupPointsE6"])
        let merchantCouponBalances: [MerchantCouponBalanceItem]? = (root["merchantCouponBalances"] as? [[String: Any]])?.compactMap { row in
            guard
                let cardAddress = coerceOptionalString(row["cardAddress"]),
                let couponId = coerceOptionalString(row["couponId"]),
                let tokenId = coerceOptionalString(row["tokenId"])
            else { return nil }
            return MerchantCouponBalanceItem(
                cardAddress: cardAddress,
                couponId: couponId,
                tokenId: tokenId,
                title: coerceOptionalString(row["title"]) ?? "Coupon #\(tokenId)",
                balance: coerceOptionalString(row["balance"]) ?? "0",
                requiresRedeemCode: coerceBool(row["requiresRedeemCode"])
            )
        }
        let merchantClaimableCoupons: [MerchantClaimableCouponItem]? = (root["merchantClaimableCoupons"] as? [[String: Any]])?.compactMap { row in
            guard
                let cardAddress = coerceOptionalString(row["cardAddress"]),
                let couponId = coerceOptionalString(row["couponId"]),
                let tokenId = coerceOptionalString(row["tokenId"])
            else { return nil }
            return MerchantClaimableCouponItem(
                cardAddress: cardAddress,
                couponId: couponId,
                tokenId: tokenId,
                title: coerceOptionalString(row["title"]) ?? "Coupon #\(tokenId)",
                requiresRedeemCode: coerceBool(row["requiresRedeemCode"])
            )
        }
        let beamioTagVal =
            s("beamioTag") ?? s("accountName") ?? s("username")
        let beamioTagNormalized =
            beamioTagVal?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^@+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        let uidVal = s("uid")
        let tagIdHexVal = s("tagIdHex")
        let counterHexVal = s("counterHex")
        let counterVal = root["counter"] as? Int

        let rootPrimaryId = coerceOptionalString(root["primaryMemberTokenId"])

        if let cards = cardsFromArr, !cards.isEmpty {
            let first = cards[0]
            return UIDAssets(
                ok: (root["ok"] as? Bool) ?? false,
                address: s("address"),
                aaAddress: s("aaAddress"),
                primaryMemberTokenId: rootPrimaryId,
                beamioTag: beamioTagNormalized,
                uid: uidVal,
                tagIdHex: tagIdHexVal,
                counterHex: counterHexVal,
                counter: counterVal,
                cardAddress: first.cardAddress,
                points: first.points,
                points6: first.points6,
                usdcBalance: s("usdcBalance"),
                caddBalance: caddBalance,
                cardCurrency: first.cardCurrency,
                nfts: first.nfts.isEmpty ? nil : first.nfts,
                cards: cards,
                unitPriceUSDC6: unitPriceUSDC6,
                beamioUserCard: beamioUserCard,
                error: s("error"),
                posLastTopupAt: posLastTopupAt,
                posLastTopupUsdcE6: posLastTopupUsdcE6,
                posLastTopupPointsE6: posLastTopupPointsE6,
                merchantCouponBalances: merchantCouponBalances?.nilIfEmpty,
                merchantClaimableCoupons: merchantClaimableCoupons?.nilIfEmpty
            )
        }

        let legacyAddr = s("cardAddress")
        let isDep = legacyAddr?.caseInsensitiveEquals(BeamioConstants.deprecatedCardAddress) ?? false
        let legacyNfts = nfts
        let legacyPoints = isDep ? nil : coerceOptionalString(root["points"])
        let legacyPoints6 = isDep ? nil : coerceOptionalString(root["points6"])

        return UIDAssets(
            ok: (root["ok"] as? Bool) ?? false,
            address: s("address"),
            aaAddress: s("aaAddress"),
            primaryMemberTokenId: rootPrimaryId,
            beamioTag: beamioTagNormalized,
            uid: uidVal,
            tagIdHex: tagIdHexVal,
            counterHex: counterHexVal,
            counter: counterVal,
            cardAddress: isDep ? nil : legacyAddr,
            points: legacyPoints,
            points6: legacyPoints6,
            usdcBalance: s("usdcBalance"),
            caddBalance: caddBalance,
            cardCurrency: isDep ? nil : s("cardCurrency"),
            nfts: isDep ? nil : legacyNfts.flatMap { $0.isEmpty ? nil : $0 },
            cards: nil,
            unitPriceUSDC6: unitPriceUSDC6,
            beamioUserCard: beamioUserCard,
            error: s("error"),
            posLastTopupAt: posLastTopupAt,
            posLastTopupUsdcE6: posLastTopupUsdcE6,
            posLastTopupPointsE6: posLastTopupPointsE6,
            merchantCouponBalances: merchantCouponBalances?.nilIfEmpty,
            merchantClaimableCoupons: merchantClaimableCoupons?.nilIfEmpty
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func caseInsensitiveEquals(_ other: String) -> Bool {
        caseInsensitiveCompare(other) == .orderedSame
    }
}

private extension Array {
    var nilIfEmpty: [Element]? {
        isEmpty ? nil : self
    }
}
