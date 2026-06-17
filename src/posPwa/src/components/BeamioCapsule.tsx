import type { TerminalProfile } from '@/types/pos'
import { dicebearAvatarUrl, profileBeamioTag, profileDisplayName, shortAddress } from '@/utils/display'
import { AddressCapsule } from './AddressCapsule'
import { IpfsImg } from './IpfsImg'

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
	subtitleAddress,
	primaryTitle,
	address: addressProp,
	compact = false,
	/** Home header: single line only — no @tag or address second line. */
	showSubtitle = true,
}: {
	profile: TerminalProfile
	fallbackAddress?: string | null
	className?: string
	tone?: 'onDark' | 'onLight'
	/** When true, render address pill inside the capsule row (search / terminal setup). */
	showAddressCapsule?: boolean
	/** Home header: EOA address capsule as subtitle instead of @beamioTag. */
	subtitleAddress?: string | null
	/** Override line 1 — e.g. merchant program metadata business name. */
	primaryTitle?: string | null
	address?: string | null
	compact?: boolean
	showSubtitle?: boolean
}) {
	const tag = profileBeamioTag(profile)
	const name = profileDisplayName(profile)
	const hasName = name.length > 0
	const titleOverride = primaryTitle?.trim() ?? ''
	const showPrimaryTitle = titleOverride.length > 0
	const resolvedAddress = (addressProp ?? profile.address ?? fallbackAddress ?? '').trim()
	const subtitleEoa = (subtitleAddress ?? '').trim()
	const showSubtitleAddress = showSubtitle && subtitleEoa.length >= 10
	const showAddressFallback =
		showSubtitle && !tag && !hasName && resolvedAddress.length >= 10 && !showSubtitleAddress
	const isLight = tone === 'onLight'
	const avatarSize = compact ? 'h-7 w-7' : 'h-9 w-9'

	const subtitleAddressCapsule = showSubtitleAddress ? (
		<AddressCapsule
			address={subtitleEoa}
			compact={compact}
			className={
				isLight
					? 'border-mkt-outlineVariant/40 bg-white text-mkt-onSurfaceVariant'
					: 'border-white/15 bg-white/10 text-white/80'
			}
		/>
	) : null

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
			<IpfsImg
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
							{showPrimaryTitle ? (
								<p className={`truncate text-xs font-semibold ${primaryTextClass}`}>
									{titleOverride}
								</p>
							) : hasName ? (
								<p className={`truncate text-xs font-semibold ${primaryTextClass}`}>{name}</p>
							) : tag ? (
								<p className={`truncate text-xs font-semibold ${primaryTextClass}`}>@{tag}</p>
							) : !showSubtitleAddress ? (
								<p className={`truncate text-xs font-semibold ${primaryTextClass}`}>—</p>
							) : null}
							{showSubtitleAddress ? (
								<div
									className={`max-w-full ${showPrimaryTitle || hasName || tag ? 'mt-0.5' : ''}`}
								>
									{subtitleAddressCapsule}
								</div>
							) : tag && hasName && !showPrimaryTitle && showSubtitle ? (
								<p className={`truncate text-[10px] font-medium ${tagTextClass}`}>@{tag}</p>
							) : null}
						</>
					)}
				</div>
				{addressCapsule ? <span className="shrink-0">{addressCapsule}</span> : null}
			</div>
		</div>
	)
}

/** Home / header compact pill — avatar + primary line (+ optional subtitle elsewhere). */
export function BeamioCapsuleCompact(props: {
	profile: TerminalProfile
	fallbackAddress?: string | null
	subtitleAddress?: string | null
	primaryTitle?: string | null
	showSubtitle?: boolean
	className?: string
}) {
	const maxWidth =
		props.subtitleAddress || props.primaryTitle
			? 'max-w-[min(220px,46vw)]'
			: 'max-w-[min(180px,42vw)]'
	return (
		<div
			className={`inline-flex ${maxWidth} shrink-0 rounded-full bg-black/[0.06] py-1.5 pl-1.5 pr-2.5 ${props.className ?? ''}`}
		>
			<BeamioCapsule
				profile={props.profile}
				fallbackAddress={props.fallbackAddress}
				subtitleAddress={props.subtitleAddress}
				primaryTitle={props.primaryTitle}
				showSubtitle={props.showSubtitle}
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
