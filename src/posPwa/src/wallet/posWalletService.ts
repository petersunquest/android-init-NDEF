import { Interface, Wallet, type HDNodeWallet } from 'ethers'
import { addUser, mapAddUserRegistrationError, probeBeamioTagRegistration } from '@/api/beamioApi'
import { ACCOUNT_REGISTRY, CONET_RPC } from '@/constants'
import { fromBase64Utf8 } from '@/conet/crypto'
import {
	aesGcmDecryptWithStored,
	buildRecoverEntriesForNewUser,
	decodeRecoverStoragePayload,
	type RecoverStoragePayload,
} from '@/wallet/recoverCrypto'
import {
	loadPosWalletInitFromIndexedDb,
	savePosWalletInitToIndexedDb,
	type PosWalletInitRecord,
} from '@/wallet/posWalletStorage'

const IDB_SAVE_MAX_ATTEMPTS = 3

async function persistPosWalletInit(record: PosWalletInitRecord): Promise<void> {
	let lastError: unknown
	for (let attempt = 0; attempt < IDB_SAVE_MAX_ATTEMPTS; attempt++) {
		try {
			await savePosWalletInitToIndexedDb(record)
			return
		} catch (err) {
			lastError = err
			if (attempt + 1 < IDB_SAVE_MAX_ATTEMPTS) {
				await new Promise((r) => setTimeout(r, 120 * (attempt + 1)))
			}
		}
	}
	throw lastError instanceof Error ? lastError : new Error('Could not save wallet locally.')
}

function walletSaveFailedMessage(registeredOnChain: boolean): string {
	if (registeredOnChain) {
		return (
			'Your terminal was registered on CoNET, but this device could not save the wallet locally. ' +
			'Allow site storage (turn off Private Browsing if enabled), then tap Restore existing terminal ' +
			'with the same @BeamioTag and access password.'
		)
	}
	return (
		'Could not save wallet on this device. Allow site storage (turn off Private Browsing if enabled) and try again.'
	)
}
import {
	clearSessionWallet,
	getSessionPrivateKeyHex,
	getSessionWalletAddress,
	hasSessionWallet,
	setSessionWallet,
} from '@/wallet/posWalletSession'

const registryIface = new Interface([
	'function getBase64ByAccountName(string accountName) view returns (string)',
])

export type CreatePosWalletResult =
	| { ok: true; address: string; recoveryCode: string }
	| { ok: false; error: string }

export type RestorePosWalletResult =
	| { ok: true; address: string }
	| { ok: false; error: string }

function walletFromMnemonic(mnemonicPhrase: string): HDNodeWallet | null {
	try {
		return Wallet.fromPhrase(mnemonicPhrase.trim())
	} catch {
		return null
	}
}

function hydrateSessionFromMnemonic(mnemonicPhrase: string): HDNodeWallet | null {
	const w = walletFromMnemonic(mnemonicPhrase)
	if (!w) return null
	const pk = w.privateKey.startsWith('0x') ? w.privateKey.slice(2) : w.privateKey
	setSessionWallet(pk, w.address)
	return w
}

/** SilentPassUI `createOrGetWallet('', true)` + `storeSystemData` parity for POS web. */
export async function createPosWalletWithIndexedDb(params: {
	accountName: string
	password: string
	parentBeamioTag: string
}): Promise<CreatePosWalletResult> {
	const accountName = params.accountName.trim()
	if (!accountName) return { ok: false, error: 'Account name is required.' }

	const w = Wallet.createRandom()
	const mnemonicPhrase = w.mnemonic?.phrase?.trim()
	if (!mnemonicPhrase) return { ok: false, error: 'Could not generate wallet mnemonic.' }

	const pk = w.privateKey.startsWith('0x') ? w.privateKey.slice(2) : w.privateKey
	setSessionWallet(pk, w.address)

	let recoverEntries
	try {
		recoverEntries = await buildRecoverEntriesForNewUser(accountName, params.password, mnemonicPhrase)
	} catch {
		clearSessionWallet()
		return { ok: false, error: 'Could not build recovery payload.' }
	}

	const signMessage = await w.signMessage(w.address)

	const registrationProbe = await probeBeamioTagRegistration(accountName, w.address)
	if (!registrationProbe.ok) {
		clearSessionWallet()
		if (registrationProbe.reason === 'taken') {
			return {
				ok: false,
				error: mapAddUserRegistrationError('Wallet & accountName ownership Error!'),
			}
		}
		if (registrationProbe.reason === 'network') {
			return { ok: false, error: 'Network error. Check connection and try again.' }
		}
		return { ok: false, error: 'Invalid terminal @BeamioTag.' }
	}

	const reg = await addUser({
		accountName,
		wallet: w.address,
		signMessage,
		recover: recoverEntries.recover,
	})
	if (!reg.ok) {
		clearSessionWallet()
		return { ok: false, error: reg.error ?? 'Registration failed' }
	}

	const record: PosWalletInitRecord = {
		ver: 1,
		isReady: true,
		mnemonicPhrase,
		profiles: [
			{
				keyID: w.address,
				accountName,
				type: 'ethereum',
				isPrimary: true,
			},
		],
		parentBeamioTag: params.parentBeamioTag.trim() || undefined,
	}
	try {
		await persistPosWalletInit(record)
	} catch {
		clearSessionWallet()
		return { ok: false, error: walletSaveFailedMessage(true) }
	}

	return { ok: true, address: w.address, recoveryCode: recoverEntries.recoveryCode }
}

