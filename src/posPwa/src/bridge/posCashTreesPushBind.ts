/**
 * Native shell push: bind terminal EOA → device token → POST /api/registerPushDevice.
 * Parity with SilentPassUI cashTreesPushBind (independent copy — no cross-project import).
 * iOS APNs (64-hex); Android FCM when shell supports bindPushIdentity.
 *
 * On /home: query POST /api/pushDeviceStatus (scope=pos); if not registered, re-bind until API has a row.
 */

import { ethers } from 'ethers'
import { BEAMIO_API } from '@/constants'
import { getSessionPrivateKeyHex, getSessionWalletAddress } from '@/wallet/posWalletService'

const IOS_BUNDLE_ID = 'com.beamio.app.pos'
/** Play Store applicationId / FCM package (Android softPOS). */
const ANDROID_BUNDLE_ID = 'com.beamio.pos'

type PushPlatform = 'ios' | 'android'
type CashTreesHost = 'ios' | 'android' | null

type PushTokenDetail = {
	action?: string
	deviceToken?: string
	eoa?: string
	pgpKeyId?: string
	platform?: string
	bundleId?: string
}

let listenerAttached = false
let lastRegisteredToken = ''
let lastSyncedUnread = -1
let syncInFlight = false
/** Prefer PGP key id from chat bootstrap when registering. */
let boundPgpKeyId = ''

/** In-flight / retry guard for home ensure. */
let homeEnsureEoa = ''
let homeEnsureTimer: ReturnType<typeof setTimeout> | undefined
let homeEnsureAttempt = 0
const HOME_ENSURE_MAX_ATTEMPTS = 8
const HOME_ENSURE_RETRY_MS = [0, 2000, 4000, 8000, 12000, 20000, 30000, 45000]

function detectCashTreesHost(): CashTreesHost {
	const w = window as Window & {
		CashTreesIOS?: { getNfcStatus?: () => string; bindPushIdentity?: (p: unknown) => void }
		CashTreesAndroid?: { getNfcStatus?: () => string; bindPushIdentity?: (s: string) => void }
	}
	if (typeof w.CashTreesIOS?.getNfcStatus === 'function') return 'ios'
	if (typeof w.CashTreesAndroid?.getNfcStatus === 'function') return 'android'
	return null
}

function isPosNativeShell(): boolean {
	return detectCashTreesHost() !== null
}

function buildRegisterMessage(params: {
	eoa: string
	deviceToken: string
	platform: string
	bundleId: string
	timestamp: number
}): string {
	return [
		'Beamio registerPushDevice',
		`eoa:${params.eoa.toLowerCase()}`,
		`deviceToken:${params.deviceToken}`,
		`platform:${params.platform}`,
		`bundleId:${params.bundleId}`,
		`timestamp:${params.timestamp}`,
	].join('\n')
}

function buildSyncBadgeMessage(params: { eoa: string; unread: number; timestamp: number }): string {
	return [
		'Beamio syncChatBadge',
		`eoa:${params.eoa.toLowerCase()}`,
		`unread:${params.unread}`,
		`timestamp:${params.timestamp}`,
	].join('\n')
}

function buildPushDeviceStatusMessage(params: { eoa: string; timestamp: number }): string {
	return [
		'Beamio pushDeviceStatus',
		`eoa:${params.eoa.toLowerCase()}`,
		`timestamp:${params.timestamp}`,
	].join('\n')
}

async function signMessage(message: string): Promise<{ eoa: string; signature: string } | null> {
	const pk = getSessionPrivateKeyHex()
	if (!pk) return null
	const hex = pk.startsWith('0x') ? pk : `0x${pk}`
	const wallet = new ethers.Wallet(hex)
	const signature = await wallet.signMessage(message)
	return { eoa: wallet.address, signature }
}

function normalizePlatform(raw: string | undefined, hostHint: CashTreesHost): PushPlatform | null {
	const p = (raw || hostHint || '').toLowerCase()
	if (p === 'ios' || p === 'android') return p
	return null
}

function isValidDeviceToken(platform: PushPlatform, token: string): boolean {
	if (platform === 'ios') return /^[0-9a-f]{64}$/i.test(token)
	if (token.length < 80 || token.length > 4096) return false
	return /^[A-Za-z0-9_.:\-]+$/.test(token)
}

function defaultBundleId(platform: PushPlatform, fromNative?: string): string {
	const t = (fromNative || '').trim()
	if (t) return t
	return platform === 'android' ? ANDROID_BUNDLE_ID : IOS_BUNDLE_ID
}

