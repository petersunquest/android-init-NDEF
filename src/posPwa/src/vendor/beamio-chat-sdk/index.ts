/**
 * @conet.project/chat-sdk — public entry (main thread).
 *
 * Gossip messaging with all openpgp encrypt/decrypt + ethers signing running in a
 * Web Worker (zero main-thread crypto → no UI freeze) + encrypted fragmented IPFS
 * history. UI-agnostic; reusable across SilentPassUI / bizSite / Alliance / POS.
 *
 * Usage (host owns worker creation so the SDK stays bundler-agnostic):
 * ```ts
 * import { createBeamioChatClient } from '@conet.project/chat-sdk'
 * const client = createBeamioChatClient(config, {
 *   workerFactory: () => new Worker(new URL('@conet.project/chat-sdk/worker', import.meta.url), { type: 'module' }),
 * })
 * await client.init()
 * client.on('message', (env) => addNewMessage(env.line)) // host serial queue + checkSign
 * ```
 */

export { createBeamioChatClient } from './client'
export type { BeamioChatClientOptions } from './client'

export {
	armorToString,
	buildPostBody,
	encryptRouteCommand,
	wrapArmorToEntryRoute,
	wrapArmorToMailboxWork,
	wrapWouldHitSameNode,
} from './envelope'
export type { MailboxWorkEnvelope } from './envelope'
export { postUrl } from './nodes'
export {
	GROUP_V1_DEFAULT_PADDING_BUCKET_BYTES,
	GROUP_V1_MAX_BODY_BYTES,
	GROUP_V1_MAX_MEMBERS,
	GroupStateV1,
	assertGroupAdminProposalV1,
	assertGroupDeliveryPacketV1,
	assertGroupRosterV1,
	assertGroupMessageV1,
	assertGroupTombstoneV1,
	assertNextGroupRosterV1,
	canonicalGroupJson,
	createGroupMessageV1,
	createPaddedGroupDeliveryPacket,
	groupRosterHash,
	normalizeGroupAddress,
	signGroupObject,
} from './group'

export type {
	BeamioChatClient,
	BeamioChatConfig,
	BeamioChatHistory,
	ChatEventListener,
	ChatEventMap,
	ChatEventName,
	ChatIdentity,
	ChatLogEvent,
	ChatRoute,
	ChatRuntimeOptions,
	ChatStatus,
	DeliveryReceiptEvent,
	GroupAdminProposalV1,
	GroupDeliveryPacketV1,
	GroupMemberV1,
	GroupMessageV1,
	GroupPolicyV1,
	GroupRosterV1,
	GroupSendRequest,
	GroupSendResult,
	GroupTombstoneV1,
	HistoryBufferEvent,
	HistoryEntry,
	HistoryLoadOptions,
	InboundEnvelope,
	NodeInfo,
	PersistenceAdapter,
	PresenceEvent,
	SendMessageOptions,
	StatusEvent,
	Unsubscribe,
	VoiceCallSignal,
	VoiceCallSignalType,
	VoiceFrame,
} from './types'
export {
	VOICE_MAX_FRAME_B64,
	VOICE_FRAME_TIMESTAMP_SKEW_SEC,
	VOICE_CALL_MAX_DURATION_MS,
} from './types'
