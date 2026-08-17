export type PosChatMessage = {
	id: string
	sendId?: string
	from: 'me' | 'them'
	text: string
	createdAt: number
	peerAddress: string
	status?: 'sent' | 'delivered'
}

export type PosChatThread = {
	peerAddress: string
	peerTag?: string
	peerName?: string
	peerImage?: string
	lastText: string
	lastAt: number
	unreadCount: number
	messages: PosChatMessage[]
}

export type PosChatStoreSnapshot = {
	version: 1
	threads: PosChatThread[]
	updatedAt: number
}
