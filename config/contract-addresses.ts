/**
 * 全局合约地址配置 - 单一数据源
 *
 * 所有模块必须从此文件导入，禁止在各模块内自行定义合约地址。
 * 数据来源：
 *   - Base: config/base-addresses.json
 *   - CoNET: deployments/conet-addresses.json
 *
 * 部署脚本更新地址时，应更新上述 JSON 文件，本文件会自动读取。
 */
import baseAddrs from './base-addresses.json'
import conetAddrs from '../deployments/conet-addresses.json'

type BaseAddrs = {
  BASE_MAINNET_CHAIN_ID?: number
  AA_FACTORY?: string
  BEAMIO_ACCOUNT_DEPLOYER?: string
  CARD_FACTORY?: string
  CCSA_CARD_ADDRESS?: string
  BASE_TREASURY?: string
  BEAMIO_USER_CARD_ASSET_ADDRESS?: string
  PURCHASING_CARD_METADATA_ADDRESS?: string
  USDC_BASE?: string
  /** BeamioUserCard 链接库；空则发卡依赖环境变量或 x402sdk chainAddresses 手工配置 */
  BEAMIO_USER_CARD_FORMATTING_LIB?: string
  BEAMIO_USER_CARD_TRANSFER_LIB?: string
}

type ConetAddrs = {
  BUint?: string
  BUnitAirdrop?: string
  BuintRedeemAirdrop?: string
  BeamioIndexerDiamond?: string
  ConetTreasury?: string
  conetUsdc?: string
  /** src/mainnet/AccountRegistry.sol；与 beamioAccount（AA 实现）不同 */
  AccountRegistry?: string
}

const base = baseAddrs as BaseAddrs
const conet = conetAddrs as ConetAddrs

// --- Base Mainnet ---
export const BASE_MAINNET_CHAIN_ID = base.BASE_MAINNET_CHAIN_ID ?? 8453
export const BASE_AA_FACTORY = base.AA_FACTORY ?? '0x4b31D6a05Cdc817CAc1B06369555b37a5b182122'
/** BeamioAccountDeployer（CREATE2）；与 deployments/base-FactoryAndModule.json beamioFactoryPaymaster.deployer 一致 */
export const BASE_BEAMIO_ACCOUNT_DEPLOYER =
  base.BEAMIO_ACCOUNT_DEPLOYER ?? '0x139D55591A03550259AF32097A9848ECE9869C90'
export const BASE_CARD_FACTORY = base.CARD_FACTORY ?? '0x2EB245646de404b2Dce87E01C6282C131778bb05'
export const BASE_CCSA_CARD_ADDRESS = base.CCSA_CARD_ADDRESS ?? '0x2032A363BB2cf331142391fC0DAd21D6504922C7'
/** Base 主网（8453）BaseTreasury；勿与 CoNET L1 的 {@link CONET_TREASURY} 混淆 */
export const BASE_TREASURY = base.BASE_TREASURY ?? '0x5c64a8b0935DA72d60933bBD8cD10579E1C40c58'
export const BEAMIO_USER_CARD_ASSET_ADDRESS = base.BEAMIO_USER_CARD_ASSET_ADDRESS ?? '0xB7644DDb12656F4854dC746464af47D33C206F0E'
export const PURCHASING_CARD_METADATA_ADDRESS = base.PURCHASING_CARD_METADATA_ADDRESS ?? '0xf99018dffdb0c5657c93ca14db2900cebe1168a7'
export const USDC_BASE = base.USDC_BASE ?? '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'
/** 空串表示未配置；运行 `npm run deploy:usercard-libraries:base` 后写入 base-addresses.json */
export const BASE_BEAMIO_USER_CARD_FORMATTING_LIB = (base.BEAMIO_USER_CARD_FORMATTING_LIB ?? '').trim()
export const BASE_BEAMIO_USER_CARD_TRANSFER_LIB = (base.BEAMIO_USER_CARD_TRANSFER_LIB ?? '').trim()

