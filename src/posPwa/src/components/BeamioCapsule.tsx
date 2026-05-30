import type { TerminalProfile } from '@/types/pos'
import { dicebearAvatarUrl, profileBeamioTag, profileDisplayName, shortAddress } from '@/utils/display'
import { AddressCapsule } from './AddressCapsule'

function avatarSeedFromProfile(profile: TerminalProfile): string {
	const tag = profileBeamioTag(profile)
	return tag || 'Beamio'
}

export function BeamioCapsule({
	profile,
	fallbackAddress,
	className = '',
	tone = 'onDark',
	showAddressCapsule = false,
	address: addressProp,
	compact = false,
}: {
	profile: TerminalProfile
	fallbackAddress?: string | null
	className?: string
	tone?: 'onDark' | 'onLight'
	/** When true, render address pill inside the capsule row (search / terminal setup). */
	showAddressCapsule?: boolean
	address?: string | null
	compact?: boolean
}) {
	const tag = profileBeamioTag(profile)
	const name = profileDisplayName(profile)
	const hasName = name.length > 0
	const resolvedAddress = (addressProp ?? profile.address ?? fallbackAddress ?? '').trim()
	const showAddressFallback = !tag && !hasName && resolvedAddress.length >= 10
	const isLight = tone === 'onLight'
	const avatarSize = compact ? 'h-7 w-7' : 'h-9 w-9'

	const addressCapsule =
		showAddressCapsule && !showAddressFallback && resolvedAddress.length >= 10 ? (
			<AddressCapsule
				address={resolvedAddress}
				className={
					isLight
						? 'border-mkt-outlineVariant/40 bg-white text-mkt-onSurfaceVariant'
						: 'bg-white/10 border-white/15 text-white/80'
				}
			/>
		) : null

	const primaryTextClass = isLight ? 'text-slate-900' : 'text-white'
	const tagTextClass = isLight ? 'text-slate-900/70' : 'text-white/70'

	return (
		<div className={`flex min-w-0 items-center gap-2 ${compact ? 'gap-2' : 'gap-2.5'} ${className}`}>
			<img
				src={profile.image?.trim() || dicebearAvatarUrl(avatarSeedFromProfile(profile))}
				alt=""
				className={`${avatarSize} shrink-0 rounded-full border object-cover ${
					isLight ? 'border-slate-200/80' : 'border-white/20'
				}`}
			/>
			<div className="flex min-w-0 flex-1 items-center gap-2">
				<div className="min-w-0 flex-1 text-left leading-tight">
					{showAddressFallback ? (
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
							{hasName ? (
								<p className={`truncate text-xs font-semibold ${primaryTextClass}`}>{name}</p>
							) : null}
							{tag ? (
								<p
									className={`truncate font-medium ${tagTextClass} ${
										hasName ? 'text-[10px]' : 'text-xs font-semibold'
									}`}
								>
									@{tag}
								</p>
							) : !hasName ? (
								<p className={`truncate text-xs font-semibold ${primaryTextClass}`}>—</p>
							) : null}
						</>
					)}
				</div>
				{addressCapsule ? <span className="shrink-0">{addressCapsule}</span> : null}
			</div>
		</div>
	)
}

/** Home / header compact pill — avatar + displayName + @beamioTag (Android `BeamioCapsuleCompact`). */
export function BeamioCapsuleCompact(props: {
	profile: TerminalProfile
	fallbackAddress?: string | null
	className?: string
}) {
	return (
		<div
			className={`inline-flex max-w-[min(180px,42vw)] shrink-0 rounded-full bg-black/[0.06] py-1.5 pl-1.5 pr-2.5 ${props.className ?? ''}`}
		>
			<BeamioCapsule
				profile={props.profile}
				fallbackAddress={props.fallbackAddress}
				tone="onLight"
				compact
				className="min-w-0"
			/>
		</div>
	)
}

export function profileHasIdentity(profile: TerminalProfile): boolean {
	const tag = profileBeamioTag(profile)
	if (tag) return true
	return profileDisplayName(profile).length > 0
}

export function walletShortLine(addr: string): string {
	return shortAddress(addr)
}
