import Foundation

struct NftItem: Identifiable, Equatable {
    var id: String { tokenId }
    let tokenId: String
    let attribute: String
    let tier: String
    let expiry: String
    let isExpired: Bool
}

struct CardItem: Identifiable, Equatable {
    var id: String { cardAddress }
    let cardAddress: String
    let cardName: String
    let cardType: String
    let points: String
    let points6: String
    let cardCurrency: String
    var nfts: [NftItem]
    var cardBackground: String?
    var cardImage: String?
    var tierName: String?
    var tierDescription: String?
    var primaryMemberTokenId: String?

    /// Android `memberNoFromCardItem` / iOS `readBalanceMemberNo`.
    func formattedMemberNumber() -> String {
        let primary = primaryMemberTokenId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !primary.isEmpty, (Int64(primary) ?? 0) > 0 {
            return "M-\(primary.beamioPadStart(6))"
        }
        let legacy = nfts
            .filter { (Int64($0.tokenId) ?? 0) > 0 }
            .max(by: { (Int64($0.tokenId) ?? 0) < (Int64($1.tokenId) ?? 0) })?
            .tokenId
        if let legacy, (Int64(legacy) ?? 0) > 0 {
            return "M-\(legacy.beamioPadStart(6))"
        }
        return ""
    }
}

/// Full-screen top-up success (Android `TopupSuccessContent`).
struct TopupSuccessState: Identifiable, Equatable {
    let id: UUID
    let amount: String
    let txHash: String
    let preBalance: String?
    let postBalance: String?
    let cardCurrency: String?
    let address: String?
    let memberNo: String?
    let cardBackground: String?
    let cardImage: String?
    let tierName: String?
    let tierDescription: String?
    let passCard: CardItem?
    let settlementViaQr: Bool

    init(
        id: UUID = UUID(),
        amount: String,
        txHash: String,
        preBalance: String?,
        postBalance: String?,
        cardCurrency: String?,
        address: String?,
        memberNo: String?,
        cardBackground: String?,
        cardImage: String?,
        tierName: String?,
        tierDescription: String?,
        passCard: CardItem?,
        settlementViaQr: Bool
    ) {
        self.id = id
        self.amount = amount
        self.txHash = txHash
        self.preBalance = preBalance
        self.postBalance = postBalance
        self.cardCurrency = cardCurrency
        self.address = address
        self.memberNo = memberNo
        self.cardBackground = cardBackground
        self.cardImage = cardImage
        self.tierName = tierName
        self.tierDescription = tierDescription
        self.passCard = passCard
        self.settlementViaQr = settlementViaQr
    }
}

/// Full-screen charge / payment success (Android `PaymentSuccessContent`).
struct ChargeSuccessState: Identifiable, Equatable {
    let id: UUID
    let amount: String
    let payee: String
    let txHash: String
    let subtotal: String?
    let tip: String?
    let postBalance: String?
    let cardCurrency: String?
    let memberNo: String?
    let cardBackground: String?
    let cardImage: String?
    let cardName: String?
    let tierName: String?
    let cardType: String?
    let passCard: CardItem?
    let settlementViaQr: Bool
    let chargeTaxPercent: Double?
    let chargeTierDiscountPercent: Int?
    let tableNumber: String?

    init(
        id: UUID = UUID(),
        amount: String,
        payee: String,
        txHash: String,
        subtotal: String?,
        tip: String?,
        postBalance: String?,
        cardCurrency: String?,
        memberNo: String?,
        cardBackground: String?,
        cardImage: String?,
        cardName: String?,
        tierName: String?,
        cardType: String?,
        passCard: CardItem?,
        settlementViaQr: Bool,
        chargeTaxPercent: Double?,
        chargeTierDiscountPercent: Int?,
        tableNumber: String?
    ) {
        self.id = id
        self.amount = amount
        self.payee = payee
        self.txHash = txHash
        self.subtotal = subtotal
        self.tip = tip
        self.postBalance = postBalance
        self.cardCurrency = cardCurrency
        self.memberNo = memberNo
        self.cardBackground = cardBackground
        self.cardImage = cardImage
        self.cardName = cardName
        self.tierName = tierName
        self.cardType = cardType
        self.passCard = passCard
        self.settlementViaQr = settlementViaQr
        self.chargeTaxPercent = chargeTaxPercent
        self.chargeTierDiscountPercent = chargeTierDiscountPercent
        self.tableNumber = tableNumber
    }
}

private extension String {
    func beamioPadStart(_ minLength: Int, pad: Character = "0") -> String {
        guard count < minLength else { return self }
        return String(repeating: String(pad), count: minLength - count) + self
    }
}

struct UIDAssets: Equatable {
    var ok: Bool
    var address: String?
    var aaAddress: String?
    var beamioTag: String?
    var uid: String?
    var tagIdHex: String?
    var counterHex: String?
    var counter: Int?
    var cardAddress: String?
    var points: String?
    var points6: String?
    var usdcBalance: String?
    var cardCurrency: String?
    var nfts: [NftItem]?
    var cards: [CardItem]?
    var unitPriceUSDC6: String?
    var beamioUserCard: String?
    var error: String?

    /// Android `memberNoPrimaryFromSortedCardsItem`
    func memberNoPrimaryFromSortedCards() -> String {
        for c in cards ?? [] {
            let m = c.formattedMemberNumber()
            if !m.isEmpty { return m }
        }
        let legacy = (nfts ?? [])
            .filter { (Int64($0.tokenId) ?? 0) > 0 }
            .max(by: { (Int64($0.tokenId) ?? 0) < (Int64($1.tokenId) ?? 0) })?
            .tokenId
        guard let legacy, (Int64(legacy) ?? 0) > 0 else { return "" }
        let padded = legacy.count >= 6 ? legacy : String(repeating: "0", count: max(0, 6 - legacy.count)) + legacy
        return "M-\(padded)"
    }

    init(
        ok: Bool,
        address: String? = nil,
        aaAddress: String? = nil,
        beamioTag: String? = nil,
        uid: String? = nil,
        tagIdHex: String? = nil,
        counterHex: String? = nil,
        counter: Int? = nil,
        cardAddress: String? = nil,
        points: String? = nil,
        points6: String? = nil,
        usdcBalance: String? = nil,
        cardCurrency: String? = nil,
        nfts: [NftItem]? = nil,
        cards: [CardItem]? = nil,
        unitPriceUSDC6: String? = nil,
        beamioUserCard: String? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.address = address
        self.aaAddress = aaAddress
        self.beamioTag = beamioTag
        self.uid = uid
        self.tagIdHex = tagIdHex
        self.counterHex = counterHex
        self.counter = counter
        self.cardAddress = cardAddress
        self.points = points
        self.points6 = points6
        self.usdcBalance = usdcBalance
        self.cardCurrency = cardCurrency
        self.nfts = nfts
        self.cards = cards
        self.unitPriceUSDC6 = unitPriceUSDC6
        self.beamioUserCard = beamioUserCard
        self.error = error
    }
}

struct TerminalProfile: Equatable {
    let accountName: String?
    let firstName: String?
    let lastName: String?
    let image: String?
    let address: String?
}

struct SunParams: Equatable {
    let uid: String
    let e: String
    let c: String
    let m: String
}

enum ScanPendingAction: String {
    case read
    case topup
    case payment
    case linkApp
}

enum ScanMethod: String {
    case nfc
    case qr
}
