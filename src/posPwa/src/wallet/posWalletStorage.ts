/**
 * POS PWA local wallet init blob — IndexedDB (align SilentPassUI `checkStorage` / PouchDB doc `init`).
 * Persists **mnemonicPhrase** only; private key stays in session memory (`posWalletSession.ts`).
 */

export type PosWalletProfile = {
	keyID: string
	accountName?: string
	type: 'ethereum'
	isPrimary: true
}

/** Same shape as bizSite `encrypt_keys_object` subset used at wallet init. */
export type PosWalletInitRecord = {
	ver: 1
	isReady: true
	mnemonicPhrase: string
	profiles: PosWalletProfile[]
	parentBeamioTag?: string
}

const DB_NAME = 'beamio_pos_wallet_v1'
const STORE = 'docs'
const INIT_DOC_ID = 'init'

function openDb(): Promise<IDBDatabase> {
	return new Promise((resolve, reject) => {
		if (typeof indexedDB === 'undefined') {
			reject(new Error('IndexedDB is unavailable'))
			return
		}
		const req = indexedDB.open(DB_NAME, 1)
		req.onupgradeneeded = () => {
			const db = req.result
			if (!db.objectStoreNames.contains(STORE)) {
				db.createObjectStore(STORE)
			}
		}
		req.onsuccess = () => resolve(req.result)
		req.onerror = () => reject(req.error ?? new Error('IndexedDB open failed'))
	})
}

function idbGet(db: IDBDatabase, key: string): Promise<unknown> {
	return new Promise((resolve, reject) => {
		const tx = db.transaction(STORE, 'readonly')
		const req = tx.objectStore(STORE).get(key)
		req.onsuccess = () => resolve(req.result)
		req.onerror = () => reject(req.error)
	})
}

function idbPut(db: IDBDatabase, key: string, value: unknown): Promise<void> {
	return new Promise((resolve, reject) => {
		const tx = db.transaction(STORE, 'readwrite')
		tx.oncomplete = () => resolve()
		tx.onerror = () => reject(tx.error)
		tx.objectStore(STORE).put(value, key)
	})
}

/** PouchDB-compatible envelope: `{ title: base64(JSON) }`. */
type InitEnvelope = { title: string }

function encodeRecord(record: PosWalletInitRecord): InitEnvelope {
	const json = JSON.stringify(record)
	const title = btoa(
		Array.from(new TextEncoder().encode(json), (c) => String.fromCharCode(c)).join(''),
	)
	return { title }
}

function decodeEnvelope(raw: unknown): PosWalletInitRecord | null {
	if (!raw || typeof raw !== 'object') return null
	const title = (raw as InitEnvelope).title
	if (typeof title !== 'string' || !title.trim()) return null
	try {
		const bin = atob(title)
		const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0))
		const parsed = JSON.parse(new TextDecoder().decode(bytes)) as PosWalletInitRecord
		if (!parsed?.mnemonicPhrase?.trim() || !Array.isArray(parsed.profiles) || !parsed.profiles[0]?.keyID) {
			return null
		}
		return parsed
	} catch {
		return null
	}
}

export async function loadPosWalletInitFromIndexedDb(): Promise<PosWalletInitRecord | null> {
	try {
		const db = await openDb()
		const raw = await idbGet(db, INIT_DOC_ID)
		db.close()
		return decodeEnvelope(raw)
	} catch {
		return null
	}
}

export async function savePosWalletInitToIndexedDb(record: PosWalletInitRecord): Promise<void> {
	const db = await openDb()
	try {
		await idbPut(db, INIT_DOC_ID, encodeRecord(record))
	} finally {
		db.close()
	}
}

export async function clearPosWalletInitFromIndexedDb(): Promise<void> {
	try {
		const db = await openDb()
		await new Promise<void>((resolve, reject) => {
			const tx = db.transaction(STORE, 'readwrite')
			tx.oncomplete = () => resolve()
			tx.onerror = () => reject(tx.error)
			tx.objectStore(STORE).delete(INIT_DOC_ID)
		})
		db.close()
	} catch {
		/* ignore */
	}
}

export async function hasPosWalletInIndexedDb(): Promise<boolean> {
	const rec = await loadPosWalletInitFromIndexedDb()
	return Boolean(rec?.mnemonicPhrase?.trim())
}
