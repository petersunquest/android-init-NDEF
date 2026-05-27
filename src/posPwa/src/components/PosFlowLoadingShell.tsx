import { Loader2 } from 'lucide-react'
import { PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'

/** Full-screen loading for Home action flows — see `beamio-pos-pwa-home-action-flow.mdc`. */
export function PosFlowLoadingShell({
	title,
	subtitle,
	bg = 'bg-white',
}: {
	title: string
	subtitle: string
	bg?: string
}) {
	return (
		<PosScreenShell bg={bg}>
			<PosScreenMain className="items-center justify-center px-5">
				<Loader2 className="h-12 w-12 animate-spin text-brand-blue" aria-hidden />
				<p className="mt-6 text-base font-bold text-mkt-onSurface">{title}</p>
				<p className="mt-2 max-w-xs text-center text-sm text-mkt-onSurfaceVariant">{subtitle}</p>
			</PosScreenMain>
		</PosScreenShell>
	)
}
