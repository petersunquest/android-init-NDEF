#!/usr/bin/env node
/**
 * One-shot: write LongDhang CoNET program icon into shareTokenMetadata.icon/image
 * from the first issued coupon icon (not couponImage banner).
 *
 * Usage (on API host with METADATA_BASE + DB):
 *   node scripts/repairLongDhangProgramIconMetadata.mjs
 *   node scripts/repairLongDhangProgramIconMetadata.mjs 0xc06055AEEd896F832e602a5876D2Dbe1CB365A8A
 */
import { ethers } from 'ethers'
import { createRequire } from 'node:module'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const sdkRoot = process.env.X402SDK_ROOT || path.resolve(__dirname, '../src/x402sdk')
const requireFromSdk = createRequire(path.join(sdkRoot, 'package.json'))

const DEFAULT_CARD = '0xc06055AEEd896F832e602a5876D2Dbe1CB365A8A'

async function main() {
	const cardArg = process.argv[2]?.trim() || DEFAULT_CARD
	if (!ethers.isAddress(cardArg)) {
		console.error('Invalid card address:', cardArg)
		process.exit(1)
	}
	const cardAddress = ethers.getAddress(cardArg)

	const { getCardByAddress } = requireFromSdk('./dist/db.js')
	const { applyBeamioCardShareMetadataUpdate } = requireFromSdk('./dist/MemberCard.js')
	const { ensureShareTokenProgramIconAssembled, readFirstShareCatalogIconUrl } = requireFromSdk(
		'./dist/shareTokenProgramIcon.js'
	)

	const row = await getCardByAddress(cardAddress)
	if (!row?.metadata || typeof row.metadata !== 'object') {
		console.error('Card not found or missing metadata:', cardAddress)
		process.exit(1)
	}
	const meta = row.metadata
	const shareRaw = meta.shareTokenMetadata
	const share =
		shareRaw && typeof shareRaw === 'object' && !Array.isArray(shareRaw)
			? { ...(shareRaw) }
			: {}

	const beforeIcon = typeof share.icon === 'string' ? share.icon : ''
	const catalogIcon = readFirstShareCatalogIconUrl(share)
	const assembled = ensureShareTokenProgramIconAssembled(share)

	console.log('card:', cardAddress)
	console.log('before share.icon:', beforeIcon || '(empty)')
	console.log('catalog icon:', catalogIcon || '(empty)')
	console.log('after share.icon:', assembled.icon || '(empty)')

	if (!assembled.icon && !catalogIcon) {
		console.error('No coupon/catalog icon to assemble — abort.')
		process.exit(1)
	}

	if (beforeIcon === assembled.icon && typeof share.image === 'string' && share.image === assembled.image) {
		console.log('Already up to date — no write.')
		return
	}

	const r = await applyBeamioCardShareMetadataUpdate({
		cardAddress,
		shareTokenMetadata: assembled,
		...(Array.isArray(meta.tiers) && meta.tiers.length > 0 ? { tiers: meta.tiers } : {}),
		...(meta.upgradeType != null ? { upgradeType: Number(meta.upgradeType) } : {}),
		...(typeof meta.transferWhitelistEnabled === 'boolean'
			? { transferWhitelistEnabled: meta.transferWhitelistEnabled }
			: {}),
	})

	if (!r.success) {
		console.error('applyBeamioCardShareMetadataUpdate failed:', r.error)
		process.exit(1)
	}
	console.log('OK — metadata updated for', cardAddress)
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
