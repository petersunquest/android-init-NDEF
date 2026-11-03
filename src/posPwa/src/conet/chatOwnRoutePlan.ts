/**
 * Own Chat mailbox: when to register AddressPGP again, and on which mailbox.
 *
 * One failed chain read used to re-register the account on a random node
 * (2026-11-02: a test account moved from its mailbox to a random old node after an
 * unlock), and the messages waiting in the old mailbox were lost. Rules:
 *
 * - A failed or timed-out chain read never registers. Keep the current mailbox
 *   and retry later.
 * - Register only after a successful read shows: no record, another user key,
 *   no route, or no private-key blob at all.
 * - Register on the mailbox the account already has (chain route, else the
 *   local one). A random mailbox is only for an account that never had one.
 * - A private-key blob that failed to load or to decrypt is never a reason by
 *   itself.
 *
 * Pure code, no imports. The same file is copied into SilentPassUI,
 * bizSiteMerchant and posPwa; keep the copies identical.
 */

export type OwnPrivateBlob = 'ok' | 'missing' | 'error' | 'undecryptable'

export type OwnChainRead =
	| { status: 'error'; reason: string }
	| { status: 'empty' }
	| {
		status: 'ok'
		userKeyID: string
		routeKeyID: string
		routeArmor: string
		privateBlob: OwnPrivateBlob
	}

export type OwnMailbox = { routeKeyID: string; routeArmor: string }

export type OwnRoutePlan =
	/** Chain record is fine: listen on the chain mailbox, do not register. */
	| { action: 'use-chain'; mailbox: OwnMailbox; reason: string }
	/** Chain read failed: listen on the mailbox we already use, do not register, check again later. */
	| { action: 'keep-current'; routeArmor: string; reason: string }
	/** Chain read failed and no mailbox is known: do not register, retry later. */
	| { action: 'wait-retry'; reason: string }
	/** Register the local key on `target` ('random' only for an account that never had a mailbox). */
	| { action: 'register'; target: OwnMailbox | 'random'; reason: string }

const normArmor = (s: string | undefined | null): string => String(s || '').replace(/\r/g, '').trim()
const normKeyID = (s: string | undefined | null): string => String(s || '').trim().toUpperCase()

export function planOwnChatRoute(input: {
	read: OwnChainRead
	/** Key ID of the local user PGP public key ('' if it could not be read). */
	localKeyID: string
	/** Mailbox we listen on now, with its route key ID, if known. */
	current: OwnMailbox | null
	/** Route armor we listen on now (may be known without its key ID). */
	currentArmor: string
}): OwnRoutePlan {
	const { read } = input
	const localKeyID = normKeyID(input.localKeyID)
	const currentArmor = normArmor(input.currentArmor) || normArmor(input.current?.routeArmor)
	const current = input.current && normKeyID(input.current.routeKeyID) && normArmor(input.current.routeArmor)
		? { routeKeyID: input.current.routeKeyID.trim(), routeArmor: normArmor(input.current.routeArmor) }
		: null

	if (read.status === 'error') {
		return currentArmor
			? { action: 'keep-current', routeArmor: currentArmor, reason: `chain read failed (${read.reason}); keeping current mailbox` }
			: { action: 'wait-retry', reason: `chain read failed (${read.reason}); no known mailbox` }
	}

	if (read.status === 'empty') {
		return current
			? { action: 'register', target: current, reason: 'no chain record; registering on current mailbox' }
			: { action: 'register', target: 'random', reason: 'no chain record and no mailbox yet (new account)' }
	}

	const chainMailbox = normKeyID(read.routeKeyID) && normArmor(read.routeArmor)
		? { routeKeyID: read.routeKeyID.trim(), routeArmor: normArmor(read.routeArmor) }
		: null

	if (!localKeyID) {
		// Cannot compare keys: never overwrite the chain record on that basis.
		if (chainMailbox) return { action: 'use-chain', mailbox: chainMailbox, reason: 'local key ID unreadable; using chain mailbox' }
		return currentArmor
			? { action: 'keep-current', routeArmor: currentArmor, reason: 'local key ID unreadable; keeping current mailbox' }
			: { action: 'wait-retry', reason: 'local key ID unreadable; no known mailbox' }
	}

	if (normKeyID(read.userKeyID) !== localKeyID) {
		const target = chainMailbox ?? current
		return target
			? { action: 'register', target, reason: 'chain user key differs from local key; registering on current mailbox' }
			: { action: 'register', target: 'random', reason: 'chain user key differs and no mailbox yet' }
	}

	if (!chainMailbox) {
		return current
			? { action: 'register', target: current, reason: 'chain record has no route; registering on current mailbox' }
			: { action: 'register', target: 'random', reason: 'chain record has no route and no mailbox yet' }
	}

	if (read.privateBlob === 'missing') {
		return { action: 'register', target: chainMailbox, reason: 'chain record has no private key blob; registering on chain mailbox' }
	}

	return {
		action: 'use-chain',
		mailbox: chainMailbox,
		reason: read.privateBlob === 'ok' ? 'chain record matches' : `chain record matches (private blob ${read.privateBlob}; not a reason to register)`,
	}
}

