#!/usr/bin/env tsx

/**
 * Verify the LongDhang Base -> CoNET migration through the Beamio API.
 *
 * Usage:
 *   npx tsx scripts/verifyLongDhangConetMigration.ts <newCoNETCard>
 *
 * Env:
 *   BEAMIO_API_URL=https://beamio.app
 */

const apiBase = (process.env.BEAMIO_API_URL || 'https://beamio.app').replace(/\/+$/, '')
const newCardAddress = process.argv[2]?.trim()

if (!newCardAddress || !/^0x[0-9a-fA-F]{40}$/.test(newCardAddress)) {
	console.error('Usage: npx tsx scripts/verifyLongDhangConetMigration.ts <newCoNETCard>')
	process.exit(1)
}

async function main(): Promise<void> {
	const res = await fetch(`${apiBase}/api/longDhangMigrationVerify`, {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ newCardAddress }),
	})
	const data = await res.json()
	if (!res.ok || !data?.success) {
		console.error(JSON.stringify(data, null, 2))
		process.exit(1)
	}
	console.log(JSON.stringify({
		success: true,
		newCardAddress: data.newCardAddress,
		snapshotHash: data.snapshotHash,
		totalRows: data.totalRows,
		matches: data.matches,
		mismatchCount: Array.isArray(data.mismatches) ? data.mismatches.length : 0,
		mismatches: data.mismatches,
		terminals: data.terminals,
	}, null, 2))
}

main().catch((error) => {
	console.error(error instanceof Error ? error.stack || error.message : String(error))
	process.exit(1)
})
