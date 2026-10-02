import { Contract, JsonRpcProvider, Wallet, getAddress, hexlify, keccak256, toUtf8Bytes, ZeroHash } from 'ethers'
import { createMessage, encrypt, readKey } from 'openpgp'
import { CONET_RPC } from '@/constants'
import { CONET_ADDRESS_PGP_MANAGER } from '@/conet/constants'

const CONET_CARD_FACTORY = '0xfA52a0CcC96C19cF4b6Ea864615F6d52BD0774FB'
const CONET_ADDRESS_PGP = CONET_ADDRESS_PGP_MANAGER
const CONET_RPC_URL = CONET_RPC

export type KycFieldMode = 'off' | 'optional' | 'required'

export type MembershipKycFormPolicy = {
	enabled: boolean
	merchantName: string
	brandColor?: string
	fields: { name: KycFieldMode; phone: KycFieldMode; email: KycFieldMode }
	offerLabel: string
	offerValue: string
	offerReward: string
}

const provider = new JsonRpcProvider(CONET_RPC_URL)
const CARD_ABI = [
	'function kycIpfsHashOf(address) view returns (bytes32)',
	'function activeMembershipId(address) view returns (uint256)',
	'function getAdminListWithMetadata() view returns (address[] admins, string[] metadatas, address[] parents)',
	'function factoryGateway() view returns (address)',
	'function name() view returns (string)',
]
const PGP_ABI = [
	'function searchKey(address) view returns (string userPgpKeyID, string userPublicKeyArmored, string routePgpKeyID, string routePublicKeyArmored, bool routeOnline)',
]

function fieldMode(raw: unknown, fallback: KycFieldMode): KycFieldMode {
	if (raw === 'required' || raw === 2 || raw === '2') return 'required'
	if (raw === 'off' || raw === 0 || raw === '0') return 'off'
	if (raw === 'optional' || raw === 1 || raw === '1') return 'optional'
	return fallback
}

function armorFromStored(raw: string): string {
	const text = raw.trim()
	if (text.includes('BEGIN PGP PUBLIC KEY')) return text
	try {
		const decoded = atob(text)
		if (decoded.includes('BEGIN PGP PUBLIC KEY')) return decoded
	} catch {
		/* stored value is not base64 armor */
	}
	return ''
}

export async function loadMembershipKycPolicy(cardAddress: string): Promise<MembershipKycFormPolicy | null> {
	const card = getAddress(cardAddress)
	const response = await fetch(`https://beamio.app/api/cardMetadata?cardAddress=${card}`)
	if (!response.ok) return null
	const body = (await response.json()) as { metadata_json?: unknown; metadata?: unknown; name?: string }
	const meta = (body.metadata_json ?? body.metadata ?? body) as {
		name?: string
		backgroundColor?: string
		background_color?: string
		shareTokenMetadata?: {
			kyc?: Record<string, unknown>
			storeName?: string
			businessName?: string
			backgroundColor?: string
			background_color?: string
		}
	}
	const kyc = meta.shareTokenMetadata?.kyc
	if (!kyc || kyc.enabled !== true) return null
	const fields = (kyc.fields ?? {}) as Record<string, unknown>
	const merchantName =
		String(meta.shareTokenMetadata?.storeName || meta.shareTokenMetadata?.businessName || meta.name || 'Merchant')
	const rawBrandColor =
		String(
			meta.shareTokenMetadata?.backgroundColor ||
				meta.shareTokenMetadata?.background_color ||
				meta.backgroundColor ||
				meta.background_color ||
				'',
		).trim()
	const brandColor = /^#[0-9a-f]{6}$/i.test(rawBrandColor) ? rawBrandColor : undefined
	return {
		enabled: true,
		merchantName,
		...(brandColor ? { brandColor } : {}),
		fields: {
			name: fieldMode(fields.name, 'optional'),
			phone: fieldMode(fields.phone, 'off'),
			email: fieldMode(fields.email, 'optional'),
		},
		offerLabel: 'Store Credits',
		offerValue: '',
		offerReward: '',
	}
}

export async function membershipIssueNeedsKyc(cardAddress: string, wallet: string): Promise<boolean> {
	const policy = await loadMembershipKycPolicy(cardAddress).catch(() => null)
	if (!policy?.enabled) return false
	try {
		const card = new Contract(getAddress(cardAddress), CARD_ABI, provider)
		const id = (await card.activeMembershipId(getAddress(wallet))) as bigint
		if (id >= 100n) return false
	} catch {
		return false
	}
	return !(await membershipKycAlreadyLinked(cardAddress, wallet))
}

