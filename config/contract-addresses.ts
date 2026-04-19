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
export const BASE_TREASURY = base.BASE_TREASURY ?? '0x5c64a8b0935DA72d60933bBD8cD10579E1C40c58'
export const BEAMIO_USER_CARD_ASSET_ADDRESS = base.BEAMIO_USER_CARD_ASSET_ADDRESS ?? '0xB7644DDb12656F4854dC746464af47D33C206F0E'
export const PURCHASING_CARD_METADATA_ADDRESS = base.PURCHASING_CARD_METADATA_ADDRESS ?? '0xf99018dffdb0c5657c93ca14db2900cebe1168a7'
export const USDC_BASE = base.USDC_BASE ?? '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'
/** 空串表示未配置；运行 `npm run deploy:usercard-libraries:base` 后写入 base-addresses.json */
export const BASE_BEAMIO_USER_CARD_FORMATTING_LIB = (base.BEAMIO_USER_CARD_FORMATTING_LIB ?? '').trim()
export const BASE_BEAMIO_USER_CARD_TRANSFER_LIB = (base.BEAMIO_USER_CARD_TRANSFER_LIB ?? '').trim()

// --- CoNET Mainnet ---
export const CONET_BUINT = conet.BUint ?? '0x4A3E59519eE72B9Dcf376f0617fF0a0a5a1ef879'
export const CONET_BUNIT_AIRDROP_ADDRESS = conet.BUnitAirdrop ?? '0xbE1CF54f76BcAb40DC49cDcD7FBA525b9ABDa264'
/** B-Unit 兑换码空投（EIP-712 admin 提交）；见 deployments/conet-BuintRedeemAirdrop.json */
export const CONET_BUINT_REDEEM_AIRDROP = conet.BuintRedeemAirdrop ?? '0x0DC615bAc14411CbDCd082fe59CBdDA8768615B0'
export const BEAMIO_INDEXER_DIAMOND = conet.BeamioIndexerDiamond ?? '0xd990719B2f05ccab4Acdd5D7A3f7aDfd2Fc584Fe'
export const CONET_TREASURY = conet.ConetTreasury ?? '0xA7fb50fE8e09E17E74081014d49f4E80729cCA48'
export const CONET_USDC = conet.conetUsdc ?? '0x28fBBb6C5C06A4736B00A540b66378091c224456'
export const CONET_ACCOUNT_REGISTRY =
  conet.AccountRegistry ?? '0x2dF9c4c51564FfF861965572CE11ebe27d3C1B35'

// --- 其他（相对稳定，可后续迁入 JSON）---
export const MERCHANT_POS_MANAGEMENT_CONET = '0x3Eb57035d3237Fce4b1cB273662E875EdfA0D54f'

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
