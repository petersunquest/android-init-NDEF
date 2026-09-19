import { useEffect, useMemo, useState } from 'react'
import { ethers } from 'ethers'
import { QRCodeCanvas } from 'qrcode.react'
import {
  buildWalletAuthorization,
  createStripeGift,
  createWalletGift,
  loadGiftCard,
  pollStripeGift,
  quoteGift,
  redeemHash,
  redeemUrl,
  type GiftCard,
} from './api'
import { listGiftPurchases, saveGiftPurchase, type GiftPurchase } from './giftDb'
import './styles.css'

declare global {
  interface Window {
    ethereum?: any
  }
}

function amountToE6(value: string): string {
  return ethers.parseUnits(value || '0', 6).toString()
}

function formatE6(value: string, currency: string): string {
  return `${currency} ${Number(ethers.formatUnits(value || '0', 6)).toFixed(2)}`
}

function cardAddressFromPath(): string {
  const match = window.location.pathname.match(/\/gift\/(0x[a-fA-F0-9]{40})/)
  return match?.[1] ?? ''
}

export default function App() {
  const cardAddress = cardAddressFromPath()
  const [card, setCard] = useState<GiftCard | null>(null)
  const [amount, setAmount] = useState('25')
  const [rail, setRail] = useState<'wallet' | 'stripe'>('wallet')
  const [wallet, setWallet] = useState('')
  const [history, setHistory] = useState<GiftPurchase[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [success, setSuccess] = useState<GiftPurchase | null>(null)

  useEffect(() => {
    if (!cardAddress) {
      setError('This Gift URL does not contain a valid merchant card address.')
      return
    }
    void loadGiftCard(cardAddress).then(setCard).catch((e: unknown) => {
      setError(e instanceof Error ? e.message : 'Unable to load this merchant Gift page')
    })
    void listGiftPurchases().then(setHistory).catch(() => {})
  }, [cardAddress])

  const amountFiat6 = useMemo(() => {
    try { return amountToE6(amount) } catch { return '0' }
  }, [amount])
  const totalFiat6 = useMemo(() => {
    try { return (BigInt(amountFiat6) + BigInt(card?.membershipFeeE6 ?? '0')).toString() } catch { return '0' }
  }, [amountFiat6, card?.membershipFeeE6])

  async function connectWallet(): Promise<{ provider: ethers.BrowserProvider; address: string }> {
    if (!window.ethereum) throw new Error('Install MetaMask or another compatible wallet to pay with a wallet.')
    const provider = new ethers.BrowserProvider(window.ethereum)
    await provider.send('eth_requestAccounts', [])
    const network = await provider.getNetwork()
    if (network.chainId !== 224422n) {
      throw new Error('Switch your wallet to the CoNET network before paying.')
    }
    const signer = await provider.getSigner()
    const address = await signer.getAddress()
    setWallet(address)
    return { provider, address }
  }

  async function buyWithWallet() {
    if (!card) return
    setBusy(true)
    setError('')
    try {
      const { provider, address } = await connectWallet()
      const code = `beamio-gift-${crypto.randomUUID()}`
      const hash = redeemHash(code)
      const quotedUsdc6 = await quoteGift(card.address, totalFiat6)
      const auth = await buildWalletAuthorization({
        provider,
        from: address,
        to: card.owner,
        value: quotedUsdc6,
      })
      const result = await createWalletGift({
        cardAddress: card.address,
        from: address,
        code,
        membershipFeeE6: card.membershipFeeE6,
        topupPrincipalE6: amountFiat6,
        usdcAmount: quotedUsdc6,
        ...auth,
      })
      const purchase: GiftPurchase = {
        purchaseId: `${hash}:${Date.now()}`,
        cardAddress: card.address,
        merchantName: card.name,
        redeemCode: code,
        redeemHash: hash,
        purchasedAt: Date.now(),
        amountFiat6: totalFiat6,
        currency: card.currency,
        paymentRail: 'wallet',
        createTxHash: result.createTxHash,
        status: 'purchased',
      }
      await saveGiftPurchase(purchase)
      setHistory((previous) => [purchase, ...previous])
      setSuccess(purchase)
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Gift purchase failed')
    } finally {
      setBusy(false)
    }
  }

  async function buyWithStripe() {
    if (!card) return
    setBusy(true)
    setError('')
    try {
      const code = `beamio-gift-${crypto.randomUUID()}`
      const hash = redeemHash(code)
      const result = await createStripeGift({
        cardAddress: card.address,
        buyerEoa: ethers.ZeroAddress,
        amountFiat6: totalFiat6,
        currency: card.currency,
        membershipFeeE6: card.membershipFeeE6,
        topupPrincipalE6: amountFiat6,
        redeemHash: hash,
      })
      sessionStorage.setItem('beamio:gifts:pending', JSON.stringify({
        sessionId: result.sessionId,
        card,
        code,
        hash,
        amountFiat6: totalFiat6,
      }))
      window.location.assign(result.url)
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Unable to start card payment')
      setBusy(false)
    }
  }

  useEffect(() => {
    const pendingRaw = sessionStorage.getItem('beamio:gifts:pending')
    const sessionId = new URLSearchParams(window.location.search).get('session_id')
    if (!pendingRaw || !sessionId || sessionId === 'null') return
    const pending = JSON.parse(pendingRaw) as {
      sessionId: string; card: GiftCard; code: string; hash: string; amountFiat6: string
    }
    if (pending.sessionId !== sessionId) return
    let cancelled = false
    const check = async () => {
      try {
        const result = await pollStripeGift(sessionId)
        if (cancelled) return
        if (result.fulfillmentStatus === 'fulfillment_succeeded' || result.status === 'succeeded' && result.txHash) {
          const purchase: GiftPurchase = {
            purchaseId: `${pending.hash}:${Date.now()}`,
            cardAddress: pending.card.address,
            merchantName: pending.card.name,
            redeemCode: pending.code,
            redeemHash: pending.hash,
            purchasedAt: Date.now(),
            amountFiat6: pending.amountFiat6,
            currency: pending.card.currency,
            paymentRail: 'stripe',
            createTxHash: result.txHash,
            status: 'purchased',
          }
          await saveGiftPurchase(purchase)
          setHistory((previous) => [purchase, ...previous])
          setSuccess(purchase)
          sessionStorage.removeItem('beamio:gifts:pending')
          return
        }
        if (result.status === 'failed') {
          setError(result.error ?? 'Stripe payment could not be completed')
          return
        }
        window.setTimeout(check, 2500)
      } catch (e: unknown) {
        setError(e instanceof Error ? e.message : 'Unable to confirm card payment')
      }
    }
    void check()
    return () => { cancelled = true }
  }, [])

  const grouped = history.reduce<Record<string, GiftPurchase[]>>((groups, purchase) => {
    ;(groups[purchase.cardAddress] ??= []).push(purchase)
    return groups
  }, {})

  if (!card && !error) return <main className="shell"><p>Loading Gift…</p></main>
  return (
    <main className="shell">
      <section className="hero">
        <p className="eyebrow">BEAMIO GIFT</p>
        <h1>{card?.name ?? 'Merchant Gift'}</h1>
        <p>{card?.description}</p>
      </section>
      {error && <div className="alert" role="alert">{error}</div>}
      {card && (
        <section className="panel">
          <label htmlFor="gift-amount">Gift amount ({card.currency})</label>
          <input id="gift-amount" inputMode="decimal" value={amount} onChange={(event) => setAmount(event.target.value)} />
          <div className="rail">
            <button className={rail === 'wallet' ? 'selected' : ''} onClick={() => setRail('wallet')} type="button">Third-party wallet</button>
            <button className={rail === 'stripe' ? 'selected' : ''} onClick={() => setRail('stripe')} type="button" disabled={!card.stripeConnected}>Visa / Mastercard</button>
          </div>
          <p className="hint">The buyer receives a redeem link after the payment is confirmed.</p>
          <button className="primary" type="button" disabled={busy} onClick={() => void (rail === 'wallet' ? buyWithWallet() : buyWithStripe())}>
            {busy ? 'Processing…' : 'Buy Gift'}
          </button>
          {wallet && <p className="hint">Connected wallet: {wallet.slice(0, 6)}…{wallet.slice(-4)}</p>}
        </section>
      )}
      {success && (
        <section className="panel success">
          <h2>Gift purchased</h2>
          <p>Save this link or show the QR code to the recipient.</p>
          <QRCodeCanvas value={redeemUrl(success.cardAddress, success.redeemCode)} size={220} />
          <code>{redeemUrl(success.cardAddress, success.redeemCode)}</code>
          <button type="button" onClick={() => navigator.clipboard.writeText(redeemUrl(success.cardAddress, success.redeemCode))}>Copy claim link</button>
        </section>
      )}
      {Object.entries(grouped).map(([address, purchases]) => (
        <section className="panel" key={address}>
          <h2>{purchases[0]?.merchantName ?? address}</h2>
          {purchases.map((purchase) => (
            <div className="history-row" key={purchase.purchaseId}>
              <span>{new Date(purchase.purchasedAt).toLocaleString()}</span>
              <span>{formatE6(purchase.amountFiat6, purchase.currency)}</span>
              <button type="button" onClick={() => setSuccess(purchase)}>Review code</button>
            </div>
          ))}
        </section>
      ))}
    </main>
  )
}
