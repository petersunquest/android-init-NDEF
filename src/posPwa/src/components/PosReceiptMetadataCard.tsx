import { BadgeCheck, Shield } from 'lucide-react'
import { baseScanTxUrl, formatPosReceiptDate, shortTxHash } from '@/utils/posReceiptUtils'

const OUTLINE = '#737685'
const ON_SURFACE = '#1a1c1f'
const LINK_BLUE = '#003792'

function MetaRow({ left, right }: { left: string; right: string }) {
	return (
		<div className="flex items-start justify-between gap-3 py-1.5">
			<span
				className="text-[10px] font-bold uppercase tracking-wide"
				style={{ color: OUTLINE }}
			>
				{left}
			</span>
			<span className="font-mono text-[11px] font-medium text-right" style={{ color: ON_SURFACE }}>
				{right}
			</span>
		</div>
	)
}

export function PosReceiptMetadataCard({
	memberNo,
	txHash,
	settlementViaQr,
	dateStr = formatPosReceiptDate(),
	variant = 'charge',
}: {
	memberNo: string
	txHash?: string
	settlementViaQr?: boolean
	dateStr?: string
	/** Top-up uses simpler Date row; charge uses Date & Time uppercase labels. */
	variant?: 'topup' | 'charge'
}) {
	const settlementLabel = settlementViaQr ? 'App Validator' : 'NTAG 424 DNA'
	const tx = txHash?.trim() ?? ''
	const txUrl = tx ? baseScanTxUrl(tx) : null

	if (variant === 'topup') {
		return (
			<div className="rounded-2xl border border-black/5 bg-white px-4 py-2">
				<div className="flex items-center justify-between gap-3 py-1.5">
					<span className="text-[13px]" style={{ color: '#86868b' }}>
						Date
					</span>
					<span className="text-[13px] font-medium" style={{ color: ON_SURFACE }}>
						{dateStr}
					</span>
				</div>
				<div className="h-px bg-black/6" />
				<div className="flex justify-end py-1.5">
					<span className="text-[13px] font-medium" style={{ color: ON_SURFACE }}>
						{memberNo}
					</span>
				</div>
				{tx ? (
					<>
						<div className="h-px bg-black/6" />
						<div className="flex items-center justify-between gap-3 py-1.5">
							<span className="text-[13px]" style={{ color: '#86868b' }}>
								TX Hash
							</span>
							{txUrl ? (
								<a
									href={txUrl}
									target="_blank"
									rel="noopener noreferrer"
									className="font-mono text-[13px] font-medium"
									style={{ color: '#1562f0' }}
								>
									{shortTxHash(tx)}
								</a>
							) : (
								<span className="font-mono text-[13px] font-medium">{shortTxHash(tx)}</span>
							)}
						</div>
					</>
				) : null}
				<div className="h-px bg-black/6" />
				<div className="flex items-center justify-between gap-3 py-1.5">
					<span className="text-[13px]" style={{ color: '#86868b' }}>
						Settlement
					</span>
					<span className="flex items-center gap-1 text-[13px] font-medium text-emerald-600">
						<Shield className="h-3 w-3" aria-hidden />
						{settlementLabel}
					</span>
				</div>
			</div>
		)
	}

	return (
		<div className="px-2 pt-1">
			<MetaRow left="Date & Time" right={dateStr} />
			<div className="flex justify-end py-1">
				<span className="font-mono text-[11px] font-medium" style={{ color: ON_SURFACE }}>
					{memberNo}
				</span>
			</div>
			<div className="flex items-center justify-between gap-3 py-1">
				<span
					className="text-[10px] font-bold uppercase tracking-wide"
					style={{ color: OUTLINE }}
				>
					TX Hash
				</span>
				{tx && txUrl ? (
					<a
						href={txUrl}
						target="_blank"
						rel="noopener noreferrer"
						className="rounded-full px-2 py-1 font-mono text-[10px] font-medium"
						style={{ color: LINK_BLUE, backgroundColor: 'rgba(0,55,146,0.06)' }}
					>
						{shortTxHash(tx)}
					</a>
				) : (
					<span className="font-mono text-[11px] font-medium" style={{ color: ON_SURFACE }}>
						{tx ? shortTxHash(tx) : '—'}
					</span>
				)}
			</div>
			<div className="flex items-center justify-between gap-3 py-1">
				<span
					className="text-[10px] font-bold uppercase tracking-wide"
					style={{ color: OUTLINE }}
				>
					Settlement
				</span>
				<span className="flex items-center gap-1 text-[11px] font-medium" style={{ color: ON_SURFACE }}>
					{settlementLabel}
					<BadgeCheck className="h-3.5 w-3.5 text-[#0052d2]" aria-hidden />
				</span>
			</div>
		</div>
	)
}
