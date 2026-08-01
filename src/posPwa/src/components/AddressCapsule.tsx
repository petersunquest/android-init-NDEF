import { Check, Copy } from 'lucide-react'
import { useState, type MouseEvent } from 'react'
import { shortAddress } from '@/utils/display'

export function AddressCapsule({
	address,
	className = '',
	onClick,
}: {
	address: string
	className?: string
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

	return (
		<button
			type="button"
			onClick={onCopy}
			className={`inline-flex items-center gap-2 rounded-full border border-slate-200 bg-slate-100 px-3 py-1.5 text-xs font-medium text-slate-700 ${className}`}
		>
			<span>{shortAddress(address)}</span>
			{copied ? (
				<Check className="h-3.5 w-3.5 text-emerald-500" aria-hidden />
			) : (
				<Copy className="h-3.5 w-3.5 text-slate-500" aria-hidden />
			)}
		</button>
	)
}
