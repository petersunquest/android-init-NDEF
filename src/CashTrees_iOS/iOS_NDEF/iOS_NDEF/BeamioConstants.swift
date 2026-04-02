import Foundation

enum BeamioConstants {
    /// 与 SilentPassUI `beamioApi` / Android `BEAMIO_API` 一致
    static let beamioApi = "https://beamio.app"
    static let sunBaseUrl = "https://api.beamio.app/api/sun"
    static let baseRpcUrl = "https://base-rpc.conet.network"
    /// CoNET mainnet RPC — `beamio-AccountRegistry` / `isAccountNameAvailable`（与 `bizSite` beamio.ts 一致）
    static let conetMainnetRpcUrl = "https://mainnet-rpc.conet.network"
    /// `beamioAccountContract.address` in `bizSite/src/services/beamio.ts`
    static let beamioAccountRegistryAddress = "0x3E15607BCf98B01e6C7dF834a2CEc7B8B6aFb1BC"
    static let usdcBase = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

    /// 默认基础设施卡；运行时以 `/api/myPosAddress?wallet=` 为准
    static let defaultBeamioUserCard = "0xA756F2E27a332d6Be2d399dA543E3Ce4C8455F14"

    /// 与 `chainAddresses.BASE_CARD_FACTORY` / Android `BeamioWeb3Wallet` 一致（EIP-712 verifyingContract）
    static let baseCardFactory = "0x2EB245646de404b2Dce87E01C6282C131778bb05"
    static let baseChainId: UInt64 = 8453

    static let deprecatedCardAddress = "0xEcC5bDFF6716847e45363befD3506B1D539c02D5"
}
