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
/** Fallback when IndexedDB is blocked (private mode / WebView policy). */
const LS_FALLBACK_KEY = 'beamio_pos_wallet_init_v1'

/** PouchDB-compatible envelope: `{ title: base64(JSON) }`. */
type InitEnvelope = { title: string }

function isPosWalletInitRecord(raw: unknown): raw is PosWalletInitRecord {
	if (!raw || typeof raw !== 'object') return false
	const rec = raw as PosWalletInitRecord
	return Boolean(
		rec.mnemonicPhrase?.trim() &&
			Array.isArray(rec.profiles) &&
			rec.profiles[0]?.keyID?.trim(),
	)
}

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
		req.onblocked = () => reject(new Error('IndexedDB open blocked'))
	})
}

function idbGet(db: IDBDatabase, key: string): Promise<unknown> {
	return new Promise((resolve, reject) => {
		const tx = db.transaction(STORE, 'readonly')
		const req = tx.objectStore(STORE).get(key)
		req.onsuccess = () => resolve(req.result)
		req.onerror = () => reject(req.error ?? tx.error)
		tx.onerror = () => reject(tx.error ?? req.error)
	})
}

function idbPut(db: IDBDatabase, key: string, value: unknown): Promise<void> {
	return new Promise((resolve, reject) => {
		const tx = db.transaction(STORE, 'readwrite')
		const req = tx.objectStore(STORE).put(value, key)
		req.onsuccess = () => resolve()
		req.onerror = () => reject(req.error ?? tx.error ?? new Error('IndexedDB put failed'))
		tx.onerror = () => reject(tx.error ?? req.error)
	})
}

function decodeEnvelope(raw: unknown): PosWalletInitRecord | null {
	if (!raw || typeof raw !== 'object') return null
	const title = (raw as InitEnvelope).title
	if (typeof title !== 'string' || !title.trim()) return null
	try {
		const bin = atob(title)
		const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0))
		const parsed = JSON.parse(new TextDecoder().decode(bytes)) as PosWalletInitRecord
		return isPosWalletInitRecord(parsed) ? parsed : null
	} catch {
		return null
	}
}

function parseStoredInit(raw: unknown): PosWalletInitRecord | null {
	if (isPosWalletInitRecord(raw)) return raw
	return decodeEnvelope(raw)
}

function readLocalStorageFallback(): PosWalletInitRecord | null {
	if (typeof localStorage === 'undefined') return null
	try {
		const raw = localStorage.getItem(LS_FALLBACK_KEY)
		if (!raw) return null
		return parseStoredInit(JSON.parse(raw))
	} catch {
		return null
	}
}

function writeLocalStorageFallback(record: PosWalletInitRecord): void {
	if (typeof localStorage === 'undefined') {
		throw new Error('localStorage is unavailable')
	}
	localStorage.setItem(LS_FALLBACK_KEY, JSON.stringify(record))
}

function clearLocalStorageFallback(): void {
	try {
		localStorage?.removeItem(LS_FALLBACK_KEY)
	} catch {
		/* ignore */
	}
}

async function saveToIndexedDb(record: PosWalletInitRecord): Promise<void> {
	const db = await openDb()
	try {
		await idbPut(db, INIT_DOC_ID, record)
	} finally {
		db.close()
	}
}

async function loadFromIndexedDb(): Promise<PosWalletInitRecord | null> {
	const db = await openDb()
	try {
		const raw = await idbGet(db, INIT_DOC_ID)
		return parseStoredInit(raw)
	} finally {
		db.close()
	}
}

/** Best-effort probe before onboarding — does not persist secrets. */
export async function probePosWalletStorageWritable(): Promise<boolean> {
	const probeKey = '__pos_wallet_probe__'
	try {
		const db = await openDb()
		try {
			await idbPut(db, probeKey, { ok: true, at: Date.now() })
			await new Promise<void>((resolve, reject) => {
				const tx = db.transaction(STORE, 'readwrite')
				const req = tx.objectStore(STORE).delete(probeKey)
				req.onsuccess = () => resolve()
				req.onerror = () => reject(req.error ?? tx.error)
				tx.onerror = () => reject(tx.error ?? req.error)
			})
			return true
		} finally {
			db.close()
		}
	} catch {
		try {
			const k = `${LS_FALLBACK_KEY}:probe`
			localStorage.setItem(k, '1')
			localStorage.removeItem(k)
			return true
		} catch {
			return false
		}
	}
}

export async function loadPosWalletInitFromIndexedDb(): Promise<PosWalletInitRecord | null> {
	try {
		const fromIdb = await loadFromIndexedDb()
		if (fromIdb) return fromIdb
	} catch {
		/* fall through to localStorage */
	}
	return readLocalStorageFallback()
}

export async function savePosWalletInitToIndexedDb(record: PosWalletInitRecord): Promise<void> {
	let idbError: unknown
	try {
		await saveToIndexedDb(record)
		clearLocalStorageFallback()
		return
	} catch (err) {
		idbError = err
	}

	try {
		writeLocalStorageFallback(record)
		return
	} catch {
		/* both failed */
	}

	const idbMsg =
		idbError instanceof DOMException
			? idbError.name
			: idbError instanceof Error
				? idbError.message
				: 'unknown'
	throw new Error(`IndexedDB save failed (${idbMsg})`)
}

export async function clearPosWalletInitFromIndexedDb(): Promise<void> {
	clearLocalStorageFallback()
	try {
		const db = await openDb()
		try {
			await new Promise<void>((resolve, reject) => {
				const tx = db.transaction(STORE, 'readwrite')
				const req = tx.objectStore(STORE).delete(INIT_DOC_ID)
				req.onsuccess = () => resolve()
				req.onerror = () => reject(req.error ?? tx.error)
				tx.onerror = () => reject(tx.error ?? req.error)
			})
		} finally {
			db.close()
		}
	} catch {
		/* ignore */
	}
}

export async function hasPosWalletInIndexedDb(): Promise<boolean> {
	const rec = await loadPosWalletInitFromIndexedDb()
	return Boolean(rec?.mnemonicPhrase?.trim())
}
