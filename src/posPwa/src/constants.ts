export const BEAMIO_API = 'https://beamio.app'
export const CONET_MAINNET_CHAIN_ID = 224422

/** Default merchant UserCard EIP-712 chain (CoNET). */
export const MERCHANT_USER_CARD_CHAIN_ID = CONET_MAINNET_CHAIN_ID

export const CONET_RPC = 'https://publicrpc.conet.network'
export const BASE_RPC = 'https://base-rpc.conet.network'
export const ACCOUNT_REGISTRY = '0xfFDc8d2021A41F4638Cb3eCf58B5155383EE9f6d'
/** Base USDC (charge container kind=0). */
export const USDC_BASE = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'
/** Deprecated global cards — exclude from charge routing (iOS parity). */
export const DEPRECATED_INFRA_CARD = '0xBCcfA50d2a5917C7A8662177F5F4B7A175787270'

/** POS Welcome hero — bundled asset (same illustration as iOS `marketExampleTerminalHeroImageURL`). */
export const TERMINAL_HERO_IMAGE_URL = `${import.meta.env.BASE_URL}terminal-hero.png`

/** iOS softPOS `cashTreesWebSurfaceColor` — LaunchScreen / splash / WebView letterbox. */
export const POS_WEB_SURFACE_HEX = '#000414'
