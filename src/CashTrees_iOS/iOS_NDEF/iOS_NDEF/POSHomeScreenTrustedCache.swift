import Foundation

/// Local-first home screen cache (align Android `PREFS_PROFILE_CACHE` + trusted on-chain stats).
/// Only persist after a successful API / RPC parse; never write on failure.
/// Never remove admin/profile entries because a later fetch failed — failure is untrusted; only clear admin after a **successful**
/// `getCardAdminInfo` that indicates no `upperAdmin`.
enum POSHomeScreenTrustedCache {
    private static let ud = UserDefaults.standard

    private static func normWallet(_ wallet: String) -> String {
        wallet.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normInfra(_ infra: String) -> String {
        infra.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func termKey(_ wallet: String) -> String {
        "iosndef.home.term.\(normWallet(wallet))"
    }

    private static func adminKey(_ wallet: String) -> String {
        "iosndef.home.admin.\(normWallet(wallet))"
    }

    private static func statsKey(_ wallet: String, infraCard: String) -> String {
        "iosndef.home.stats.\(normWallet(wallet)).\(normInfra(infraCard))"
    }

    private static func routingKey(_ wallet: String, infraCard: String) -> String {
        "iosndef.home.routing.\(normWallet(wallet)).\(normInfra(infraCard))"
    }

    private static func programKey(_ wallet: String, infraCard: String) -> String {
        "iosndef.home.program.\(normWallet(wallet)).\(normInfra(infraCard))"
    }

    // MARK: - Profiles

    static func loadProfiles(wallet: String) -> (terminal: TerminalProfile?, admin: TerminalProfile?) {
        let t = loadProfileJson(key: termKey(wallet)).flatMap { decodeProfile(data: $0) }
        let a = loadProfileJson(key: adminKey(wallet)).flatMap { decodeProfile(data: $0) }
        return (t, a)
    }

    static func saveTerminal(_ profile: TerminalProfile, wallet: String) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        ud.set(data, forKey: termKey(wallet))
    }

    static func saveAdmin(_ profile: TerminalProfile, wallet: String) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        ud.set(data, forKey: adminKey(wallet))
    }

    static func removeAdmin(wallet: String) {
        ud.removeObject(forKey: adminKey(wallet))
    }

    private static func loadProfileJson(key: String) -> Data? {
        ud.data(forKey: key)
    }

    private static func decodeProfile(data: Data) -> TerminalProfile? {
        try? JSONDecoder().decode(TerminalProfile.self, from: data)
    }

    // MARK: - Stats (per wallet + infra card)

    private struct StatsPayload: Codable {
        var charge: Double?
        var topUp: Double?
        var tips: Double?
        var chargeUsdc: Double?
        var tipsUsdc: Double?
    }

    static func loadStats(wallet: String, infraCard: String) -> (
        charge: Double?,
        topUp: Double?,
        tips: Double?,
        chargeUsdc: Double?,
        tipsUsdc: Double?
    ) {
        let key = statsKey(wallet, infraCard: infraCard)
        guard let data = ud.data(forKey: key),
              let p = try? JSONDecoder().decode(StatsPayload.self, from: data)
        else { return (nil, nil, nil, nil, nil) }
        return (p.charge, p.topUp, p.tips, p.chargeUsdc, p.tipsUsdc)
    }

    /// Merge with existing file so a one-sided RPC success does not erase the other side.
    static func mergeAndSaveStats(
        wallet: String,
        infraCard: String,
        charge: Double?,
        topUp: Double?,
        tips: Double? = nil,
        chargeUsdc: Double? = nil,
        tipsUsdc: Double? = nil
    ) {
        var p = StatsPayload(charge: nil, topUp: nil, tips: nil, chargeUsdc: nil, tipsUsdc: nil)
        if let data = ud.data(forKey: statsKey(wallet, infraCard: infraCard)),
           let decoded = try? JSONDecoder().decode(StatsPayload.self, from: data)
        {
            p = decoded
        }
        if let charge { p.charge = charge }
        if let topUp { p.topUp = topUp }
        if let tips { p.tips = tips }
        if let chargeUsdc { p.chargeUsdc = chargeUsdc }
        if let tipsUsdc { p.tipsUsdc = tipsUsdc }
        guard let data = try? JSONEncoder().encode(p) else { return }
        ud.set(data, forKey: statsKey(wallet, infraCard: infraCard))
    }