async function registerDeviceToken(
	deviceToken: string,
	opts?: { pgpKeyId?: string; platform?: PushPlatform; bundleId?: string; force?: boolean },
): Promise<boolean> {
	const host = detectCashTreesHost()
	const platform = opts?.platform || (host === 'android' ? 'android' : host === 'ios' ? 'ios' : null)
	if (!platform) return false

	const token = platform === 'ios' ? deviceToken.trim().toLowerCase() : deviceToken.trim()
	if (!isValidDeviceToken(platform, token)) return false
	if (!opts?.force && token === lastRegisteredToken) return true

	const sessionEoa = getSessionWalletAddress()
	if (!sessionEoa || !ethers.isAddress(sessionEoa)) return false

	const bundleId = defaultBundleId(platform, opts?.bundleId)
	const timestamp = Math.floor(Date.now() / 1000)
	const message = buildRegisterMessage({
		eoa: ethers.getAddress(sessionEoa),
		deviceToken: token,
		platform,
		bundleId,
		timestamp,
	})
	const signed = await signMessage(message)
	if (!signed) return false

	const pgpKeyId = (opts?.pgpKeyId || boundPgpKeyId || '').trim() || undefined

	try {
		const res = await fetch(`${BEAMIO_API}/api/registerPushDevice`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				eoa: signed.eoa,
				deviceToken: token,
				platform,
				bundleId,
				pgpKeyId,
				timestamp,
				signature: signed.signature,
			}),
		})
		if (!res.ok) {
			console.warn('[pos-push] registerPushDevice HTTP', res.status)
			return false
		}
		const json = (await res.json().catch(() => null)) as { success?: boolean } | null
		if (json?.success) {
			lastRegisteredToken = token
			console.info('[pos-push] registerPushDevice ok', bundleId)
			return true
		}
		return false
	} catch (e) {
		console.warn('[pos-push] registerPushDevice failed', e)
		return false
	}
}

function onNativePushEvent(ev: Event): void {
	const detail = (ev as CustomEvent<PushTokenDetail>).detail
	if (!detail || detail.action !== 'pushDeviceToken') return
	const token = String(detail.deviceToken || '').trim()
	if (!token) return
	const platform = normalizePlatform(detail.platform, detectCashTreesHost())
	if (!platform) return
	void registerDeviceToken(token, {
		pgpKeyId: detail.pgpKeyId || boundPgpKeyId,
		platform,
		bundleId: detail.bundleId,
	})
}

/** Attach once; listens for both iOS and Android CustomEvents. */
export function ensurePushDeviceTokenListener(): void {
	if (typeof window === 'undefined' || listenerAttached) return
	listenerAttached = true
	window.addEventListener('cashtreesios', onNativePushEvent as EventListener)
	window.addEventListener('cashtreesandroid', onNativePushEvent as EventListener)
}

/**
 * Ask native to bind terminal EOA and register for APNs/FCM.
 * Call as soon as the wallet session is on home (parity with Consumer) — do not wait for chat gossip.
 */
export function bindNativePushIdentity(opts?: { eoa?: string; pgpKeyId?: string }): boolean {
	if (typeof window === 'undefined') return false
	if (!isPosNativeShell()) return false
	ensurePushDeviceTokenListener()

	const eoa = (opts?.eoa || getSessionWalletAddress() || '').trim()
	if (!eoa || !ethers.isAddress(eoa)) return false

	const pgpKeyId = (opts?.pgpKeyId || boundPgpKeyId || '').trim()
	if (pgpKeyId) boundPgpKeyId = pgpKeyId
	const host = detectCashTreesHost()

	if (host === 'ios') {
		const ios = window.CashTreesIOS as
			| { bindPushIdentity?: (p: { eoa: string; pgpKeyId?: string }) => void }
			| undefined
		if (typeof ios?.bindPushIdentity !== 'function') return false
		try {
			ios.bindPushIdentity({ eoa, pgpKeyId: pgpKeyId || undefined })
			return true
		} catch {
			return false
		}
	}

	if (host === 'android') {
		const android = window.CashTreesAndroid as
			| { bindPushIdentity?: (json: string) => void }
			| undefined
		if (typeof android?.bindPushIdentity !== 'function') return false
		try {
			android.bindPushIdentity(JSON.stringify({ eoa, pgpKeyId: pgpKeyId || undefined }))
			return true
		} catch {
			return false
		}
	}

	return false
}

export function ensureNativePushBoundForWallet(opts?: { eoa?: string; pgpKeyId?: string }): boolean {
	const eoa = (opts?.eoa || getSessionWalletAddress() || '').trim()
	if (!eoa || !ethers.isAddress(eoa)) return false
	if (opts?.pgpKeyId) boundPgpKeyId = String(opts.pgpKeyId).trim()
	return bindNativePushIdentity({
		eoa,
		pgpKeyId: boundPgpKeyId || undefined,
	})
}