export async function membershipKycAlreadyLinked(cardAddress: string, wallet: string): Promise<boolean> {
	try {
		const card = new Contract(getAddress(cardAddress), CARD_ABI, provider)
		const hash = (await card.kycIpfsHashOf(getAddress(wallet))) as string
		return Boolean(hash) && hash !== ZeroHash
	} catch {
		return false
	}
}

async function adminEncryptionKeys(cardAddress: string) {
	const card = new Contract(getAddress(cardAddress), CARD_ABI, provider)
	const pgp = new Contract(CONET_ADDRESS_PGP, PGP_ABI, provider)
	const admins = (await card.getAdminListWithMetadata())[0] as string[]
	const keys = []
	for (const admin of admins) {
		try {
			const row = await pgp.searchKey(getAddress(admin))
			const armored = armorFromStored(String(row[1] || ''))
			if (!armored) continue
			keys.push(await readKey({ armoredKey: armored }))
		} catch {
			/* this admin has no usable public key */
		}
	}
	if (keys.length === 0) {
		throw new Error('No merchant admin has a registered encryption key.')
	}
	return keys
}

export async function saveMembershipKycAndLink(params: {
	cardAddress: string
	privateKey: string
	fullName: string
	phone: string
	email: string
	emailOffers: boolean
	smsOffers: boolean
	signerKind: 'wallet' | 'admin'
	subjectWallet: string
}): Promise<void> {
	const signer = new Wallet(params.privateKey.startsWith('0x') ? params.privateKey : `0x${params.privateKey}`)
	const subject = getAddress(params.subjectWallet)
	const payload = JSON.stringify({
		v: 1,
		card: getAddress(params.cardAddress),
		wallet: subject,
		fullName: params.fullName.trim(),
		phone: params.phone.trim(),
		email: params.email.trim(),
		emailOffers: params.emailOffers,
		smsOffers: params.smsOffers,
		savedAt: Date.now(),
	})
	const keys = await adminEncryptionKeys(params.cardAddress)
	const message = await createMessage({ text: payload })
	const armored = await encrypt({ message, encryptionKeys: keys, format: 'armored' })
	const signMessage = await signer.signMessage(signer.address)
	const uploaded = await fetch('https://ipfs.conet.network/api/storageFragment', {
		method: 'POST',
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify({ wallet: signer.address, signMessage, image: armored }),
	})
	if (!uploaded.ok) throw new Error('Could not store the encrypted membership details.')
	const ipfsHash = keccak256(toUtf8Bytes(String(armored)))
	const card = new Contract(getAddress(params.cardAddress), CARD_ABI, provider)
	const factory = (await card.factoryGateway()) as string
	const deadline = Math.floor(Date.now() / 1000) + 600
	const nonce = BigInt(hexlify(crypto.getRandomValues(new Uint8Array(16))))
	const domain = {
		name: 'BeamioUserCardFactory',
		version: '1',
		chainId: 224422,
		verifyingContract: factory || CONET_CARD_FACTORY,
	}
	const value = { wallet: subject, ipfsHash, deadline, nonce }
	const signature =
		params.signerKind === 'admin'
			? await signer.signTypedData(
					domain,
					{
						LinkKycIpfsHashByAdmin: [
							{ name: 'wallet', type: 'address' },
							{ name: 'ipfsHash', type: 'bytes32' },
							{ name: 'deadline', type: 'uint256' },
							{ name: 'nonce', type: 'uint256' },
						],
					},
					value,
				)
			: await signer.signTypedData(
					domain,
					{
						LinkKycIpfsHash: [
							{ name: 'wallet', type: 'address' },
							{ name: 'ipfsHash', type: 'bytes32' },
							{ name: 'deadline', type: 'uint256' },
							{ name: 'nonce', type: 'uint256' },
						],
					},
					value,
				)
	const response = await fetch('https://beamio.app/api/linkMembershipKyc', {
		method: 'POST',
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify({
			cardAddress: getAddress(params.cardAddress),
			wallet: subject,
			ipfsHash,
			deadline: deadline.toString(),
			nonce: nonce.toString(),
			signature,
			signerKind: params.signerKind,
		}),
	})
	const result = (await response.json().catch(() => ({}))) as { success?: boolean; error?: string }
	if (!response.ok || result.success === false) {
		throw new Error(result.error || 'Could not link these membership details to your wallet.')
	}
}
