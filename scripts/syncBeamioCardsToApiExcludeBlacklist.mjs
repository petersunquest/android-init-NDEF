#!/usr/bin/env node
/**
 * Sync beamio_cards → API exclude blacklist (static file + optional DB dynamic table).
 *
 * Policy (no runtime whitelist gate):
 * - Keep visible on client: only the three CoNET merchant program cards below.
 * - Blacklist everything else in beamio_cards (Base-legacy + other CoNET deploys).
 *
 * Usage (on API host with PG access):
 *   DB_URL='postgres://...' node scripts/syncBeamioCardsToApiExcludeBlacklist.mjs --dry-run
 *   DB_URL='postgres://...' node scripts/syncBeamioCardsToApiExcludeBlacklist.mjs --apply-db
 *   DB_URL='postgres://...' node scripts/syncBeamioCardsToApiExcludeBlacklist.mjs --write-static
 *
 * `--write-static` patches src/x402sdk/src/apiExcludedUserCards.ts (Base-legacy block).
 */
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import pg from 'pg'
import { ethers } from 'ethers'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(__dirname, '..')

/** Client-visible merchant cards (reference for this script only — not a runtime whitelist). */
const CLIENT_VISIBLE_MERCHANT_CARDS = [
	'0xc06055AEEd896F832e602a5876D2Dbe1CB365A8A',
	'0xB24D242A320b8dd756572b410645FE41Cd07FC8C',
	'0xafE482D2612327a0D723544B9fB713C514a793a2',
].map((a) => ethers.getAddress(a).toLowerCase())

const VISIBLE_SET = new Set(CLIENT_VISIBLE_MERCHANT_CARDS)

const CONET_RPC =
	(process.env.CONET_RPC_URL || process.env.CONET_RPC || 'https://publicrpc.conet.network').trim()
const BASE_RPC = (process.env.BASE_RPC_URL || 'https://base-rpc.conet.network').trim()
const DB_URL = process.env.DB_URL || process.env.DATABASE_URL || ''

const conetProvider = new ethers.JsonRpcProvider(CONET_RPC, 224422)
const baseProvider = new ethers.JsonRpcProvider(BASE_RPC, 8453)

const args = new Set(process.argv.slice(2))
const dryRun = args.has('--dry-run') || (!args.has('--apply-db') && !args.has('--write-static'))
const applyDb = args.has('--apply-db')
const writeStatic = args.has('--write-static')

function readExistingStaticExcludes() {
	const file = path.join(ROOT, 'src/x402sdk/src/apiExcludedUserCards.ts')
	const src = fs.readFileSync(file, 'utf8')
	const re = /'(0x[0-9a-f]{40})'/gi
	const out = new Set()
	let m
	while ((m = re.exec(src)) !== null) out.add(m[1].toLowerCase())
	return out
}

async function listBeamioCardsFromDb() {
	if (!DB_URL) throw new Error('Set DB_URL or DATABASE_URL')
	const client = new pg.Client({ connectionString: DB_URL })
	await client.connect()
	try {
		const { rows } = await client.query(
			`SELECT card_address FROM beamio_cards WHERE card_address IS NOT NULL AND TRIM(card_address) <> '' ORDER BY created_at ASC`
		)
		const out = []
		const seen = new Set()
		for (const r of rows) {
			try {
				const addr = ethers.getAddress(String(r.card_address).trim())
				const lower = addr.toLowerCase()
				if (seen.has(lower)) continue
				seen.add(lower)
				out.push(addr)
			} catch {
				/* skip malformed */
			}
		}
		return out
	} finally {
		await client.end().catch(() => {})
	}
}

async function classifyCard(addr) {
	const lower = addr.toLowerCase()
	if (VISIBLE_SET.has(lower)) {
		return { addr, lower, kind: 'visible', conetCode: null, baseCode: null }
	}
	const [conetCode, baseCode] = await Promise.all([
		conetProvider.getCode(addr),
		baseProvider.getCode(addr),
	])
	const onConet = conetCode && conetCode !== '0x'
	const onBase = baseCode && baseCode !== '0x'
	let kind = 'unknown'
	if (onConet) kind = 'conet-other'
	else if (onBase) kind = 'base-legacy'
	else kind = 'no-code'
	return { addr, lower, kind, conetCode: conetCode?.length ?? 0, baseCode: baseCode?.length ?? 0 }
}