/** Signed Cluster read: whether this EOA has a POS push device row. */
export async function fetchPosPushDeviceRegistered(eoaRaw?: string): Promise<boolean | null> {
	if (typeof window === 'undefined') return null
	if (!isPosNativeShell()) return null
	const eoa = (eoaRaw || getSessionWalletAddress() || '').trim()
	if (!eoa || !ethers.isAddress(eoa)) return null

	const timestamp = Math.floor(Date.now() / 1000)
	const message = buildPushDeviceStatusMessage({
		eoa: ethers.getAddress(eoa),
		timestamp,
	})
	const signed = await signMessage(message)
	if (!signed) return null

	try {
		const res = await fetch(`${BEAMIO_API}/api/pushDeviceStatus`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				eoa: signed.eoa,
				scope: 'pos',
				timestamp,
				signature: signed.signature,
			}),
		})
		if (!res.ok) return null
		const json = (await res.json().catch(() => null)) as {
			success?: boolean
			registered?: boolean
		} | null
		if (!json?.success) return null
		return Boolean(json.registered)
	} catch {
		return null
	}
}

function clearHomeEnsureTimer(): void {
	if (homeEnsureTimer !== undefined) {
		clearTimeout(homeEnsureTimer)
		homeEnsureTimer = undefined
	}
}

/**
 * Stop home ensure retries (e.g. leave home / wallet switch).
 */
export function stopEnsurePosPushDeviceRegistered(): void {
	homeEnsureEoa = ''
	homeEnsureAttempt = 0
	clearHomeEnsureTimer()
}

/**
 * On /home: check API for POS push registration; if missing, bind native + retry until registered.
 * Uses setTimeout chain (no setInterval).
 */
export function ensurePosPushDeviceRegisteredOnHome(opts?: { eoa?: string; pgpKeyId?: string }): void {
	if (typeof window === 'undefined') return
	if (!isPosNativeShell()) return

	const eoa = (opts?.eoa || getSessionWalletAddress() || '').trim()
	if (!eoa || !ethers.isAddress(eoa)) return
	if (opts?.pgpKeyId) boundPgpKeyId = String(opts.pgpKeyId).trim()

	const eoaLower = eoa.toLowerCase()
	// Fresh ensure each call (home mount or gossip pgp ready) — reset retry budget.
	homeEnsureEoa = eoaLower
	homeEnsureAttempt = 0
	clearHomeEnsureTimer()

	ensurePushDeviceTokenListener()
	ensureNativePushBoundForWallet({ eoa, pgpKeyId: boundPgpKeyId || undefined })

	const schedule = (delayMs: number) => {
		clearHomeEnsureTimer()
		homeEnsureTimer = setTimeout(() => {
			void (async () => {
				if (homeEnsureEoa !== eoaLower) return
				const registered = await fetchPosPushDeviceRegistered(eoa)
				if (registered === true) {
					console.info('[pos-push] already registered on API')
					homeEnsureAttempt = HOME_ENSURE_MAX_ATTEMPTS
					clearHomeEnsureTimer()
					return
				}
				// null = untrusted fetch — keep last attempt path (re-bind), do not treat as "not registered forever"
				if (registered === false) {
					lastRegisteredToken = ''
					console.info('[pos-push] not registered — re-bind for registerPushDevice')
				}
				ensureNativePushBoundForWallet({ eoa, pgpKeyId: boundPgpKeyId || undefined })
				homeEnsureAttempt += 1
				if (homeEnsureAttempt >= HOME_ENSURE_MAX_ATTEMPTS) {
					console.warn('[pos-push] ensure stopped after max attempts (still unregistered or status untrusted)')
					return
				}
				const nextDelay =
					HOME_ENSURE_RETRY_MS[Math.min(homeEnsureAttempt, HOME_ENSURE_RETRY_MS.length - 1)] ?? 30000
				schedule(nextDelay)
			})()
		}, delayMs)
	}

	schedule(HOME_ENSURE_RETRY_MS[0] ?? 0)
}

/**
 * Persist unread on API for offline SI notify increments.
 * Live icon badge still goes through posNativeAppStateBridge.
 */
export async function syncChatBadgeToApi(unreadRaw: number): Promise<void> {
	if (typeof window === 'undefined') return
	if (!isPosNativeShell()) return
	const unread = Math.max(0, Math.min(999, Math.floor(Number(unreadRaw) || 0)))
	if (unread === lastSyncedUnread) return
	if (syncInFlight) return
	const sessionEoa = getSessionWalletAddress()
	if (!sessionEoa || !ethers.isAddress(sessionEoa)) return

	syncInFlight = true
	try {
		const timestamp = Math.floor(Date.now() / 1000)
		const message = buildSyncBadgeMessage({
			eoa: ethers.getAddress(sessionEoa),
			unread,
			timestamp,
		})
		const signed = await signMessage(message)
		if (!signed) return
		const res = await fetch(`${BEAMIO_API}/api/syncChatBadge`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				eoa: signed.eoa,
				unread,
				timestamp,
				signature: signed.signature,
			}),
		})
		if (res.ok) lastSyncedUnread = unread
	} catch {
		/* retry next tick */
	} finally {
		syncInFlight = false
	}
}
