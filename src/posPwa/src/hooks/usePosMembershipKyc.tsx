import { useRef, useState } from 'react'
import { BecomeMemberSheet } from '@/components/BecomeMemberSheet'
import { getPosPrivateKeyHex } from '@/wallet/getPosPrivateKeyHex'
import {
	loadMembershipKycPolicy,
	membershipIssueNeedsKyc,
	type MembershipKycFormPolicy,
} from '@/utils/membershipKyc'

export function usePosMembershipKyc() {
	const done = useRef<((ok: boolean) => void) | null>(null)
	const [sheet, setSheet] = useState<null | {
		policy: MembershipKycFormPolicy
		card: string
		key: string
		wallet: string
	}>(null)

	const ensure = async (cardAddress: string, customerWallet?: string) => {
		const wallet = customerWallet?.trim() ?? ''
		if (!cardAddress || !wallet) return true
		const needed = await membershipIssueNeedsKyc(cardAddress, wallet).catch(() => false)
		if (!needed) return true
		const policy = await loadMembershipKycPolicy(cardAddress).catch(() => null)
		const key = await getPosPrivateKeyHex()
		if (!policy || !key) return false
		return new Promise<boolean>((resolve) => {
			done.current = resolve
			setSheet({ policy, card: cardAddress, key, wallet })
		})
	}

	const node = sheet ? (
		<BecomeMemberSheet
			policy={sheet.policy}
			cardAddress={sheet.card}
			privateKey={sheet.key}
			subjectWallet={sheet.wallet}
			signerKind="admin"
			onClose={() => {
				done.current?.(false)
				done.current = null
				setSheet(null)
			}}
			onLinked={() => {
				done.current?.(true)
				done.current = null
				setSheet(null)
			}}
		/>
	) : null

	return { ensure, node }
}
