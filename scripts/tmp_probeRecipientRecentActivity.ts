import { fetchMergedRecentActivityFromIndexer } from '../src/SilentPassUI/src/pages/History/recentActivityIndexerMerge'

const EOA = '0x3Ca84050541F4A2f570F717C9D52624161dFaa7f'
const TX = '0x0f0b28d558baec61ea5e7920405ddaa8b6405370dab3cc3c2fe87dde406fd5fb'

async function main() {
	const { items, error, trusted } = await fetchMergedRecentActivityFromIndexer([EOA], {
		maxReturn: 30,
	})
	console.log('trusted', trusted, 'error', error, 'count', items.length)
	const hit = items.find((i) => i.id.toLowerCase() === TX.toLowerCase())
	console.log('giftHit', Boolean(hit))
	if (hit) {
		console.log(
			JSON.stringify(
				{
					id: hit.id,
					type: hit.type,
					title: hit.title,
					isInbound: hit.isInbound,
					isMerchantCharge: hit.isMerchantCharge,
					amountFiat: hit.amountFiat,
					handle: hit.handle,
					counterpartyAddress: hit.counterpartyAddress,
				},
				null,
				2,
			),
		)
	}
	console.log(
		'top8',
		items.slice(0, 8).map((i) => ({
			id: i.id.slice(0, 12),
			type: i.type,
			in: i.isInbound,
			mc: i.isMerchantCharge,
			title: i.title,
			fiat: i.amountFiat,
		})),
	)
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
