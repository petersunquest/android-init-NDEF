/**
 * L0 / CoNET-SI envelope helpers (docs: `src/docs/gitbook/l0/si-developer-guide.md`).
 *
 * - Business armor: encrypt to recipient **user PGP**.
 * - SI command: `{ message, signMessage }` encrypt to **route PGP**.
 * - Mailbox work: `{ data: <user-PGP armor>, NoPush?: true }` encrypt to **mailbox B route PGP**.
 * - Optional outer wrap: encrypt already-built inner armor to **this entry's**
 *   route public key so the first `/post` observer sees the entry key ID.
 * - HTTP `POST /post` is **only** `{ data: armor }`. Never add sibling fields.
 * - Clients **must not** set `X-CoNET-Hop-Sigs` (SI appends that only on SI→SI).
 */

import {
	createMessage,
	encrypt,
	enums,
	readKey,
	readMessage,
} from 'openpgp'
import type { Wallet } from 'ethers'

import { utf8ToBase64 } from './crypto'
import { hasEntryPgpKey, normalizeArmoredKey } from './nodes'

export function armorToString(armored: unknown): string {
	if (typeof armored === 'string') return armored
	if (armored && typeof armored === 'object' && 'data' in (armored as object)) {
		const data = (armored as { data?: unknown }).data
		if (typeof data === 'string') return data
	}
	return String(armored ?? '')
}

/** JSON body for `POST /post`. Wire is only `{ data }`. Never add sibling fields. */
export function buildPostBody(armored: string): { data: string } {
	return { data: armored }
}

export type MailboxWorkEnvelope = {
	data: string
	NoPush?: boolean
}

/**
 * Wrap user-PGP (or other) armor as a mailbox work packet encrypted to **B route PGP**.
 * SI on B decrypts this, reads `NoPush`, then stores/forwards the inner `data` armor.
 */
export async function wrapArmorToMailboxWork(
	innerArmor: string,
	mailboxRoutePublicKeyArmored: string,
	work?: { NoPush?: boolean },
): Promise<string> {
	const mailboxKey = normalizeArmoredKey(mailboxRoutePublicKeyArmored)
	if (!mailboxKey || !innerArmor.includes('BEGIN PGP')) {
		throw new Error('wrapArmorToMailboxWork: missing mailbox route key or inner armor')
	}
	const payload: MailboxWorkEnvelope = { data: innerArmor }
	if (work?.NoPush) payload.NoPush = true
	const encryptionKeys = await readKey({ armoredKey: mailboxRoutePublicKeyArmored })
	const pgpMsg = await createMessage({ text: JSON.stringify(payload) })
	return armorToString(
		await encrypt({
			message: pgpMsg,
			encryptionKeys,
			config: { preferredCompressionAlgorithm: enums.compression.zlib },
		}),
	)
}

async function entryKeyIds(entryRoutePublicKeyArmored: string): Promise<Set<string>> {
	const key = await readKey({ armoredKey: entryRoutePublicKeyArmored })
	return new Set(key.getKeyIDs().map((id) => id.toHex().toUpperCase()))
}

/**
 * True when wrapping `innerArmor` to this entry would make the inner key ID
 * equal the entry (SI treats that as a same-node peel attack and emits `end`).
 */
export async function wrapWouldHitSameNode(
	innerArmor: string,
	entryRoutePublicKeyArmored: string,
): Promise<boolean> {
	if (!normalizeArmoredKey(entryRoutePublicKeyArmored) || !innerArmor.includes('BEGIN PGP')) {
		return true
	}
	try {
		const innerMsg = await readMessage({ armoredMessage: innerArmor })
		const innerIds = innerMsg.getEncryptionKeyIDs().map((id) => id.toHex().toUpperCase())
		if (!innerIds.length) return true
		const entryIds = await entryKeyIds(entryRoutePublicKeyArmored)
		return innerIds.some((id) => entryIds.has(id))
	} catch {
		return true
	}
}

/** Why the outer entry wrap was refused. The inner armor is never sent instead (§50). */
export type EntryWrapFailure = 'no_entry_key' | 'not_pgp' | 'unsafe_route' | 'encrypt_failed'

export class EntryWrapError extends Error {
	readonly reason: EntryWrapFailure

	constructor(reason: EntryWrapFailure, cause?: unknown) {
		super(`wrapArmorToEntryRoute: ${reason}`)
		this.name = 'EntryWrapError'
		this.reason = reason
		if (cause !== undefined) (this as { cause?: unknown }).cause = cause
	}
}

/**
 * Encrypt already-built inner OpenPGP armor to an entry route public key.
 * Literal plaintext is the **raw inner armor** (SI `tryReadInnerPgpMessage`).
 * Throws `EntryWrapError` when the entry has no PGP key, the input is not armor,
 * the wrap would hit the same node, or encryption fails. Callers skip that entry;
 * they never fall back to posting the inner armor unwrapped.
 */
export async function wrapArmorToEntryRoute(
	innerArmor: string,
	entryRoutePublicKeyArmored: string,
): Promise<string> {
	if (!hasEntryPgpKey({ armoredPublicKey: entryRoutePublicKeyArmored })) throw new EntryWrapError('no_entry_key')
	if (!innerArmor.includes('BEGIN PGP')) throw new EntryWrapError('not_pgp')
	if (await wrapWouldHitSameNode(innerArmor, entryRoutePublicKeyArmored)) throw new EntryWrapError('unsafe_route')
	try {
		const encryptionKeys = await readKey({ armoredKey: entryRoutePublicKeyArmored })
		const pgpMsg = await createMessage({ text: innerArmor })
		return armorToString(
			await encrypt({
				message: pgpMsg,
				encryptionKeys,
				config: { preferredCompressionAlgorithm: enums.compression.zlib },
			}),
		)
	} catch (ex) {
		throw new EntryWrapError('encrypt_failed', ex)
	}
}

/** Signed SI command → OpenPGP armor encrypted to a **route** public key. */
export async function encryptRouteCommand(
	wallet: Wallet,
	command: Record<string, unknown>,
	routePublicKeyArmored: string,
): Promise<string> {
	const message = JSON.stringify(command)
	const signMessage = await wallet.signMessage(message)
	const pgpMsg = await createMessage({
		text: utf8ToBase64(JSON.stringify({ message, signMessage })),
	})
	const encryptionKeys = await readKey({ armoredKey: routePublicKeyArmored })
	return armorToString(
		await encrypt({
			message: pgpMsg,
			encryptionKeys,
			config: { preferredCompressionAlgorithm: enums.compression.zlib },
		}),
	)
}
