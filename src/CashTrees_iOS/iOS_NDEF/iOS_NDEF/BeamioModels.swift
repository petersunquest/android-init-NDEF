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
    /// Program tier discount % (metadata/API); falls back to parsing [tierDescription] in UI when nil.
    var tierDiscountPercent: Double? = nil

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
    /// Android `TopupSuccessContent`: `customerBeamioTag` for hero title (Balance Loaded parity).
    let customerBeamioTag: String?

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
        settlementViaQr: Bool,
        customerBeamioTag: String? = nil
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
        self.customerBeamioTag = customerBeamioTag
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
    let chargeTierDiscountPercent: Double?
    let tableNumber: String?
    /// `verra-home` `ndef1.html` — partial charge: wallet paid all available funds but order not fully settled.
    let isPartialApproval: Bool
    let originalOrderTotal: String?
    let remainingShortfall: String?
    /// Android `PaymentSuccessContent` hero / share receipt.
    let customerBeamioTag: String?
    let customerWalletAddress: String?

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
        chargeTierDiscountPercent: Double?,
        tableNumber: String?,
        isPartialApproval: Bool = false,
        originalOrderTotal: String? = nil,
        remainingShortfall: String? = nil,
        customerBeamioTag: String? = nil,
        customerWalletAddress: String? = nil
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
        self.isPartialApproval = isPartialApproval
        self.originalOrderTotal = originalOrderTotal
        self.remainingShortfall = remainingShortfall
        self.customerBeamioTag = customerBeamioTag
        self.customerWalletAddress = customerWalletAddress
    }
}

struct SunParams: Equatable {
    let uid: String
    let e: String
    let c: String
    let m: String
}

/// Full-screen charge declined: customer assets cannot cover the payment (before `postAAtoEOA` / NFC sign).
struct ChargeInsufficientFundsState: Identifiable, Equatable {
    let id: UUID
    let chargeTotalInPayCurrency: Double
    let payCurrency: String
    let requiredUsdc6: Int64
    let availableUsdc6: Int64
    let subtotal: Double
    let tip: Double
    let taxPercent: Double
    let tierDiscountPercent: Double
    let beamioTag: String?
    let walletShort: String?
    let memberNo: String?
    let passCard: CardItem?
    let settlementViaQr: Bool
    /// Immediate partial charge retry (aligned with Android `InsufficientPartialRetryContext`); single source of truth for the insufficient screen.
    let retryNfcUid: String?
    let retryNfcSun: SunParams?
    let retryQrAccount: String?
    /// JSON string of the Dynamic QR open-container payload.
    let retryQrPayloadJson: String?

    init(
        id: UUID = UUID(),
        chargeTotalInPayCurrency: Double,
        payCurrency: String,
        requiredUsdc6: Int64,
        availableUsdc6: Int64,
        subtotal: Double,
        tip: Double,
        taxPercent: Double,
        tierDiscountPercent: Double,
        beamioTag: String?,
        walletShort: String?,
        memberNo: String?,
        passCard: CardItem?,
        settlementViaQr: Bool,
        retryNfcUid: String? = nil,
        retryNfcSun: SunParams? = nil,
        retryQrAccount: String? = nil,
        retryQrPayloadJson: String? = nil
    ) {
        self.id = id
        self.chargeTotalInPayCurrency = chargeTotalInPayCurrency
        self.payCurrency = payCurrency
        self.requiredUsdc6 = requiredUsdc6
        self.availableUsdc6 = availableUsdc6
        self.subtotal = subtotal
        self.tip = tip
        self.taxPercent = taxPercent
        self.tierDiscountPercent = tierDiscountPercent
        self.beamioTag = beamioTag
        self.walletShort = walletShort
        self.memberNo = memberNo
        self.passCard = passCard
        self.settlementViaQr = settlementViaQr
        self.retryNfcUid = retryNfcUid
        self.retryNfcSun = retryNfcSun
        self.retryQrAccount = retryQrAccount
        self.retryQrPayloadJson = retryQrPayloadJson
    }

    var shortfallUsdc6: Int64 { max(0, requiredUsdc6 - availableUsdc6) }
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
    /// Root-level `primaryMemberTokenId` when API has no `cards[]` (synthetic `CardItem` in Balance Loaded).
    var primaryMemberTokenId: String?
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
    /// Cluster：商户基础设施卡上该会员 DB 最近 top-up（与 `getMemberLastTopupOnCard` / POS 查询同窗返回）
    var posLastTopupAt: String?
    var posLastTopupUsdcE6: String?
    var posLastTopupPointsE6: String?

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
        primaryMemberTokenId: String? = nil,
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
        error: String? = nil,
        posLastTopupAt: String? = nil,
        posLastTopupUsdcE6: String? = nil,
        posLastTopupPointsE6: String? = nil
    ) {
        self.ok = ok
        self.address = address
        self.aaAddress = aaAddress
        self.primaryMemberTokenId = primaryMemberTokenId
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
        self.posLastTopupAt = posLastTopupAt
        self.posLastTopupUsdcE6 = posLastTopupUsdcE6
        self.posLastTopupPointsE6 = posLastTopupPointsE6
    }
}

struct TerminalProfile: Equatable, Codable {
    let accountName: String?
    let firstName: String?
    let lastName: String?
    let image: String?
    let address: String?

    enum CodingKeys: String, CodingKey {
        case accountName
        case firstName = "first_name"
        case lastName = "last_name"
        case image
        case address
    }
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

// MARK: - Charge QR Smart Routing (align Android `RoutingStep` / `PaymentRoutingMonitorDisplayCard`)

enum PaymentRoutingStepStatus: String, Equatable {
    case pending
    case loading
    case success
    case error
}

struct PaymentRoutingStepRow: Identifiable, Equatable {
    let id: String
    var label: String
    var detail: String
    var status: PaymentRoutingStepStatus
}

extension Array where Element == PaymentRoutingStepRow {
    /// Same filters as Android `filterPaymentRoutingStepsForDisplay`, then last N rows.
    func beamioPaymentRoutingStepsForDisplay(maxVisible: Int = 6) -> [PaymentRoutingStepRow] {
        let early: Set<String> = ["detectingUser", "membership", "analyzingAssets", "optimizingRoute"]
        let filtered = filter { step in
            early.contains(step.id) || step.status != .pending
        }
        if filtered.count <= maxVisible { return filtered }
        return Array(filtered.suffix(maxVisible))
    }
}
