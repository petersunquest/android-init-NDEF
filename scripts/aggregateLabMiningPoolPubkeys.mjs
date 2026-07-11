#!/usr/bin/env node
/**
 * Aggregate Lab manual staking pubkeys from all CoNET VA hosts into one manifest
 * for CL skim → ConetLabMiningPool payout (validatorLabMiningPoolClPayoutReporter).
 *
 * Each host typically has TWO validator sets during rotation:
 *   - current validator_deposits.json (new / pending-active)
 *   - validator_deposits.json.bak-legacy-* (old / exiting)
 *
 * Reads deployments/conet-lab-mining-pool-staking-hosts.json, SSH each host, merges
 * matching withdrawal_credentials entries from current + legacy backups (deduped by pubkey).
 *
 * Usage:
 *   node scripts/aggregateLabMiningPoolPubkeys.mjs
 *   DRY_RUN=1 node scripts/aggregateLabMiningPoolPubkeys.mjs
 *   LAB_INCLUDE_LEGACY_BACKUPS=0 node scripts/aggregateLabMiningPoolPubkeys.mjs  # current only
 *   OUT=deployments/conet-lab-mining-pool-pubkeys.json node scripts/aggregateLabMiningPoolPubkeys.mjs
 */
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { execSync } from 'node:child_process'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = path.join(__dirname, '..')

const HOSTS_CONFIG =
	process.env.LAB_STAKING_HOSTS_FILE?.trim() ||
	path.join(REPO_ROOT, 'deployments/conet-lab-mining-pool-staking-hosts.json')
const OUT =
	process.env.OUT?.trim() || path.join(REPO_ROOT, 'deployments/conet-lab-mining-pool-pubkeys.json')
const DRY_RUN = ['1', 'true', 'yes'].includes(String(process.env.DRY_RUN || '').toLowerCase())

function normalizeHex(h) {
	const s = String(h || '').trim()
	if (!s) return ''
	return s.startsWith('0x') ? s.toLowerCase() : `0x${s.toLowerCase()}`
}

function normalizePubkey(pk) {
	const h = normalizeHex(pk)
	if (h.length !== 98) {
		throw new Error(`bad pubkey length ${h.length}: ${h.slice(0, 20)}…`)
	}
	return h
}

function loadHostsConfig() {
	if (!fs.existsSync(HOSTS_CONFIG)) {
		throw new Error(`missing hosts config: ${HOSTS_CONFIG}`)
	}
	return JSON.parse(fs.readFileSync(HOSTS_CONFIG, 'utf8'))
}

function sshRemote(hostCfg, ip, shellCmd) {
	const user = hostCfg.sshUser || 'peter'
	const remote = `${user}@${ip}`
	return execSync(`ssh -o ConnectTimeout=25 -o BatchMode=yes ${remote} ${JSON.stringify(shellCmd)}`, {
		encoding: 'utf8',
		maxBuffer: 128 * 1024 * 1024,
	})
}

function fetchRemoteJson(hostCfg, ip, relPath) {
	const dir = hostCfg.newconetDir || '/home/peter/ethereum-pos-mainnet'
	const full = `${dir}/${relPath}`
	const raw = sshRemote(hostCfg, ip, `cat '${full}'`)
	return JSON.parse(raw)
}

function listLegacyBackupPaths(hostCfg, ip) {
	const dir = hostCfg.newconetDir || '/home/peter/ethereum-pos-mainnet'
	const out = sshRemote(
		hostCfg,
		ip,
		`ls -1 '${dir}'/validator_deposits.json.bak-legacy-* 2>/dev/null || true`
	).trim()
	if (!out) return []
	return out
		.split('\n')
		.map((line) => line.trim())
		.filter(Boolean)
		.map((abs) => {
			const prefix = `${dir}/`
			return abs.startsWith(prefix) ? abs.slice(prefix.length) : path.basename(abs)
		})
}

function resolveIncludeLegacy(cfg) {
	if (process.env.LAB_INCLUDE_LEGACY_BACKUPS != null) {
		return ['1', 'true', 'yes'].includes(String(process.env.LAB_INCLUDE_LEGACY_BACKUPS).toLowerCase())
	}
	return cfg.includeLegacyDepositBackups !== false
}

function resolveWalletSets(cfg) {
	const env = process.env.LAB_STAKING_WALLET_SETS?.trim()
	if (env) {
		const n = Number(env)
		if (Number.isFinite(n) && n >= 1) return Math.floor(n)
	}
	return Number(cfg.walletSets) >= 1 ? Math.floor(cfg.walletSets) : 1
}

