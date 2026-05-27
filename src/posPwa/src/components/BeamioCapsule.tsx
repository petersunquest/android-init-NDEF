import type { TerminalProfile } from '@/types/pos'
import { dicebearAvatarUrl, profileBeamioTag, profileDisplayName, shortAddress } from '@/utils/display'
import { AddressCapsule } from './AddressCapsule'

export function BeamioCapsule({
	profile,
	fallbackAddress,
	className = '',
	tone = 'onDark',
	showAddressCapsule = false,
	address: addressProp,
}: {
	profile: TerminalProfile
	fallbackAddress?: string | null
	className?: string
	tone?: 'onDark' | 'onLight'
	/** When true, render address pill inside the capsule row (search / terminal setup). */
	showAddressCapsule?: boolean
	address?: string | null
}) {
	const tag = profileBeamioTag(profile)
	const name = profileDisplayName(profile)
	const resolvedAddress = (addressProp ?? profile.address ?? fallbackAddress ?? '').trim()
	const seed = tag || name || resolvedAddress || 'Beamio'
	const showFallback = !tag && !name && resolvedAddress
	const isLight = tone === 'onLight'
	const addressCapsule =
		showAddressCapsule && !showFallback && resolvedAddress.length >= 10 ? (
			<AddressCapsule
				address={resolvedAddress}
				className={
					isLight
						? 'border-mkt-outlineVariant/40 bg-white text-mkt-onSurfaceVariant'
						: 'bg-white/10 border-white/15 text-white/80'
				}
			/>
		) : null

	return (
		<div className={`flex min-w-0 items-center gap-2.5 ${className}`}>
			<img
				src={profile.image || dicebearAvatarUrl(seed)}
				alt=""
				className={`h-9 w-9 shrink-0 rounded-full border object-cover ${
					isLight ? 'border-mkt-outlineVariant/50' : 'border-white/20'
				}`}
			/>
			<div className="flex min-w-0 flex-1 items-center gap-2">
				<div className="min-w-0 flex-1 text-left">
					{showFallback ? (
						<AddressCapsule
							address={resolvedAddress}
							className={
								isLight
									? 'border-mkt-outlineVariant/40 bg-white text-mkt-onSurfaceVariant'
									: undefined
							}
						/>
					) : (
						<>
							<p
								className={`truncate text-sm font-semibold ${
									isLight ? 'text-mkt-onSurface' : 'text-white'
								}`}
							>
								{name || (tag ? `@${tag}` : '—')}
							</p>
							{tag && name ? (
								<p
									className={`truncate text-xs ${
										isLight ? 'font-medium text-mkt-primary' : 'text-white/70'
									}`}
								>
									@{tag}
								</p>
							) : null}
						</>
					)}
				</div>
				{addressCapsule ? <span className="shrink-0">{addressCapsule}</span> : null}
			</div>
		</div>
	)
}

export function BeamioCapsuleCompact(props: {
	profile: TerminalProfile
	fallbackAddress?: string | null
}) {
	return <BeamioCapsule {...props} className="max-w-[160px]" />
}

export function profileHasIdentity(profile: TerminalProfile): boolean {
	const tag = profileBeamioTag(profile)
	if (tag) return true
	return profileDisplayName(profile).length > 0
}

export function walletShortLine(addr: string): string {
	return shortAddress(addr)
}
