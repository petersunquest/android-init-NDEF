import { normalizeEoaLower40 } from '@/conet/crypto'

const DB_NAME = 'beamio_pos_chat_pgp_v1'
const STORE = 'pgp'
const DOC_ID = 'keys'

export type PosChatPgpBundle = {
	eoaLower: string
	privateKeyArmored: string
	publicKeyArmored: string
	keyID: string
	routerArmoredPublicKey: string
	updatedAt: number
}

function openDb(): Promise<IDBDatabase> {
	return new Promise((resolve, reject) => {
		const req = indexedDB.open(DB_NAME, 1)
		req.onupgradeneeded = () => {
			const db = req.result
			if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE)
		}
		req.onsuccess = () => resolve(req.result)
		req.onerror = () => reject(req.error ?? new Error('idb open failed'))
	})
}

export async function loadPosChatPgp(eoa: string): Promise<PosChatPgpBundle | null> {
	const h = normalizeEoaLower40(eoa)
	if (!h) return null
	try {
		const db = await openDb()
		return await new Promise((resolve, reject) => {
			const tx = db.transaction(STORE, 'readonly')
			const req = tx.objectStore(STORE).get(DOC_ID)
			req.onsuccess = () => {
				const v = req.result as PosChatPgpBundle | undefined
				if (!v || v.eoaLower !== h) resolve(null)
				else resolve(v)
			}
			req.onerror = () => reject(req.error)
		})
	} catch {
		return null
	}
}

export async function savePosChatPgp(bundle: PosChatPgpBundle): Promise<void> {
	const h = normalizeEoaLower40(bundle.eoaLower)
	if (!h) return
	try {
		const db = await openDb()
		await new Promise<void>((resolve, reject) => {
			const tx = db.transaction(STORE, 'readwrite')
			tx.objectStore(STORE).put({ ...bundle, eoaLower: h, updatedAt: Date.now() }, DOC_ID)
			tx.oncomplete = () => resolve()
			tx.onerror = () => reject(tx.error)
		})
	} catch {
		/* ignore */
	}
}