function collectHostPubkeys(hostCfg, hostEntry, selfCred, includeLegacy) {
	const ip = hostEntry.ip
	const dir = hostCfg.newconetDir || '/home/peter/ethereum-pos-mainnet'
	const mainFile = hostCfg.depositJsonFile || 'validator_deposits.json'
	const sourceFiles = [mainFile]

	const depositsList = [fetchRemoteJson(hostCfg, ip, mainFile)]

	if (includeLegacy) {
		for (const rel of listLegacyBackupPaths(hostCfg, ip)) {
			if (sourceFiles.includes(rel)) continue
			sourceFiles.push(rel)
			depositsList.push(fetchRemoteJson(hostCfg, ip, rel))
		}
	}

	const byPubkey = new Map()
	const legacyNonLabCred = []
	for (let fileIdx = 0; fileIdx < depositsList.length; fileIdx++) {
		const deposits = depositsList[fileIdx]
		const isLegacySource = fileIdx > 0
		if (!Array.isArray(deposits)) throw new Error(`${ip}: deposit json is not an array`)
		for (const e of deposits) {
			const wc = normalizeHex(e.withdrawal_credentials)
			if (!isLegacySource && wc !== selfCred) {
				throw new Error(
					`${ip}: withdrawal_credentials mismatch on ${String(e.pubkey).slice(0, 18)}…: ${wc}`
				)
			}
			if (isLegacySource && wc !== selfCred) {
				legacyNonLabCred.push(normalizePubkey(e.pubkey))
			}
			const pk = normalizePubkey(e.pubkey)
			if (!byPubkey.has(pk)) byPubkey.set(pk, e)
		}
	}

	return {
		ip,
		slotCount: hostEntry.count,
		sourceFiles: sourceFiles.map((f) => `${dir}/${f}`),
		pubkeys: [...byPubkey.keys()],
		legacyNonLabCredCount: new Set(legacyNonLabCred).size,
	}
}

function main() {
	const cfg = loadHostsConfig()
	const selfCred = normalizeHex(cfg.selfWithdrawalCredentials)
	const includeLegacy = resolveIncludeLegacy(cfg)
	const walletSets = resolveWalletSets(cfg)
	const hostsOut = []
	const allPubkeys = new Set()
	let expectedTotal =
		Number(cfg.expectedValidatorCount) > 0
			? Math.floor(cfg.expectedValidatorCount)
			: cfg.hosts.reduce((sum, h) => sum + h.count * walletSets, 0)

	for (const h of cfg.hosts) {
		const expectHost = h.count * walletSets
		console.log(
			`==> ${h.ip} merge ${includeLegacy ? 'current + legacy backups' : 'current only'} (expect ~${expectHost} pubkeys)`
		)
		const { pubkeys, sourceFiles, legacyNonLabCredCount } = collectHostPubkeys(cfg, h, selfCred, includeLegacy)
		for (const pk of pubkeys) {
			if (allPubkeys.has(pk)) {
				throw new Error(`duplicate pubkey across hosts: ${pk}`)
			}
			allPubkeys.add(pk)
		}
		hostsOut.push({
			ip: h.ip,
			slotCount: h.count,
			walletSets,
			pubkeyCount: pubkeys.length,
			expectedPubkeyCount: expectHost,
			legacyNonLabCredCount,
			sourceFiles,
			pubkeys,
		})
		console.log(
			`    ok ${pubkeys.length} pubkeys from ${sourceFiles.length} file(s)` +
				(legacyNonLabCredCount ? ` (${legacyNonLabCredCount} legacy non-Redeem wc)` : '')
		)
		if (pubkeys.length < expectHost) {
			console.warn(
				`    WARN ${h.ip}: got ${pubkeys.length} < expected ${expectHost} (missing legacy backup or incomplete deposit?)`
			)
		}
	}

	if (allPubkeys.size !== expectedTotal) {
		console.warn(
			`WARN: pubkey total ${allPubkeys.size} != configured expected ${expectedTotal} (continuing; check legacy backups on each host)`
		)
	}

	const manifest = {
		version: 2,
		generatedAt: new Date().toISOString(),
		redeem: normalizeHex(cfg.redeem),
		miningPool: normalizeHex(cfg.miningPool),
		selfWithdrawalCredentials: selfCred,
		walletSets,
		includeLegacyDepositBackups: includeLegacy,
		expectedValidatorCount: expectedTotal,
		activeValidatorsPerWave: cfg.activeValidatorsPerWave ?? Math.floor(expectedTotal / walletSets),
		hosts: hostsOut,
		pubkeys: [...allPubkeys],
	}

	console.log(`\nTotal: ${manifest.pubkeys.length} pubkeys (target ${expectedTotal}) → ${OUT}`)
	if (DRY_RUN) {
		console.log('DRY_RUN=1: not writing file')
		return
	}
	fs.mkdirSync(path.dirname(OUT), { recursive: true })
	fs.writeFileSync(OUT, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8')
	console.log('written.')
}

main()
