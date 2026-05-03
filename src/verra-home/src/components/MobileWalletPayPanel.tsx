import { useEffect, useState } from 'react'
import {
	buildMobileWalletDappLinks,
	injectedWalletFlags,
	isMobileDeviceForWalletApps,
	openBaseWalletDappWithFallback,
	probeMobileWalletInstallations,
	type MobileWalletId,
} from '../utils/mobileWalletApps'

const BTN =
	'inline-flex flex-1 min-w-[108px] items-center justify-center rounded-full bg-blue-600 px-4 py-3 text-sm font-bold text-white shadow-md transition-all hover:bg-blue-500 active:scale-95'

type Props = {
	/** Universal MetaMask app link when probes find no installed wallet (still opens app or store). */
	fallbackDeeplink: string
}

/**
 * Phone / tablet only: neutral panel listing wallet apps that appear to be installed,
 * so the customer can open this payment URL inside the app. No “no browser wallet” warning.
 */
export function MobileWalletPayPanel({ fallbackDeeplink }: Props) {
	const [visible, setVisible] = useState<Record<MobileWalletId, boolean>>({
		metamask: false,
		okx: false,
		base: false,
		tp: false,
	})
	const [ready, setReady] = useState(false)

	useEffect(() => {
		if (!isMobileDeviceForWalletApps()) {
			setReady(true)
			return
		}
		let cancelled = false
		void (async () => {
			const inj = injectedWalletFlags()
			const probed = await probeMobileWalletInstallations()
			if (cancelled) return
			setVisible({
				metamask: !inj.metamask && probed.metamask,
				okx: !inj.okx && probed.okx,
				base: !inj.base && probed.base,
				tp: !inj.tp && probed.tp,
			})
			setReady(true)
		})()
		return () => {
			cancelled = true
		}
	}, [])

	if (!isMobileDeviceForWalletApps()) return null

	const links = buildMobileWalletDappLinks()
	const any = visible.metamask || visible.okx || visible.base || visible.tp

	return (
		<div className="rounded-3xl border border-outline-variant/20 bg-surface-container-lowest p-6 shadow-[0_4px_24px_rgba(0,0,0,0.04)]">
			<h2 className="text-lg font-bold text-on-surface">Pay with a wallet app</h2>
			<p className="mt-2 text-sm leading-relaxed text-on-surface-variant">
				Choose an installed wallet below to open this payment page inside the app’s browser. Then connect your wallet
				and pay with USDC on Base.
			</p>

			{!ready ? (
				<p className="mt-6 text-center text-sm font-medium text-on-surface-variant">Looking for wallet apps…</p>
			) : any ? (
				<div className="mt-6 flex flex-wrap gap-3">
					{visible.metamask ? (
						<a href={links.metamask} target="_self" rel="noreferrer" className={BTN}>
							MetaMask
						</a>
					) : null}
					{visible.okx ? (
						<a href={links.okx} target="_self" rel="noreferrer" className={BTN}>
							OKX Wallet
						</a>
					) : null}
					{visible.base ? (
						<button
							type="button"
							onClick={() => openBaseWalletDappWithFallback()}
							className={BTN}
						>
							Base Wallet
						</button>
					) : null}
					{visible.tp ? (
						<a href={links.tp} target="_self" rel="noreferrer" className={BTN}>
							TP Wallet
						</a>
					) : null}
				</div>
			) : (
				<div className="mt-6 space-y-4">
					<p className="text-sm text-on-surface-variant">
						We could not confirm a wallet app on this device. You can still try MetaMask, or open this page from
						inside MetaMask, OKX Wallet, Base Wallet, or TP Wallet (browser menu → paste link).
					</p>
					<a
						href={fallbackDeeplink}
						target="_blank"
						rel="noopener noreferrer"
						className="inline-flex w-full items-center justify-center rounded-full bg-blue-600 px-6 py-3 text-sm font-bold text-white shadow-md transition-all hover:bg-blue-500 active:scale-95"
					>
						Try opening in MetaMask
					</a>
				</div>
			)}
		</div>
	)
}