/**
 * The mailbox we use now: the local router armor (or the last chain read when
 * there is none), with its route key ID from the node list or that cache.
 */
export function resolveCurrentMailbox(
	routerArmor: string,
	nodes: ReadonlyArray<{ domain?: string; armoredPublicKey?: string }>,
	cached: OwnMailbox | null,
): { armor: string; mailbox: OwnMailbox | null } {
	const armor = normArmor(routerArmor) || normArmor(cached?.routeArmor)
	if (!armor) return { armor: '', mailbox: null }
	const node = nodes.find((n) => normArmor(n.armoredPublicKey) === armor && String(n.domain || '').trim())
	if (node) return { armor, mailbox: { routeKeyID: String(node.domain).trim(), routeArmor: armor } }
	if (cached && normKeyID(cached.routeKeyID) && normArmor(cached.routeArmor) === armor) {
		return { armor, mailbox: { routeKeyID: cached.routeKeyID.trim(), routeArmor: armor } }
	}
	return { armor, mailbox: null }
}

export type OwnChainRecord = { userKeyID: string; routeKeyID: string; routeArmor: string; publicArmored: string }

/**
 * Read our own AddressPGP record, telling a failed read apart from an empty one.
 * - `first`: a read already done (null means "failed or empty", unknown which).
 * - `searchKey`: resolves null when the chain has no record; throws on RPC error.
 * - `probeBlob`: our encrypted private key, only asked for when `first` had none.
 * A read that throws or takes longer than `timeoutMs` is an error, never "empty".
 */
export async function readOwnChainState(deps: {
	first: (OwnChainRecord & { privateArmored?: string }) | null
	searchKey: () => Promise<OwnChainRecord | null>
	probeBlob: () => Promise<{ state: OwnPrivateBlob; armored: string }>
	timeoutMs?: number
}): Promise<{ read: OwnChainRead; publicArmored: string; privateArmored: string }> {
	const timeoutMs = deps.timeoutMs ?? 8_000
	const withTimeout = <T,>(p: Promise<T>, what: string): Promise<T> => {
		let timer: ReturnType<typeof setTimeout> | undefined
		return Promise.race([
			p,
			new Promise<never>((_, reject) => {
				timer = setTimeout(() => reject(new Error(`${what} timeout`)), timeoutMs)
			}),
		]).finally(() => clearTimeout(timer))
	}
	let rec: OwnChainRecord | null = deps.first
	if (!rec) {
		try {
			rec = await withTimeout(deps.searchKey(), 'searchKey')
		} catch (ex) {
			const reason = String((ex as Error)?.message || ex).replace(/0x[0-9a-fA-F]{16,}/g, '0x…').slice(0, 120)
			return { read: { status: 'error', reason }, publicArmored: '', privateArmored: '' }
		}
		if (!rec || (!rec.publicArmored && !rec.routeArmor)) {
			return { read: { status: 'empty' }, publicArmored: '', privateArmored: '' }
		}
	}
	let privateArmored = String(deps.first?.privateArmored || '').trim() ? String(deps.first?.privateArmored) : ''
	let privateBlob: OwnPrivateBlob = 'ok'
	if (!privateArmored) {
		try {
			const blob = await withTimeout(deps.probeBlob(), 'getEncryptedPrivateKey')
			privateBlob = blob.state
			privateArmored = blob.state === 'ok' ? blob.armored : ''
		} catch {
			privateBlob = 'error'
		}
	}
	return {
		read: { status: 'ok', userKeyID: rec.userKeyID, routeKeyID: rec.routeKeyID, routeArmor: rec.routeArmor, privateBlob },
		publicArmored: rec.publicArmored,
		privateArmored,
	}
}

