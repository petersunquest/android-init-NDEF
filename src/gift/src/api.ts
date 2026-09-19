import { ethers } from 'ethers'

export const CONET_RPC = 'https://publicrpc.conet.network'
export const CONET_USDC = '0x5209865D404aA5646eDe5B91CD4218909eA72eDA'
export const CONET_CARD_FACTORY = '0xfA52a0CcC96C19cF4b6Ea864615F6d52BD0774FB'

export type GiftCard = {
  address: string
  owner: string
  cardCurrency: number
  pointsUnitPriceE6: string
  name: string
  description: string
  icon?: string
  currency: string
  membershipFeeE6: string
  stripeConnected: boolean
}

export async function loadGiftCard(cardAddress: string): Promise<GiftCard> {
  if (!ethers.isAddress(cardAddress)) throw new Error('Invalid merchant card address')
  const normalized = ethers.getAddress(cardAddress)
  const response = await fetch(`/api/cardMetadata?cardAddress=${encodeURIComponent(normalized)}`)
  if (!response.ok) throw new Error('Unable to load this merchant Gift page')
  const body = await response.json() as any
  const metadata = body.metadata_json ?? body.metadata ?? body
  const baseMembership = metadata.baseMembership ?? {}
  const tiers = Array.isArray(metadata.tiers) ? metadata.tiers : []
  const legacyFee = tiers[0]?.membershipFeeE6 ?? '0'
  const membershipFeeE6 = String(baseMembership.membershipFeeE6 ?? legacyFee ?? '0')
  const stripe = await fetch('/api/merchantCardStripe/status', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ cardAddress: normalized }),
  }).then(async (r) => r.ok ? r.json() : null).catch(() => null)
  const provider = new ethers.JsonRpcProvider(CONET_RPC)
  const card = new ethers.Contract(normalized, [
    'function owner() view returns (address)',
    'function currency() view returns (uint8)',
    'function pointsUnitPriceInCurrencyE6() view returns (uint256)',
  ], provider)
  const [owner, cardCurrency, pointsUnitPriceE6] = await Promise.all([
    card.owner(), card.currency(), card.pointsUnitPriceInCurrencyE6(),
  ])
  return {
    address: normalized,
    owner: ethers.getAddress(owner),
    cardCurrency: Number(cardCurrency),
    pointsUnitPriceE6: String(pointsUnitPriceE6),
    name: String(metadata.name ?? 'Merchant Gift'),
    description: String(metadata.description ?? 'Purchase a Gift for this merchant program.'),
    icon: typeof metadata.icon === 'string' ? metadata.icon : undefined,
    currency: String(metadata.currency ?? metadata.shareTokenMetadata?.currency ?? 'USD'),
    membershipFeeE6,
    stripeConnected: Boolean(stripe?.connected && stripe?.topupEnabled),
  }
}

export function makeRedeemCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(24))
  return `beamio-gift-${Array.from(bytes, (value) => value.toString(16).padStart(2, '0')).join('')}`
}

export function redeemHash(code: string): string {
  return ethers.keccak256(ethers.toUtf8Bytes(code.trim()))
}

export function redeemUrl(cardAddress: string, code: string): string {
  const params = new URLSearchParams({ beamiocard: cardAddress, redeemcode: code })
  return `https://beamio.app/app/#/?${params.toString()}`
}

export async function quoteGift(cardAddress: string, amountFiat6: string): Promise<string> {
  const response = await fetch('/api/giftQuote', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ cardAddress, amountFiat6 }),
  })
  const body = await response.json()
  if (!response.ok || !body.success) throw new Error(body.error ?? 'Unable to quote Gift payment')
  return String(body.quotedUsdc6)
}

export async function createWalletGift(params: {
  cardAddress: string
  from: string
  code: string
  membershipFeeE6: string
  topupPrincipalE6: string
  usdcAmount: string
  signature: string
  nonce: string
  validAfter: string
  validBefore: string
}): Promise<any> {
  const response = await fetch('/api/purchaseMerchantGiftRedeem', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      ...params,
      redeemHash: redeemHash(params.code),
      payWith: 'usdc',
      redeemValidBefore: String(Math.floor(Date.now() / 1000) + 365 * 24 * 3600),
    }),
  })
  const body = await response.json()
  if (!response.ok || !body.success) throw new Error(body.error ?? 'Gift purchase failed')
  return body
}

export async function createStripeGift(params: {
  cardAddress: string
  buyerEoa: string
  amountFiat6: string
  currency: string
  membershipFeeE6: string
  topupPrincipalE6: string
  redeemHash: string
}): Promise<{ sessionId: string; url: string }> {
  const response = await fetch('/api/merchantCardStripe/createCheckout', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      ...params,
      kind: 'gift',
      giftPaymentMode: 'stripe',
      giftMembershipFeeE6: params.membershipFeeE6,
      giftTopupPrincipalE6: params.topupPrincipalE6,
      giftRedeemValidBefore: String(Math.floor(Date.now() / 1000) + 365 * 24 * 3600),
      businessIdempotencyKey: `gift:${params.redeemHash.slice(2, 26)}`,
    }),
  })
  const body = await response.json()
  if (!response.ok || !body.url) throw new Error(body.error ?? 'Unable to start Stripe checkout')
  return body
}

export async function pollStripeGift(sessionId: string): Promise<any> {
  const response = await fetch('/api/merchantCardStripe/poll', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ sessionId }),
  })
  const body = await response.json()
  if (!response.ok) throw new Error(body.error ?? 'Unable to check Stripe payment')
  return body
}

export async function buildWalletAuthorization(params: {
  provider: ethers.BrowserProvider
  from: string
  to: string
  value: string
}): Promise<{ signature: string; nonce: string; validAfter: string; validBefore: string }> {
  const signer = await params.provider.getSigner()
  const token = new ethers.Contract(CONET_USDC, ['function name() view returns (string)'], params.provider)
  const tokenName = await token.name().catch(() => 'CoNET USD Coin')
  const validAfter = Math.floor(Date.now() / 1000) - 30
  const validBefore = validAfter + 900
  const nonce = ethers.hexlify(ethers.randomBytes(32))
  const signature = await signer.signTypedData(
    { name: tokenName, version: '1', chainId: 224422, verifyingContract: CONET_USDC },
    {
      TransferWithAuthorization: [
        { name: 'from', type: 'address' },
        { name: 'to', type: 'address' },
        { name: 'value', type: 'uint256' },
        { name: 'validAfter', type: 'uint256' },
        { name: 'validBefore', type: 'uint256' },
        { name: 'nonce', type: 'bytes32' },
      ],
    },
    { from: params.from, to: params.to, value: params.value, validAfter, validBefore, nonce },
  )
  return { signature, nonce, validAfter: String(validAfter), validBefore: String(validBefore) }
}