async function fetchRecoverPayloadByAccountName(
	accountName: string,
): Promise<RecoverStoragePayload | null> {
	try {
		const data = registryIface.encodeFunctionData('getBase64ByAccountName', [accountName])
		const res = await fetch(CONET_RPC, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				jsonrpc: '2.0',
				method: 'eth_call',
				params: [{ to: ACCOUNT_REGISTRY, data }, 'latest'],
				id: 1,
			}),
		})
		if (!res.ok) return null
		const json = (await res.json()) as { error?: unknown; result?: string }
		if (json.error || !json.result) return null
		const decoded = registryIface.decodeFunctionResult('getBase64ByAccountName', json.result)
		const encoded = String(decoded[0] ?? '').trim()
		if (!encoded) return null
		const payload = decodeRecoverStoragePayload(encoded)
		if (!payload) return null
		return payload
	} catch {
		return null
	}
}

/** Restore: local IndexedDB first, else chain recover blob (`restoreWithUserPin` parity). */
export async function restorePosWalletWithIndexedDb(params: {
	accountName: string
	password: string
}): Promise<RestorePosWalletResult> {
	const accountName = params.accountName.trim()
	if (!accountName) return { ok: false, error: 'Account name is required.' }
	if (!params.password) return { ok: false, error: 'Enter your access password' }

	const local = await loadPosWalletInitFromIndexedDb()
	if (
		local?.mnemonicPhrase &&
		local.profiles[0]?.accountName?.toLowerCase() === accountName.toLowerCase()
	) {
		const w = hydrateSessionFromMnemonic(local.mnemonicPhrase)
		if (w) return { ok: true, address: w.address }
	}

	const recoverHit = await fetchRecoverPayloadByAccountName(accountName)
	if (!recoverHit) {
		return { ok: false, error: 'Could not load recovery data for this account.' }
	}

	let phraseBase64: string
	try {
		phraseBase64 = await aesGcmDecryptWithStored(recoverHit.img, params.password, recoverHit.stored)
	} catch {
		return { ok: false, error: 'Incorrect password or recovery data.' }
	}

	const mnemonicPhrase = fromBase64Utf8(phraseBase64).trim()
	const w = hydrateSessionFromMnemonic(mnemonicPhrase)
	if (!w) return { ok: false, error: 'Could not restore wallet from recovery data.' }

	try {
		await persistPosWalletInit({
			ver: 1,
			isReady: true,
			mnemonicPhrase,
			profiles: [
				{
					keyID: w.address,
					accountName,
					type: 'ethereum',
					isPrimary: true,
				},
			],
		})
	} catch {
		return { ok: false, error: walletSaveFailedMessage(false) }
	}

	return { ok: true, address: w.address }
}

/** App.tsx `checkStorage` — load IndexedDB init and hydrate session private key. */
export async function checkPosWalletStorage(): Promise<PosWalletInitRecord | null> {
	const record = await loadPosWalletInitFromIndexedDb()
	if (!record?.mnemonicPhrase) return null
	if (!hasSessionWallet()) {
		hydrateSessionFromMnemonic(record.mnemonicPhrase)
	}
	return record
}

export {
	clearSessionWallet,
	getSessionPrivateKeyHex,
	getSessionWalletAddress,
	hasSessionWallet,
}
