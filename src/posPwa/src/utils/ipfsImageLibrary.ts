/**
 * Local-first permanent IPFS fragment image library (IndexedDB, keyed by keccak hash).
 * Read local cache before network getFragment; persist trusted fetches indefinitely.
 */

export const IPFS_GET_FRAGMENT_BASE = 'https://ipfs.conet.network/api/getFragment?hash='

const DB_NAME = 'beamio_ipfs_image_library_v1'
const DB_VERSION = 1
const STORE = 'fragments'

export type IpfsImageLibraryRecord = {
  hash: string
  blob: Blob
  mime: string
  savedAt: number
  byteLength: number
}

const inflightByHash = new Map<string, Promise<IpfsImageLibraryRecord | null>>()

export function normalizeFragmentHash(raw: string | undefined | null): string | null {
  const trimmed = String(raw ?? '').trim()
  if (!trimmed) return null
  const body = trimmed.startsWith('0x') ? trimmed.slice(2) : trimmed
  if (!/^[a-fA-F0-9]{64}$/.test(body)) return null
  return `0x${body.toLowerCase()}`
}

/** Parse hash from ipfs.conet.network getFragment or beamio.app /api/fragment URLs. */
export function parseFragmentHashFromUrl(url: string): string | null {
  try {
    const u = new URL(url.trim())
    const host = u.hostname.toLowerCase()
    if (host === 'ipfs.conet.network' || host.endsWith('.ipfs.conet.network')) {
      if (!u.pathname.endsWith('/getFragment')) return null
    } else if (host === 'beamio.app' || host.endsWith('.beamio.app')) {
      if (u.pathname !== '/api/fragment') return null
    } else {
      return null
    }
    const hash = u.searchParams.get('hash')
    return hash ? normalizeFragmentHash(hash) : null
  } catch {
    return null
  }
}

export function ipfsFragmentUrlFromHash(hash: string): string {
  const norm = normalizeFragmentHash(hash)
  if (!norm) return ''
  return `${IPFS_GET_FRAGMENT_BASE}${norm}`
}

export function isIpfsFragmentImageUrl(url: string | undefined | null): boolean {
  return !!url && !!parseFragmentHashFromUrl(url)
}

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION)
    req.onupgradeneeded = () => {
      const db = req.result
      if (!db.objectStoreNames.contains(STORE)) {
        db.createObjectStore(STORE, { keyPath: 'hash' })
      }
    }
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error)
  })
}

export async function getLocalIpfsImageRecord(
  hash: string,
): Promise<IpfsImageLibraryRecord | null> {
  const norm = normalizeFragmentHash(hash)
  if (!norm) return null
  const db = await openDb()
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, 'readonly')
    const req = tx.objectStore(STORE).get(norm)
    req.onsuccess = () => {
      db.close()
      const row = req.result as IpfsImageLibraryRecord | undefined
      if (!row?.blob) {
        resolve(null)
        return
      }
      resolve(row)
    }
    req.onerror = () => {
      db.close()
      reject(req.error)
    }
  })
}

export async function putLocalIpfsImage(
  hash: string,
  blob: Blob,
  mime?: string,
): Promise<void> {
  const norm = normalizeFragmentHash(hash)
  if (!norm || !blob || blob.size <= 0) return

  const resolvedMime = (mime || blob.type || 'image/webp').trim() || 'image/webp'
  const record: IpfsImageLibraryRecord = {
    hash: norm,
    blob,
    mime: resolvedMime,
    savedAt: Date.now(),
    byteLength: blob.size,
  }

  const db = await openDb()
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, 'readwrite')
    const req = tx.objectStore(STORE).put(record)
    req.onsuccess = () => {
      db.close()
      resolve()
    }
    req.onerror = () => {
      db.close()
      reject(req.error)
    }
  })
}

const parseDataUrl = (dataUrl: string) => {
  const s = String(dataUrl || '').trim()
  const m = /^data:([^;]+);base64,(.+)$/i.exec(s)
  if (!m) return null
  return { mime: m[1], base64: m[2] }
}

const base64ToBlob = (base64: string, mime: string) => {
  const bin = atob(base64)
  const arr = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i)
  return new Blob([arr], { type: mime })
}

/** Persist upload payload locally (same hash as postToIPFS keccak). */
export async function putLocalIpfsImageFromDataUrl(hash: string, dataUrl: string): Promise<void> {
  const parsed = parseDataUrl(dataUrl)
  if (!parsed) return
  const blob = base64ToBlob(parsed.base64, parsed.mime || 'image/webp')
  await putLocalIpfsImage(hash, blob, parsed.mime)
}

