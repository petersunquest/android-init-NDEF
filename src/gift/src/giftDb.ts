export type GiftPurchase = {
  purchaseId: string
  cardAddress: string
  merchantName: string
  redeemCode: string
  redeemHash: string
  purchasedAt: number
  amountFiat6: string
  currency: string
  paymentRail: 'wallet' | 'stripe'
  createTxHash?: string
  status: 'purchased' | 'claimed' | 'expired'
}

const DB_NAME = 'beamio-gift-purchases-v1'
const STORE_NAME = 'purchases'

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1)
    request.onupgradeneeded = () => {
      const db = request.result
      const store = db.createObjectStore(STORE_NAME, { keyPath: 'purchaseId' })
      store.createIndex('cardAddress', 'cardAddress', { unique: false })
      store.createIndex('purchasedAt', 'purchasedAt', { unique: false })
      store.createIndex('redeemHash', 'redeemHash', { unique: true })
    }
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error ?? new Error('Unable to open Gift history'))
  })
}

export async function listGiftPurchases(): Promise<GiftPurchase[]> {
  const db = await openDb()
  return new Promise((resolve, reject) => {
    const request = db.transaction(STORE_NAME, 'readonly').objectStore(STORE_NAME).getAll()
    request.onsuccess = () =>
      resolve((request.result as GiftPurchase[]).sort((a, b) => b.purchasedAt - a.purchasedAt))
    request.onerror = () => reject(request.error ?? new Error('Unable to read Gift history'))
  })
}

export async function saveGiftPurchase(purchase: GiftPurchase): Promise<void> {
  const db = await openDb()
  return new Promise((resolve, reject) => {
    const request = db.transaction(STORE_NAME, 'readwrite').objectStore(STORE_NAME).put(purchase)
    request.onsuccess = () => resolve()
    request.onerror = () => reject(request.error ?? new Error('Unable to save Gift history'))
  })
}
