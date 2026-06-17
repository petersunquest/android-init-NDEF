import Foundation

enum BeamioConstants {
    /// 与 SilentPassUI `beamioApi` / Android `BEAMIO_API` 一致
    static let beamioApi = "https://beamio.app"
    static let sunBaseUrl = "https://api.beamio.app/api/sun"
    static let baseRpcUrl = "https://base-rpc.conet.network"
    /// CoNET mainnet RPC — `beamio-AccountRegistry` / `isAccountNameAvailable`（与 `bizSite` beamio.ts 一致）
    static let conetMainnetRpcUrl = "https://rpc1.conet.network"
    /// SilentPassUI `contracts.constPgpManager` — `searchKey(address)` for recipient CoNET PGP public key
    static let conetAddressPgpManager = "0x684b0ac760cEE9c9b85de36d69746420648Cf9e2"
    /// `beamioAccountContract.address` in `bizSite/src/services/beamio.ts`
    static let beamioAccountRegistryAddress = "0xfFDc8d2021A41F4638Cb3eCf58B5155383EE9f6d"
    /// Pre-224422 AccountRegistry archive RPC (`deployments/conet-addresses.json` → `legacyArchiveRpc`).
    static let legacyAccountRegistryRpcUrl = "https://rpc-old.conet.network"
    /// Pre-224422 AccountRegistry (`deployments/conet-addresses.json` → `legacyAccountRegistry`).
    static let legacyAccountRegistryAddress = "0x4afaca09cf8307070a83836223Ae129073eC92e5"
    static let usdcBase = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    /// Base CADD token (requested for POS balance completion view).
    static let caddBase = "0x16F93eBC5320C89EfC8701577efe49d14A276a06"
    /// `BEAMIO_INDEXER_DIAMOND` (CoNET DePIN, biz `chainAddresses.ts`) — `getAccountTransactionsPaged` source for POS Transactions screen.
    /// 2026-04-22 224422 重启后地址：`deployments/conet-IndexerDiamond.json` → `diamond`.
    /// 旧地址 `0x0c29b4DB72F31457570D38eB215b3F855d5989E1` 已无代码（链 wipe），禁止使用。
    static let beamioIndexerDiamondAddress = "0xd764eBA64536cFF1bbE7e7c7Bbc90F35620f72a9"
    /// `deployments/conet-addresses.json` / `conet-BUint.json` source of truth for B-Units on CoNET L1.
    static let buintConet = "0x9149433F154C508d2a04454b8E527A479C6fd254"

    /// 历史共享基础设施模板地址。POS **不得**再作为默认 `merchantInfraCard`；终端程序卡仅以 `/api/myPosAddress` 登记为准。仍用于过滤 `getWalletAssets` 中该行，避免 Charge 误用。
    static let defaultBeamioUserCard = "0xA756F2E27a332d6Be2d399dA543E3Ce4C8455F14"

    /// 与 `chainAddresses.BASE_CARD_FACTORY` / Android `BeamioWeb3Wallet` 一致（EIP-712 verifyingContract）
    static let baseCardFactory = "0xF2864210577359AcaE448D2B116031a0c5EE1016"
    static let baseChainId: UInt64 = 8453

    /// 与 x402sdk `apiExcludedUserCards.ts` 对齐：API/客户端不得展示或默认使用的废弃 BeamioUserCard。
    static let apiExcludedUserCardAddresses: [String] = [
        "0xBCcfA50d2a5917C7A8662177F5F4B7A175787270",
        "0x2032A363BB2cf331142391fC0DAd21D6504922C7",
        "0xEcC5bDFF6716847e45363befD3506B1D539c02D5",
        "0xA756F2E27a332d6Be2d399dA543E3Ce4C8455F14",
    ]

    static func isApiExcludedUserCard(_ address: String) -> Bool {
        let lower = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        return apiExcludedUserCardAddresses.contains { $0.caseInsensitiveCompare(lower) == .orderedSame }
    }

    /// @deprecated 使用 `isApiExcludedUserCard`；保留旧字段名兼容。
    static let deprecatedCardAddress = "0xBCcfA50d2a5917C7A8662177F5F4B7A175787270"
}
