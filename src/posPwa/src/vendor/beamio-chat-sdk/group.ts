/**
 * Privacy-preserving group-chat V1 state helpers.
 *
 * V1 deliberately does not use OpenPGP multi-recipient encryption. Every
 * member receives an independently encrypted delivery so an entry or mailbox
 * only sees the single recipient key-id needed to route that one envelope.
 */
import { ethers } from 'ethers'

import type {
	GroupAdminProposalV1,
	GroupDeliveryPacketV1,
	GroupMemberV1,
	GroupMessageV1,
	GroupRosterV1,
	GroupTombstoneV1,
} from './types'

export const GROUP_V1_MAX_MEMBERS = 10
export const GROUP_V1_DEFAULT_PADDING_BUCKET_BYTES = 4096
export const GROUP_V1_MAX_BODY_BYTES = 16 * 1024

type SignedGroupObject = { signer: string; signature: string }

function isRecord(value: unknown): value is Record<string, unknown> {
	return Boolean(value) && typeof value === 'object' && !Array.isArray(value)
}

function canonicalize(value: unknown): unknown {
	if (Array.isArray(value)) return value.map(canonicalize)
	if (!isRecord(value)) return value
	const out: Record<string, unknown> = {}
	for (const key of Object.keys(value).sort()) {
		if (key === 'signature') continue
		out[key] = canonicalize(value[key])
	}
	return out
}

/** Stable JSON used for EIP-191 signatures and roster hashes. */
export function canonicalGroupJson(value: unknown): string {
	return JSON.stringify(canonicalize(value))
}

export function groupObjectSigningText(kind: string, value: unknown): string {
	return `CoNET ${kind} v1\n${canonicalGroupJson(value)}`
}

export function normalizeGroupAddress(value: string): string {
	return ethers.getAddress(value).toLowerCase()
}

function normalizedAddresses(values: string[]): string[] {
	return values.map(normalizeGroupAddress)
}

function isUnixMs(value: unknown): value is number {
	return typeof value === 'number' && Number.isSafeInteger(value) && value > 0
}

function assertSignature(kind: string, value: SignedGroupObject): void {
	if (!ethers.isAddress(value.signer) || !value.signature) throw new Error(`invalid ${kind} signer/signature`)
	const recovered = normalizeGroupAddress(ethers.verifyMessage(groupObjectSigningText(kind, value), value.signature))
	if (recovered !== normalizeGroupAddress(value.signer)) throw new Error(`invalid ${kind} signature`)
}

function assertFingerprint(value: string): void {
	if (!/^[0-9a-f]{40}$/i.test(value)) throw new Error('invalid group member PGP fingerprint')
}

function assertMember(member: GroupMemberV1): void {
	normalizeGroupAddress(member.eoa)
	assertFingerprint(member.pgpFingerprint)
	if (!Number.isSafeInteger(member.keyEpoch) || member.keyEpoch < 0) throw new Error('invalid group member keyEpoch')
}

/** Hash of the full signed roster, suitable for chaining and message binding. */
export function groupRosterHash(roster: GroupRosterV1): string {
	return ethers.keccak256(ethers.toUtf8Bytes(canonicalGroupJson(roster)))
}

/**
 * Validate immutable V1 roster syntax and owner authorization. Applying it to
 * local state additionally requires version/prev-hash checks in
 * {@link assertNextGroupRosterV1}.
 */
export function assertGroupRosterV1(roster: GroupRosterV1, maxMembers = GROUP_V1_MAX_MEMBERS): void {
	if (roster.type !== 'conet_group_roster_v1' || !roster.groupId.trim()) throw new Error('invalid group roster type or id')
	if (!Number.isSafeInteger(roster.version) || roster.version < 1) throw new Error('invalid group roster version')
	if (roster.prevRosterHash !== null && !/^0x[0-9a-f]{64}$/i.test(roster.prevRosterHash)) {
		throw new Error('invalid previous roster hash')
	}
	if (!isUnixMs(roster.issuedAt) || !isUnixMs(roster.expiresAt) || roster.expiresAt <= roster.issuedAt) {
		throw new Error('invalid group roster validity window')
	}
	if (!roster.policy?.name.trim() || !ethers.isAddress(roster.policy.owner)) throw new Error('invalid group policy')
	if (!Array.isArray(roster.policy.admins) || !Array.isArray(roster.members)) throw new Error('invalid group roster members')
	if (roster.members.length < 1 || roster.members.length > maxMembers) throw new Error('unsupported group member count')

	const members = roster.members.map((member) => {
		assertMember(member)
		return normalizeGroupAddress(member.eoa)
	})
	if (new Set(members).size !== members.length) throw new Error('duplicate group member')
	const owner = normalizeGroupAddress(roster.policy.owner)
	if (!members.includes(owner)) throw new Error('group owner must remain a member')

	const admins = normalizedAddresses(roster.policy.admins)
	if (new Set(admins).size !== admins.length || admins.some((admin) => !members.includes(admin))) {
		throw new Error('group admin must be a unique member')
	}
	assertSignature('group roster', roster)
	if (normalizeGroupAddress(roster.signer) !== owner) throw new Error('only the group owner may issue a roster')
}