    // MARK: - Routing summary

    private struct RoutingPayload: Codable {
        let tax: Double
        let summary: String
    }

    static func loadRouting(wallet: String, infraCard: String) -> (tax: Double, summary: String)? {
        let key = routingKey(wallet, infraCard: infraCard)
        guard let data = ud.data(forKey: key),
              let p = try? JSONDecoder().decode(RoutingPayload.self, from: data)
        else { return nil }
        return (p.tax, p.summary)
    }

    static func saveRouting(wallet: String, infraCard: String, tax: Double, summary: String) {
        let p = RoutingPayload(tax: tax, summary: summary)
        guard let data = try? JSONEncoder().encode(p) else { return }
        ud.set(data, forKey: routingKey(wallet, infraCard: infraCard))
    }

    // MARK: - Program (card name + recharge bonus rules)

    /// Persists the bits of the Home black-card panel that come from program-card sources:
    /// `programCardName` (from `getWalletAssets` `cards[infra].cardName`), `bonusRules` (from `cardMetadata`),
    /// and `activeCoupons` (`/api/cardActiveIssuedCouponSeries`).
    /// Optional fields → only the side that arrived trusted is written; the other side preserves prior value via merge.
    private struct ProgramPayload: Codable {
        var programCardName: String?
        var bonusRules: [BeamioRechargeBonusRule]?
        var activeCoupons: [MerchantActiveIssuedCoupon]?
    }

    static func loadProgram(
        wallet: String,
        infraCard: String
    ) -> (
        programCardName: String?,
        bonusRules: [BeamioRechargeBonusRule]?,
        activeCoupons: [MerchantActiveIssuedCoupon]?
    ) {
        let key = programKey(wallet, infraCard: infraCard)
        guard let data = ud.data(forKey: key),
              let p = try? JSONDecoder().decode(ProgramPayload.self, from: data)
        else { return (nil, nil, nil) }
        return (p.programCardName, p.bonusRules, p.activeCoupons)
    }

    /// Merge with on-disk record so a one-sided trusted update (e.g. only bonusRules came back this round) does not erase the other.
    /// Pass `programCardName: nil` / `bonusRules: nil` / `activeCoupons: nil` to leave that side unchanged.
    static func mergeAndSaveProgram(
        wallet: String,
        infraCard: String,
        programCardName: String?,
        bonusRules: [BeamioRechargeBonusRule]?,
        activeCoupons: [MerchantActiveIssuedCoupon]?
    ) {
        var p = ProgramPayload(programCardName: nil, bonusRules: nil, activeCoupons: nil)
        if let data = ud.data(forKey: programKey(wallet, infraCard: infraCard)),
           let decoded = try? JSONDecoder().decode(ProgramPayload.self, from: data)
        {
            p = decoded
        }
        if let programCardName { p.programCardName = programCardName }
        if let bonusRules { p.bonusRules = bonusRules }
        if let activeCoupons { p.activeCoupons = activeCoupons }
        guard let data = try? JSONEncoder().encode(p) else { return }
        ud.set(data, forKey: programKey(wallet, infraCard: infraCard))
    }

    // MARK: - POS Transactions ledger (cluster `/api/posLedger` snapshot)

    private static func ledgerKey(_ wallet: String, infraCard: String) -> String {
        "iosndef.home.posLedger.\(normWallet(wallet)).\(normInfra(infraCard))"
    }

    /// Last successfully loaded `PosLedgerSnapshot` for `(wallet, infra)`. `nil` when never persisted /
    /// decode failed. **Never** cleared on a refresh failure (untrusted result is silently ignored —
    /// see `beamio-trusted-vs-untrusted-fetch.mdc`).
    static func loadPosLedger(wallet: String, infraCard: String) -> PosLedgerSnapshot? {
        let key = ledgerKey(wallet, infraCard: infraCard)
        guard let data = ud.data(forKey: key),
              let snap = try? JSONDecoder().decode(PosLedgerSnapshot.self, from: data)
        else { return nil }
        return snap
    }

    static func savePosLedger(_ snapshot: PosLedgerSnapshot, wallet: String, infraCard: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        ud.set(data, forKey: ledgerKey(wallet, infraCard: infraCard))
    }
}
