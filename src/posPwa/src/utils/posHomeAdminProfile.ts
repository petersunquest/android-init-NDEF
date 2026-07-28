import { searchUsers } from '@/api/beamioApi'
import { profileBeamioTag, profileDisplayName } from '@/utils/display'
import type { CardAdminInfoResponse, TerminalProfile } from '@/types/pos'

function profileHasIdentity(profile: TerminalProfile): boolean {
	return profileBeamioTag(profile).length > 0 || profileDisplayName(profile).length > 0
}

/** Lowercase address / tag for `/api/search-users` (iOS parity). */
function normalizeSearchKeyword(raw: string): string {
	return raw.trim().toLowerCase()
}

async function searchUsersFirst(keyword: string): Promise<TerminalProfile | null | undefined> {
	const kw = normalizeSearchKeyword(keyword)
	if (kw.length < 2) return null
	const rows = await searchUsers(kw)
	if (rows === null) return undefined
	const hit = rows.find((row) => profileHasIdentity(row))
	return hit ?? null
}

/**
 * iOS/Android home header admin capsule: `upperAdmin` → search-users only.
 * `undefined` = untrusted fetch — caller must keep prior cache.
 */
export async function resolveAdminProfileFromCardAdminInfo(
	info: CardAdminInfoResponse | null | undefined,
): Promise<TerminalProfile | null | undefined> {
	if (!info?.ok) return undefined

	const upper = info.upperAdmin?.trim()
	if (upper) {
		return searchUsersFirst(upper)
	}

	const owner = info.owner?.trim()
	if (owner) {
		return searchUsersFirst(owner)
	}

	return null
}

/** Workspace parent @tag from onboarding — fallback when chain admin lookup misses. */
export async function resolveParentWorkspaceProfile(
	parentBeamioTag: string,
): Promise<TerminalProfile | null | undefined> {
	const tag = parentBeamioTag.trim().replace(/^@+/, '')
	if (tag.length < 2) return null
	const byTag = await searchUsersFirst(tag)
	if (byTag !== undefined && byTag !== null) return byTag
	return searchUsersFirst(`@${tag}`)
}

export function pickHomeAdminCapsuleProfile(
	adminProfile: TerminalProfile | null,
	parentProfile: TerminalProfile | null,
	parentBeamioTag: string,
): TerminalProfile | null {
	if (adminProfile && profileHasIdentity(adminProfile)) return adminProfile
	if (parentProfile && profileHasIdentity(parentProfile)) return parentProfile
	const tag = parentBeamioTag.trim().replace(/^@+/, '')
	if (tag.length >= 3) {
		return { accountName: tag, username: tag }
	}
	return null
}
