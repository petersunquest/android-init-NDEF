import Foundation

/// Local-first home screen cache (align Android `PREFS_PROFILE_CACHE` + trusted on-chain stats).
/// Only persist after a successful API / RPC parse; never write on failure.
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
    }

    static func loadStats(wallet: String, infraCard: String) -> (charge: Double?, topUp: Double?) {
        let key = statsKey(wallet, infraCard: infraCard)
        guard let data = ud.data(forKey: key),
              let p = try? JSONDecoder().decode(StatsPayload.self, from: data)
        else { return (nil, nil) }
        return (p.charge, p.topUp)
    }

    /// Merge with existing file so a one-sided RPC success does not erase the other side.
    static func mergeAndSaveStats(wallet: String, infraCard: String, charge: Double?, topUp: Double?) {
        var p = StatsPayload(charge: nil, topUp: nil)
        if let data = ud.data(forKey: statsKey(wallet, infraCard: infraCard)),
           let decoded = try? JSONDecoder().decode(StatsPayload.self, from: data)
        {
            p = decoded
        }
        if let charge { p.charge = charge }
        if let topUp { p.topUp = topUp }
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
}
