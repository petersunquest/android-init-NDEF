import QRCode from 'qrcode'
import { useEffect, useState } from 'react'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'

export function TopupUsdcQrPanel({
	deepLink,
	hint,
	progressLabel,
	onCancel,
}: {
	deepLink: string
	hint: string
	progressLabel?: string
	onCancel: () => void
}) {
	const [qrDataUrl, setQrDataUrl] = useState<string | null>(null)

	useEffect(() => {
		let cancelled = false
		void QRCode.toDataURL(deepLink, { margin: 1, width: 240 }).then((url) => {
			if (!cancelled) setQrDataUrl(url)
		})
		return () => {
			cancelled = true
		}
	}, [deepLink])

	return (
		<PosScreenShell bg="bg-white">
			<div className="relative flex min-h-0 flex-1 flex-col">
				<BeamioCircularBackButton
					onClick={onCancel}
					className="absolute left-2 top-[max(0.375rem,env(safe-area-inset-top))] z-10"
				/>
				<PosScreenMain className="items-center justify-center px-5 pt-14 text-center">
					<p className="text-base font-bold text-slate-900">Customer Payment QR</p>
					<p className="mt-2 max-w-sm text-sm text-slate-600">{hint}</p>
					{progressLabel ? (
						<p className="mt-3 text-sm font-medium text-brand-blue">{progressLabel}</p>
					) : null}
					<div className="mt-6 rounded-2xl bg-white p-4 shadow-md ring-1 ring-slate-200">
						{qrDataUrl ? (
							<img src={qrDataUrl} alt="Payment QR code" className="h-60 w-60" />
						) : (
							<div className="flex h-60 w-60 items-center justify-center text-sm text-slate-500">
								Generating QR…
							</div>
						)}
					</div>
				</PosScreenMain>
			</div>
		</PosScreenShell>
	)
}