const sniffImageMime = async (blob: Blob) => {
  const buf = await blob.slice(0, 16).arrayBuffer()
  const b = new Uint8Array(buf)

  if (
    b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 &&
    b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a
  ) return 'image/png'

  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'image/jpeg'

  if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x38) return 'image/gif'

  if (
    b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 &&
    b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50
  ) return 'image/webp'

  const headText = new TextDecoder().decode(b).trimStart()
  if (headText.startsWith('<svg') || headText.startsWith('<?xml')) return 'image/svg+xml'

  return ''
}

async function parseFragmentResponseToBlob(res: Response): Promise<{ blob: Blob; mime: string } | null> {
  if (!res.ok) return null

  const contentType = (res.headers.get('content-type') || '').toLowerCase()
  if (contentType.startsWith('image/')) {
    const blob = await res.blob()
    const mime = blob.type || contentType.split(';')[0].trim() || (await sniffImageMime(blob)) || 'image/webp'
    return { blob, mime }
  }

  const txt = (await res.text()).trim()
  if (txt.startsWith('data:image/')) {
    const parsed = parseDataUrl(txt)
    if (parsed) {
      const blob = base64ToBlob(parsed.base64, parsed.mime || 'image/webp')
      return { blob, mime: parsed.mime || 'image/webp' }
    }
  }

  if (/^[A-Za-z0-9+/]+=*$/.test(txt) && txt.length > 128) {
    const blob = base64ToBlob(txt, 'image/webp')
    return { blob, mime: 'image/webp' }
  }

  return null
}

/** Network fetch only; does not read or write local library. */
export async function fetchIpfsFragmentFromNetwork(
  hash: string,
): Promise<IpfsImageLibraryRecord | null> {
  const norm = normalizeFragmentHash(hash)
  if (!norm) return null

  const url = ipfsFragmentUrlFromHash(norm)
  const res = await fetch(url, { cache: 'force-cache' }).catch(() => null)
  if (!res) return null

  const parsed = await parseFragmentResponseToBlob(res).catch(() => null)
  if (!parsed) return null

  return {
    hash: norm,
    blob: parsed.blob,
    mime: parsed.mime,
    savedAt: Date.now(),
    byteLength: parsed.blob.size,
  }
}

/**
 * Local-first resolve: IndexedDB hit → return; miss → network fetch → persist on trusted success.
 * Failed network does not erase local entries.
 */
export async function resolveIpfsFragmentRecord(hash: string): Promise<IpfsImageLibraryRecord | null> {
  const norm = normalizeFragmentHash(hash)
  if (!norm) return null

  const local = await getLocalIpfsImageRecord(norm).catch(() => null)
  if (local) return local

  const inflight = inflightByHash.get(norm)
  if (inflight) return inflight

  const task = (async () => {
    try {
      const remote = await fetchIpfsFragmentFromNetwork(norm)
      if (remote) {
        await putLocalIpfsImage(norm, remote.blob, remote.mime).catch(() => {})
        return remote
      }
      return null
    } finally {
      inflightByHash.delete(norm)
    }
  })()

  inflightByHash.set(norm, task)
  return task
}

/** Resolve any IPFS fragment URL to a blob: URL (caller must revoke). Non-IPFS URLs pass through. */
export async function resolveIpfsImageUrlToObjectUrl(url: string): Promise<string> {
  const trimmed = String(url || '').trim()
  if (!trimmed) return ''

  if (trimmed.startsWith('data:image/') || trimmed.startsWith('blob:')) {
    return trimmed
  }

  const hash = parseFragmentHashFromUrl(trimmed)
  if (!hash) return trimmed

  const record = await resolveIpfsFragmentRecord(hash)
  if (!record) return trimmed

  const typedBlob =
    record.blob.type === record.mime
      ? record.blob
      : new Blob([record.blob], { type: record.mime })
  return URL.createObjectURL(typedBlob)
}

/** Background warm: local-first fetch for each hash extracted from URLs. */
export function warmIpfsImageUrls(urls: Array<string | undefined | null>): void {
  const seen = new Set<string>()
  for (const raw of urls) {
    const hash = raw ? parseFragmentHashFromUrl(raw) : null
    if (!hash || seen.has(hash)) continue
    seen.add(hash)
    void resolveIpfsFragmentRecord(hash)
  }
}
