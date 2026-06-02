#!/usr/bin/env node
/**
 * Batch-trigger Blockscout ERC-1155 metadata refetch (PRO API).
 *
 * PRO keys (`proapi_…`) work for:
 * - Reads:  https://api.blockscout.com/{chainId}/api/v2/...?apikey=...
 * - Refetch PATCH (Bearer): https://base.blockscout.com/api/v2/tokens/{card}/instances/{tokenId}/refetch-metadata
 *
 * Usage:
 *   BLOCKSCOUT_API_KEY='proapi_…' node scripts/refetchBlockscoutErc1155Metadata.mjs 0xCard1 0xCard2
 *
 * Optional:
 *   BLOCKSCOUT_REFETCH_API_ROOT=https://base.blockscout.com
 *   TOKEN_ID=0   (default 0 — program card metadata)
 *   TOKEN_IDS=100,101,102  (batch; overrides TOKEN_ID when set)
 */
const apiKey = process.env.BLOCKSCOUT_API_KEY?.trim()
const refetchRoot = (
	process.env.BLOCKSCOUT_REFETCH_API_ROOT || 'https://base.blockscout.com'
).replace(/\/$/, '')
const tokenIdsFromEnv = process.env.TOKEN_IDS?.trim()
	? process.env.TOKEN_IDS.split(/[,\s]+/).map((s) => s.trim()).filter(Boolean)
	: null
const tokenId = process.env.TOKEN_ID?.trim() || '0'
const cards = process.argv.slice(2).filter((a) => /^0x[a-fA-F0-9]{40}$/.test(a))

if (!apiKey) {
	console.error('BLOCKSCOUT_API_KEY is required (proapi_… from https://dev.blockscout.com/)')
	process.exit(1)
}
if (cards.length === 0) {
	console.error(
		'Usage: BLOCKSCOUT_API_KEY=… node scripts/refetchBlockscoutErc1155Metadata.mjs <cardAddress> …'
	)
	process.exit(1)
}

const tokenIdsToRefetch = tokenIdsFromEnv?.length ? tokenIdsFromEnv : [tokenId]

for (const card of cards) {
	for (const tid of tokenIdsToRefetch) {
		const url = `${refetchRoot}/api/v2/tokens/${card}/instances/${encodeURIComponent(tid)}/refetch-metadata`
		try {
			const res = await fetch(url, {
				method: 'PATCH',
				headers: {
					accept: 'application/json',
					authorization: `Bearer ${apiKey}`,
					'content-type': 'application/json',
				},
				body: '{}',
			})
			const text = await res.text()
			console.log(`${card}#${tid}: HTTP ${res.status} ${text.slice(0, 200)}`)
			if (!res.ok && res.status !== 202) process.exitCode = 1
		} catch (e) {
			console.error(`${card}#${tid}:`, e?.message ?? e)
			process.exitCode = 1
		}
	}
}