/** Waits between chain reads while they fail (ms); the last one repeats. */
export const OWN_ROUTE_RECHECK_DELAYS_MS: readonly number[] = [5_000, 15_000, 30_000, 60_000, 120_000, 300_000]

export type OwnRegisterBackoff = {
	/** Registrations in a row that did not end on a confirmed chain record. */
	failures: () => number
	/** How long to wait before the next registration (0: go ahead). */
	remainingMs: (now: number) => number
	/** Count a failed or unconfirmed registration; returns the wait it starts. */
	fail: (now: number) => number
	/** A working chain read confirmed the mailbox. */
	reset: () => void
}

/**
 * Waits between own-mailbox registrations that fail, same steps as a failed
 * chain read. 2026-11-02 RC3c R7: with no chain record and the API refusing,
 * initChat registered, the listen recheck read "no record" and started chat
 * again at once: 26 registrations in 25 s, down to 0.65 s apart.
 */
export function createOwnRegisterBackoff(delaysMs: readonly number[] = OWN_ROUTE_RECHECK_DELAYS_MS): OwnRegisterBackoff {
	let failures = 0
	let nextAt = 0
	return {
		failures: () => failures,
		remainingMs: (now) => (failures === 0 ? 0 : Math.max(0, nextAt - now)),
		fail: (now) => {
			const wait = delaysMs[Math.min(failures, delaysMs.length - 1)]
			failures += 1
			nextAt = now + wait
			return wait
		},
		reset: () => {
			failures = 0
			nextAt = 0
		},
	}
}

/** Waits before each chain read that checks a registration the API accepted (ms). */
export const REGISTER_VERIFY_DELAYS_MS: readonly number[] = [1_500, 3_000, 6_000]

/**
 * After the API accepted a registration: read the chain until the record shows
 * our user key and the registered mailbox. 2026-11-02 RC3d R15: one read 1.5 s
 * after the API reply often still saw the old record, so a good registration
 * was logged as failed and counted in the backoff. `read` returns null for a
 * failed read or a record that does not match yet. Returns the first match,
 * or null after the last read (or once `sleep` reports the session ended).
 */
export async function verifyRegistration<T>(deps: {
	read: () => Promise<T | null>
	sleep: (ms: number) => Promise<boolean>
	delaysMs?: readonly number[]
}): Promise<{ record: T | null; reads: number }> {
	const delays = deps.delaysMs ?? REGISTER_VERIFY_DELAYS_MS
	let reads = 0
	for (const wait of delays) {
		if (!(await deps.sleep(wait))) break
		reads += 1
		const record = await deps.read().catch(() => null)
		if (record) return { record, reads }
	}
	return { record: null, reads }
}

