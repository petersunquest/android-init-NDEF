import { isMobileDeviceForWalletApps } from '../utils/mobileWalletApps'
import { WalletAppDappIconButtons } from './WalletAppDappIconButtons'

type Props = {
	/** Override default panel title (e.g. Vouchers / EIP-681 flow). */
	title?: string
	/** Override default helper text under the title. */
	description?: string
}

/**
 * Phone / tablet only: wallet buttons open this page inside each app’s in-app browser (or store / fallback).
 * No install detection — taps go straight to MetaMask / OKX / Base / TP universal or deep links.
 */
export function MobileWalletPayPanel({ title, description }: Props) {
	if (!isMobileDeviceForWalletApps()) return null

	const defaultTitle = 'Pay with a wallet app'
	const defaultDescription =
		'Choose a wallet below to open this payment page in the app. If the app is not installed, your device will usually offer the App Store or Play Store. Then pay with USDC on Base.'

	return (
		<div className="rounded-3xl border border-outline-variant/20 bg-surface-container-lowest p-6 shadow-[0_4px_24px_rgba(0,0,0,0.04)]">
			<h2 className="text-lg font-bold text-on-surface">{title ?? defaultTitle}</h2>
			<p className="mt-2 text-sm leading-relaxed text-on-surface-variant">{description ?? defaultDescription}</p>

			<p className="mt-4 text-center text-xs text-on-surface-variant">Tap an icon to open this page in the wallet app.</p>
			<WalletAppDappIconButtons className="mt-4" />
		</div>
	)
}
