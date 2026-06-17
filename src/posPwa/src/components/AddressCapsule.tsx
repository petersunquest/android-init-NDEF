import { Check, Copy } from 'lucide-react'
import { useState, type MouseEvent } from 'react'
import { shortAddress } from '@/utils/display'

export function AddressCapsule({
	address,
	className = '',
	compact = false,
	onClick,
}: {
	address: string
	className?: string
	compact?: boolean
	onClick?: (event: MouseEvent<HTMLButtonElement>) => void
}) {
	const [copied, setCopied] = useState(false)

	async function onCopy(event: MouseEvent<HTMLButtonElement>) {
		event.stopPropagation()
		onClick?.(event)
		try {
			await navigator.clipboard.writeText(address)
			setCopied(true)
			window.setTimeout(() => setCopied(false), 2000)
		} catch {
			/* ignore */
		}
	}

	const sizeClass = compact
		? 'gap-1 px-2 py-0.5 text-[10px] font-medium'
		: 'gap-2 px-3 py-1.5 text-xs font-medium'
	const iconClass = compact ? 'h-3 w-3' : 'h-3.5 w-3.5'

	return (
		<button
			type="button"
			onClick={onCopy}
			className={`inline-flex max-w-full items-center rounded-full border border-slate-200 bg-slate-100 text-slate-700 ${sizeClass} ${className}`}
		>
			<span className="truncate">{shortAddress(address)}</span>
			{copied ? (
				<Check className={`${iconClass} shrink-0 text-emerald-500`} aria-hidden />
			) : (
				<Copy className={`${iconClass} shrink-0 text-slate-500`} aria-hidden />
			)}
		</button>
	)
}