/**
 * After a listen started on a mailbox no working chain read confirmed
 * (`keep-current`, or a registration that could not be verified): read the
 * chain until one read works, waiting after each failure (never moving the
 * listen meanwhile). Then:
 * - 'match': the chain record is fine and names the mailbox we listen on;
 * - 'reinit': anything else; start chat again, and with a working read
 *   planOwnChatRoute moves the listen to the chain mailbox (or registers);
 * - 'gone': `sleep` reported the session ended.
 */
export async function recheckListenRoute(deps: {
	listenArmor: () => string
	read: () => Promise<OwnChainRead>
	localKeyID: string
	/** Resolves false when the session ended (stop checking). */
	sleep: (ms: number) => Promise<boolean>
	delaysMs?: readonly number[]
	onRetry?: (reason: string, waitMs: number) => void
}): Promise<{ result: 'match' | 'reinit' | 'gone'; read?: OwnChainRead }> {
	const delays = deps.delaysMs?.length ? deps.delaysMs : OWN_ROUTE_RECHECK_DELAYS_MS
	for (let attempt = 0; ; attempt++) {
		let read: OwnChainRead
		try {
			read = await deps.read()
		} catch (ex) {
			read = { status: 'error', reason: String((ex as Error)?.message || ex).slice(0, 120) }
		}
		if (read.status !== 'error') {
			const listen = normArmor(deps.listenArmor())
			const plan = planOwnChatRoute({ read, localKeyID: deps.localKeyID, current: null, currentArmor: listen })
			const match = plan.action === 'use-chain' && !!listen && normArmor(plan.mailbox.routeArmor) === listen
			return { result: match ? 'match' : 'reinit', read }
		}
		const waitMs = delays[Math.min(attempt, delays.length - 1)]
		deps.onRetry?.(read.reason, waitMs)
		if (!(await deps.sleep(waitMs))) return { result: 'gone', read }
	}
}

export type RecordedMailboxPick<T> =
	| { status: 'ok'; node: T; skipped: string[] }
	/** Every candidate checked was not recorded. */
	| { status: 'none'; skipped: string[] }
	/** A check failed (RPC error or timeout): pick nothing, retry later. */
	| { status: 'error'; reason: string; skipped: string[] }

/**
 * A new mailbox for an account that never had one: only a node AddressPGP has
 * recorded (`nodeKeyExists`). On an unrecorded node SI answers `not_my_route`
 * to presence, ACK and push registration for every account on it (2026-11-02:
 * #570 and #355 were never recorded). `candidates` come in random order. A
 * failed check picks nothing, like a failed chain read: the caller retries
 * later instead of using an unchecked node.
 */
export async function pickRecordedMailbox<T>(deps: {
	candidates: readonly T[]
	routeKeyID: (node: T) => string
	/** Resolves AddressPGP `nodeKeyExists(keccak256(routeKeyID))`; throws on RPC error. */
	isRecorded: (routeKeyID: string) => Promise<boolean>
	maxChecks?: number
	timeoutMs?: number
}): Promise<RecordedMailboxPick<T>> {
	const maxChecks = deps.maxChecks ?? 8
	const timeoutMs = deps.timeoutMs ?? 8_000
	const skipped: string[] = []
	const seen = new Set<string>()
	for (const node of deps.candidates) {
		if (seen.size >= maxChecks) break
		const id = String(deps.routeKeyID(node) || '').trim()
		if (!id || seen.has(id.toUpperCase())) continue
		seen.add(id.toUpperCase())
		let recorded: boolean
		let timer: ReturnType<typeof setTimeout> | undefined
		try {
			recorded = await Promise.race([
				deps.isRecorded(id),
				new Promise<never>((_, reject) => {
					timer = setTimeout(() => reject(new Error('nodeKeyExists timeout')), timeoutMs)
				}),
			])
		} catch (ex) {
			return { status: 'error', reason: String((ex as Error)?.message || ex).slice(0, 120), skipped }
		} finally {
			clearTimeout(timer)
		}
		if (recorded) return { status: 'ok', node, skipped }
		skipped.push(id)
	}
	return { status: 'none', skipped }
}
