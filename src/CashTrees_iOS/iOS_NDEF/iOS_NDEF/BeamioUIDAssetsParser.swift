import Foundation

enum BeamioUIDAssetsParser {
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
                    tokenId: (o["tokenId"] as? String) ?? "",
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
                        tokenId: (o["tokenId"] as? String) ?? "",
                        attribute: (o["attribute"] as? String) ?? "",
                        tier: (o["tier"] as? String) ?? "",
                        expiry: (o["expiry"] as? String) ?? "",
                        isExpired: (o["isExpired"] as? Bool) ?? false
                    )
                }
                let addr = (c["cardAddress"] as? String) ?? ""
                guard !addr.isEmpty else { return nil }
                return CardItem(
                    cardAddress: addr,
                    cardName: nonEmpty(c["cardName"]) ?? "Card",
                    cardType: (c["cardType"] as? String) ?? "",
                    points: (c["points"] as? String) ?? "0",
                    points6: (c["points6"] as? String) ?? "0",
                    cardCurrency: nonEmpty(c["cardCurrency"]) ?? "CAD",
                    nfts: nftList,
                    cardBackground: nonEmpty(c["cardBackground"]),
                    cardImage: nonEmpty(c["cardImage"]),
                    tierName: nonEmpty(c["tierName"]),
                    tierDescription: nonEmpty(c["tierDescription"]),
                    primaryMemberTokenId: nonEmpty(c["primaryMemberTokenId"])
                )
            }
        }()

        let cardsFromArr = rawCards?
            .filter { !$0.cardAddress.caseInsensitiveEquals(BeamioConstants.deprecatedCardAddress) }

        let unitPriceUSDC6 = s("unitPriceUSDC6")
        let beamioUserCard = s("beamioUserCard")
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

        if let cards = cardsFromArr, !cards.isEmpty {
            let first = cards[0]
            return UIDAssets(
                ok: (root["ok"] as? Bool) ?? false,
                address: s("address"),
                aaAddress: s("aaAddress"),
                beamioTag: beamioTagNormalized,
                uid: uidVal,
                tagIdHex: tagIdHexVal,
                counterHex: counterHexVal,
                counter: counterVal,
                cardAddress: first.cardAddress,
                points: first.points,
                points6: first.points6,
                usdcBalance: s("usdcBalance"),
                cardCurrency: first.cardCurrency,
                nfts: first.nfts.isEmpty ? nil : first.nfts,
                cards: cards,
                unitPriceUSDC6: unitPriceUSDC6,
                beamioUserCard: beamioUserCard,
                error: s("error")
            )
        }

        let legacyAddr = s("cardAddress")
        let isDep = legacyAddr?.caseInsensitiveEquals(BeamioConstants.deprecatedCardAddress) ?? false
        let legacyNfts = nfts
        return UIDAssets(
            ok: (root["ok"] as? Bool) ?? false,
            address: s("address"),
            aaAddress: s("aaAddress"),
            beamioTag: beamioTagNormalized,
            uid: uidVal,
            tagIdHex: tagIdHexVal,
            counterHex: counterHexVal,
            counter: counterVal,
            cardAddress: isDep ? nil : legacyAddr,
            points: isDep ? nil : s("points"),
            points6: isDep ? nil : s("points6"),
            usdcBalance: s("usdcBalance"),
            cardCurrency: isDep ? nil : s("cardCurrency"),
            nfts: isDep ? nil : legacyNfts.flatMap { $0.isEmpty ? nil : $0 },
            cards: nil,
            unitPriceUSDC6: unitPriceUSDC6,
            beamioUserCard: beamioUserCard,
            error: s("error")
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