async function applyToDb(toExclude, excludedBy) {
	const client = new pg.Client({ connectionString: DB_URL })
	await client.connect()
	try {
		await client.query(`CREATE TABLE IF NOT EXISTS beamio_api_excluded_user_cards (
			card_address TEXT PRIMARY KEY,
			excluded_by TEXT NOT NULL,
			created_at TIMESTAMPTZ DEFAULT NOW()
		)`)
		for (const lower of toExclude) {
			await client.query(
				`INSERT INTO beamio_api_excluded_user_cards (card_address, excluded_by)
				 VALUES ($1, $2)
				 ON CONFLICT (card_address) DO UPDATE SET excluded_by = EXCLUDED.excluded_by`,
				[lower, excludedBy.toLowerCase()]
			)
		}
	} finally {
		await client.end().catch(() => {})
	}
}

function patchStaticFile(baseLegacyLowers, existingStatic) {
	const file = path.join(ROOT, 'src/x402sdk/src/apiExcludedUserCards.ts')
	let src = fs.readFileSync(file, 'utf8')
	const markerStart = '/** Base-legacy beamio_cards (auto-sync: scripts/syncBeamioCardsToApiExcludeBlacklist.mjs) */'
	const markerEnd = '/** END Base-legacy beamio_cards auto-sync */'

	const newEntries = [...baseLegacyLowers]
		.filter((l) => !existingStatic.has(l) && !VISIBLE_SET.has(l))
		.sort()
		.map((l) => `\t'${l}',`)

	if (newEntries.length === 0) {
		console.log('[write-static] no new Base-legacy addresses to append')
		return
	}

	const block = `${markerStart}\n${newEntries.join('\n')}\n${markerEnd}`

	if (src.includes(markerStart)) {
		src = src.replace(new RegExp(`${escapeRegExp(markerStart)}[\\s\\S]*?${escapeRegExp(markerEnd)}`), block)
	} else {
		src = src.replace(
			/(\t'0x52af5f5e7c136cc1bd596d64cb44eb7f5c9d2d6c',\n)(\])$/,
			`$1${newEntries.join('\n')}\n$2`
		)
		// fallback: insert before closing ])
		if (!src.includes(markerStart)) {
			src = src.replace(/\n(\])\n\nexport function registerDynamic/, `\n${block}\n$1\n\nexport function registerDynamic`)
		}
	}

	fs.writeFileSync(file, src)
	console.log(`[write-static] appended ${newEntries.length} Base-legacy address(es) to apiExcludedUserCards.ts`)
}

function escapeRegExp(s) {
	return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

async function main() {
	const existingStatic = readExistingStaticExcludes()
	console.log(`Existing static excludes: ${existingStatic.size}`)
	console.log(`Client-visible (never blacklist): ${CLIENT_VISIBLE_MERCHANT_CARDS.join(', ')}`)

	const cards = await listBeamioCardsFromDb()
	console.log(`beamio_cards rows: ${cards.length}`)

	const toExclude = new Set()
	const baseLegacy = new Set()
	const summary = { visible: 0, 'base-legacy': 0, 'conet-other': 0, 'no-code': 0, already: 0 }

	for (const addr of cards) {
		const row = await classifyCard(addr)
		summary[row.kind === 'visible' ? 'visible' : row.kind] =
			(summary[row.kind === 'visible' ? 'visible' : row.kind] ?? 0) + 1
		if (row.kind === 'visible') continue
		if (existingStatic.has(row.lower)) {
			summary.already++
			continue
		}
		toExclude.add(row.lower)
		if (row.kind === 'base-legacy') baseLegacy.add(row.lower)
	}

	console.log('Classification:', summary)
	console.log(`New blacklist candidates: ${toExclude.size} (Base-legacy: ${baseLegacy.size})`)

	if (dryRun) {
		console.log('\n[dry-run] Sample new excludes (first 20):')
		console.log([...toExclude].slice(0, 20).join('\n'))
		console.log('\nRe-run with --apply-db and/or --write-static to persist.')
		return
	}

	const excludedBy = '0x0000000000000000000000000000000000000001'

	if (applyDb) {
		await applyToDb(toExclude, excludedBy)
		console.log(`[apply-db] inserted/updated ${toExclude.size} row(s) in beamio_api_excluded_user_cards`)
	}

	if (writeStatic) {
		patchStaticFile(baseLegacy, existingStatic)
	}
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