/** Reject skipped versions, forks, and replayed state before replacing local roster state. */
export function assertNextGroupRosterV1(current: GroupRosterV1 | null, next: GroupRosterV1): void {
	assertGroupRosterV1(next)
	if (!current) {
		if (next.version !== 1 || next.prevRosterHash !== null) throw new Error('first roster must be version 1')
		return
	}
	assertGroupRosterV1(current)
	if (next.groupId !== current.groupId) throw new Error('group id mismatch')
	if (normalizeGroupAddress(next.policy.owner) !== normalizeGroupAddress(current.policy.owner)) {
		throw new Error('V1 group owner is immutable')
	}
	if (next.version !== current.version + 1) throw new Error('group roster version must advance by one')
	if (next.prevRosterHash?.toLowerCase() !== groupRosterHash(current).toLowerCase()) {
		throw new Error('group roster predecessor hash mismatch')
	}
}

export async function signGroupObject<T extends SignedGroupObject>(
	wallet: ethers.Wallet,
	kind: string,
	unsigned: Omit<T, 'signer' | 'signature'>,
): Promise<T> {
	const signer = wallet.address
	const draft = { ...unsigned, signer, signature: '' } as T
	const signature = await wallet.signMessage(groupObjectSigningText(kind, draft))
	return { ...draft, signature }
}

export async function createGroupMessageV1(
	wallet: ethers.Wallet,
	input: Omit<GroupMessageV1, 'type' | 'signer' | 'signature'>,
): Promise<GroupMessageV1> {
	if (!input.groupId.trim() || !/^0x[0-9a-f]{64}$/i.test(input.rosterHash)) throw new Error('invalid group message target')
	if (!Number.isSafeInteger(input.seq) || input.seq < 0) throw new Error('invalid group message sequence')
	if (new TextEncoder().encode(input.body).byteLength > GROUP_V1_MAX_BODY_BYTES) {
		throw new Error('group message exceeds the V1 size limit')
	}
	if (!isUnixMs(input.createdAt) || !isUnixMs(input.expiresAt) || input.expiresAt <= input.createdAt) {
		throw new Error('invalid group message validity window')
	}
	return signGroupObject<GroupMessageV1>(wallet, 'group message', {
		type: 'conet_group_message_v1',
		...input,
	})
}

export function assertGroupMessageV1(
	message: GroupMessageV1,
	roster: GroupRosterV1,
	tombstone: GroupTombstoneV1 | null,
	now = Date.now(),
): void {
	if (message.type !== 'conet_group_message_v1' || message.groupId !== roster.groupId) throw new Error('group message target mismatch')
	if (message.rosterHash.toLowerCase() !== groupRosterHash(roster).toLowerCase()) throw new Error('stale group roster hash')
	if (message.expiresAt < now || message.createdAt > now + 60_000 || message.expiresAt <= message.createdAt) {
		throw new Error('expired or invalid group message')
	}
	if (!Number.isSafeInteger(message.seq) || message.seq < 0 || !message.sendId.trim()) throw new Error('invalid group message sequence')
	if (new TextEncoder().encode(message.body).byteLength > GROUP_V1_MAX_BODY_BYTES) throw new Error('group message exceeds the V1 size limit')
	assertSignature('group message', message)
	const sender = normalizeGroupAddress(message.signer)
	if (!roster.members.some((member) => normalizeGroupAddress(member.eoa) === sender)) throw new Error('group sender is not a member')
	// A removed recipient may still receive an offline copy of an old message.
	// Only messages created at/after its owner-signed removal notice are rejected.
	if (tombstone && message.createdAt >= tombstone.issuedAt) throw new Error('group member has been removed')
}

export function assertGroupAdminProposalV1(proposal: GroupAdminProposalV1, roster: GroupRosterV1, now = Date.now()): void {
	if (proposal.type !== 'conet_group_admin_proposal_v1' || proposal.groupId !== roster.groupId) throw new Error('invalid group proposal target')
	if (proposal.rosterHash.toLowerCase() !== groupRosterHash(roster).toLowerCase()) throw new Error('stale group proposal roster')
	if (!proposal.proposalId || proposal.expiresAt < now || proposal.expiresAt <= proposal.createdAt) throw new Error('expired or invalid group proposal')
	assertSignature('group admin proposal', proposal)
	const signer = normalizeGroupAddress(proposal.signer)
	const allowed = [roster.policy.owner, ...roster.policy.admins].map(normalizeGroupAddress)
	if (!allowed.includes(signer)) throw new Error('group proposal signer is not an admin')
}