// --- CoNET Mainnet ---
export const CONET_BUINT = conet.BUint ?? '0x1330297821814B06A6DafE3557Fa730F690D7007'
export const CONET_BUNIT_AIRDROP_ADDRESS = conet.BUnitAirdrop ?? '0xFd60936707cb4583c08D8AacBA19E4bfaEE446B8'
/** B-Unit 兑换码空投（EIP-712 admin 提交）；见 deployments/conet-BuintRedeemAirdrop.json */
export const CONET_BUINT_REDEEM_AIRDROP = conet.BuintRedeemAirdrop ?? '0xdB877ec8572C669C533021764FC1Fecfe8dc6b4c'
export const BEAMIO_INDEXER_DIAMOND = conet.BeamioIndexerDiamond ?? '0x45D45de73465b8913B50974Fc188529dFFb7AfFA'
/** CoNET mainnet（224422）ConetTreasury；勿与 Base 的 {@link BASE_TREASURY} 混淆 */
export const CONET_TREASURY = conet.ConetTreasury ?? '0x540767C2a183871deb22333a271D5e65bF489F22'
export const CONET_USDC = conet.conetUsdc ?? '0xdD0163FE76FC8fbc4a05b21bCe7CE2642968E176'
export const CONET_ACCOUNT_REGISTRY =
  conet.AccountRegistry ?? '0x4afaca09cf8307070a83836223Ae129073eC92e5'

// --- 其他（相对稳定，可后续迁入 JSON）---
export const MERCHANT_POS_MANAGEMENT_CONET = '0xB7Fb42A67100C6e0C26D21A2d75ffed448610fa2'

/** 兼容旧版 BASE_MAINNET_FACTORIES 结构 */
export const BASE_MAINNET_FACTORIES = {
  AA_FACTORY: BASE_AA_FACTORY,
  BEAMIO_ACCOUNT_DEPLOYER: BASE_BEAMIO_ACCOUNT_DEPLOYER,
  CARD_FACTORY: BASE_CARD_FACTORY,
  BeamioCardCCSA_ADDRESS: BASE_CCSA_CARD_ADDRESS,
  ...(BASE_BEAMIO_USER_CARD_FORMATTING_LIB && BASE_BEAMIO_USER_CARD_TRANSFER_LIB
    ? {
        BEAMIO_USER_CARD_FORMATTING_LIB: BASE_BEAMIO_USER_CARD_FORMATTING_LIB,
        BEAMIO_USER_CARD_TRANSFER_LIB: BASE_BEAMIO_USER_CARD_TRANSFER_LIB,
      }
    : {}),
} as const

/** 按链聚合 */
export const CONTRACT_ADDRESSES = {
  base: {
    chainId: BASE_MAINNET_CHAIN_ID,
    aaFactory: BASE_AA_FACTORY,
    beamioAccountDeployer: BASE_BEAMIO_ACCOUNT_DEPLOYER,
    cardFactory: BASE_CARD_FACTORY,
    ccsaCard: BASE_CCSA_CARD_ADDRESS,
    baseTreasury: BASE_TREASURY,
    usdc: USDC_BASE,
    ...(BASE_BEAMIO_USER_CARD_FORMATTING_LIB && BASE_BEAMIO_USER_CARD_TRANSFER_LIB
      ? {
          beamioUserCardFormattingLib: BASE_BEAMIO_USER_CARD_FORMATTING_LIB,
          beamioUserCardTransferLib: BASE_BEAMIO_USER_CARD_TRANSFER_LIB,
        }
      : {}),
  },
  conet: {
    chainId: 224422,
    buint: CONET_BUINT,
    bUnitAirdrop: CONET_BUNIT_AIRDROP_ADDRESS,
    buintRedeemAirdrop: CONET_BUINT_REDEEM_AIRDROP,
    beamioIndexerDiamond: BEAMIO_INDEXER_DIAMOND,
    conetTreasury: CONET_TREASURY,
    conetUsdc: CONET_USDC,
    accountRegistry: CONET_ACCOUNT_REGISTRY,
  },
} as const

export type ChainKey = keyof typeof CONTRACT_ADDRESSES
