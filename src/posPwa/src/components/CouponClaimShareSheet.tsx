import { Check, Copy, Share2, X } from 'lucide-react'
import { useEffect, useState } from 'react'

/** iOS `POSCouponClaimShareSheet` — link + copy/share only (no QR). */
export function CouponClaimShareSheet({
	couponTitle,
	claimUrl,
	onClose,
}: {
	couponTitle: string
	claimUrl: string
	onClose: () => void
}) {
	const [copied, setCopied] = useState(false)

	useEffect(() => {
		const prev = document.body.style.overflow
		document.body.style.overflow = 'hidden'
		return () => {
			document.body.style.overflow = prev
		}
	}, [])

	useEffect(() => {
		if (!copied) return
		const t = setTimeout(() => setCopied(false), 2000)
		return () => clearTimeout(t)
	}, [copied])

	const onCopy = async () => {
		try {
			await navigator.clipboard.writeText(claimUrl)
			setCopied(true)
		} catch {
			/* ignore */
		}
	}

	const onShare = async () => {
		if (navigator.share) {
			try {
				await navigator.share({ title: couponTitle, text: claimUrl, url: claimUrl })
				return
			} catch {
				/* cancelled */
			}
		}
		void onCopy()
	}

	return (
		<div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 p-0 sm:items-center sm:p-4">
			<div
				className="flex max-h-[min(92dvh,640px)] w-full max-w-lg flex-col overflow-hidden rounded-t-[1.25rem] bg-white shadow-xl sm:rounded-[1.25rem]"
				role="dialog"
				aria-labelledby="coupon-claim-sheet-title"
			>
				<div className="flex items-center justify-between border-b border-slate-200/80 px-4 py-3">
					<h2 id="coupon-claim-sheet-title" className="text-base font-semibold text-slate-900">
						Share coupon claim
					</h2>
					<button
						type="button"
						onClick={onClose}
						className="flex h-9 w-9 items-center justify-center rounded-full text-slate-500"
						aria-label="Close"
					>
						<X className="h-5 w-5" />
					</button>
				</div>

				<div className="overflow-y-auto px-4 py-4">
					<div className="flex flex-col items-stretch gap-4">
						<div className="w-full rounded-[14px] bg-slate-100 p-3.5 text-left">
							<p className="text-[17px] font-semibold text-slate-900">{couponTitle}</p>
							<p className="mt-2 text-[11px] font-bold uppercase tracking-wide text-slate-500">
								Claim URL
							</p>
							<p className="mt-1 break-all font-mono text-xs text-slate-600">{claimUrl}</p>
						</div>

						<div className="grid w-full grid-cols-2 gap-2.5">
							<button
								type="button"
								onClick={() => void onCopy()}
								className="inline-flex items-center justify-center gap-2 rounded-xl bg-[#1562f0] px-3 py-2.5 text-sm font-semibold text-white"
							>
								{copied ? (
									<Check className="h-4 w-4" aria-hidden />
								) : (
									<Copy className="h-4 w-4" aria-hidden />
								)}
								{copied ? 'Copied' : 'Copy URL'}
							</button>
							<button
								type="button"
								onClick={() => void onShare()}
								className="inline-flex items-center justify-center gap-2 rounded-xl border border-slate-300 px-3 py-2.5 text-sm font-semibold text-slate-800"
							>
								<Share2 className="h-4 w-4" aria-hidden />
								Share
							</button>
						</div>
					</div>
				</div>
			</div>
		</div>
	)
}
