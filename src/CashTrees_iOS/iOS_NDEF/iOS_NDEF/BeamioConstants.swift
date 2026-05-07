import Foundation

enum BeamioConstants {
    /// 与 SilentPassUI `beamioApi` / Android `BEAMIO_API` 一致
    static let beamioApi = "https://beamio.app"
    static let sunBaseUrl = "https://api.beamio.app/api/sun"
    static let baseRpcUrl = "https://base-rpc.conet.network"
    /// CoNET mainnet RPC — `beamio-AccountRegistry` / `isAccountNameAvailable`（与 `bizSite` beamio.ts 一致）
    static let conetMainnetRpcUrl = "https://rpc1.conet.network"
    /// SilentPassUI `contracts.constPgpManager` — `searchKey(address)` for recipient CoNET PGP public key
    static let conetAddressPgpManager = "0xb2aABe52f476356AE638839A786EAE425A0c1b66"
    /// `beamioAccountContract.address` in `bizSite/src/services/beamio.ts`
    static let beamioAccountRegistryAddress = "0x4afaca09cf8307070a83836223Ae129073eC92e5"
    static let usdcBase = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    /// Base CADD token (requested for POS balance completion view).
    static let caddBase = "0x16F93eBC5320C89EfC8701577efe49d14A276a06"
    /// `BEAMIO_INDEXER_DIAMOND` (CoNET DePIN, biz `chainAddresses.ts`) — `getAccountTransactionsPaged` source for POS Transactions screen.
    /// 2026-04-22 224422 重启后地址：`deployments/conet-IndexerDiamond.json` → `diamond`.
    /// 旧地址 `0x0c29b4DB72F31457570D38eB215b3F855d5989E1` 已无代码（链 wipe），禁止使用。
    static let beamioIndexerDiamondAddress = "0x45D45de73465b8913B50974Fc188529dFFb7AfFA"
    /// `deployments/conet-addresses.json` / `conet-BUint.json` source of truth for B-Units on CoNET L1.
    static let buintConet = "0x1330297821814B06A6DafE3557Fa730F690D7007"

    /// 历史共享基础设施模板地址。POS **不得**再作为默认 `merchantInfraCard`；终端程序卡仅以 `/api/myPosAddress` 登记为准。仍用于过滤 `getWalletAssets` 中该行，避免 Charge 误用。
    static let defaultBeamioUserCard = "0xA756F2E27a332d6Be2d399dA543E3Ce4C8455F14"

    /// 与 `chainAddresses.BASE_CARD_FACTORY` / Android `BeamioWeb3Wallet` 一致（EIP-712 verifyingContract）
    static let baseCardFactory = "0xbA92e9122CDff1e8dD817eE55BCe7C7f6c9bFc9B"
    static let baseChainId: UInt64 = 8453

    static let deprecatedCardAddress = "0xEcC5bDFF6716847e45363befD3506B1D539c02D5"
}