export function assertGroupTombstoneV1(tombstone: GroupTombstoneV1, owner: string): void {
	if (tombstone.type !== 'conet_group_tombstone_v1' || !tombstone.groupId.trim()) throw new Error('invalid group tombstone')
	if (!Number.isSafeInteger(tombstone.removedAtVersion) || tombstone.removedAtVersion < 1) throw new Error('invalid group tombstone version')
	if (!/^0x[0-9a-f]{64}$/i.test(tombstone.previousRosterHash) || !isUnixMs(tombstone.issuedAt)) {
		throw new Error('invalid group tombstone fields')
	}
	assertSignature('group tombstone', tombstone)
	if (normalizeGroupAddress(tombstone.signer) !== normalizeGroupAddress(owner)) throw new Error('only owner may issue a tombstone')
}

/**
 * Pad a per-recipient plaintext to a fixed byte bucket before PGP encryption.
 * Padding is random printable hex so JSON byte length is deterministic.
 */
export function createPaddedGroupDeliveryPacket(
	message: GroupMessageV1,
	bucketBytes = GROUP_V1_DEFAULT_PADDING_BUCKET_BYTES,
): GroupDeliveryPacketV1 {
	if (!Number.isSafeInteger(bucketBytes) || bucketBytes < 256) throw new Error('invalid group padding bucket')
	const base: GroupDeliveryPacketV1 = { type: 'conet_group_delivery_v1', message, padding: '' }
	const byteLength = (value: unknown) => new TextEncoder().encode(JSON.stringify(value)).byteLength
	const baseBytes = byteLength(base)
	const target = Math.ceil(baseBytes / bucketBytes) * bucketBytes
	const paddingBytes = target - baseBytes
	// Hex is ASCII, so its string length exactly matches the number of bytes added.
	const padding = ethers.hexlify(ethers.randomBytes(Math.ceil(paddingBytes / 2))).slice(2, 2 + paddingBytes)
	return { ...base, padding }
}

/** Validate the decrypted per-recipient wrapper before accepting its message. */
export function assertGroupDeliveryPacketV1(packet: GroupDeliveryPacketV1): void {
	if (packet.type !== 'conet_group_delivery_v1' || typeof packet.padding !== 'string' || !/^[0-9a-f]*$/i.test(packet.padding)) {
		throw new Error('invalid group delivery packet')
	}
	if (new TextEncoder().encode(JSON.stringify(packet)).byteLength > GROUP_V1_MAX_BODY_BYTES + GROUP_V1_DEFAULT_PADDING_BUCKET_BYTES * 2) {
		throw new Error('group delivery packet exceeds the V1 size limit')
	}
}

/**
 * Minimal recipient-local V1 group state. Hosts persist this state in their
 * encrypted chat store; this SDK keeps no roster/roster-history database.
 * A tombstone intentionally replaces the roster so a removed client cannot
 * continue treating its old local member list as current.
 */
export class GroupStateV1 {
	private roster: GroupRosterV1 | null = null
	private tombstone: GroupTombstoneV1 | null = null
	private readonly seenSendIds = new Set<string>()

	get activeRoster(): GroupRosterV1 | null {
		return this.tombstone ? null : this.roster
	}

	get removalTombstone(): GroupTombstoneV1 | null {
		return this.tombstone
	}

	applyRoster(next: GroupRosterV1): void {
		if (this.tombstone) throw new Error('removed group member must not accept a successor roster')
		assertNextGroupRosterV1(this.roster, next)
		this.roster = next
	}

	applyTombstone(next: GroupTombstoneV1): void {
		if (!this.roster) throw new Error('cannot apply a group tombstone without its predecessor roster')
		assertGroupTombstoneV1(next, this.roster.policy.owner)
		if (next.groupId !== this.roster.groupId || next.previousRosterHash.toLowerCase() !== groupRosterHash(this.roster).toLowerCase()) {
			throw new Error('group tombstone predecessor mismatch')
		}
		if (next.removedAtVersion !== this.roster.version + 1) throw new Error('invalid group tombstone version')
		this.tombstone = next
		this.seenSendIds.clear()
	}

	acceptMessage(message: GroupMessageV1, now = Date.now()): void {
		if (!this.roster) throw new Error('missing group roster')
		assertGroupMessageV1(message, this.roster, this.tombstone, now)
		const replayKey = `${message.groupId}:${normalizeGroupAddress(message.signer)}:${message.seq}:${message.sendId}`
		if (this.seenSendIds.has(replayKey)) throw new Error('duplicate group message')
		this.seenSendIds.add(replayKey)
	}

	acceptDelivery(packet: GroupDeliveryPacketV1, now = Date.now()): GroupMessageV1 {
		assertGroupDeliveryPacketV1(packet)
		this.acceptMessage(packet.message, now)
		return packet.message
	}
}
