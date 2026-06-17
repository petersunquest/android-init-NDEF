import { ChevronLeft } from 'lucide-react'
import type { ButtonHTMLAttributes } from 'react'

type BeamioCircularBackButtonProps = {
	onClick: () => void
	ariaLabel?: string
	className?: string
	disabled?: boolean
} & Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'type' | 'onClick' | 'children'>

/**
 * POS PWA circular back — light gray fill + dark chevron (readable on `#f9f9fe` / white shells).
 */
export function BeamioCircularBackButton({
	onClick,
	ariaLabel = 'Back',
	className = '',
	disabled = false,
	...rest
}: BeamioCircularBackButtonProps) {
	return (
		<button
			type="button"
			tabIndex={-1}
			disabled={disabled}
			onClick={onClick}
			aria-label={ariaLabel}
			className={[
				'inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-full',
				'border border-slate-200/90 bg-slate-100/95 text-slate-900',
				'shadow-[0_1px_3px_rgba(0,0,0,0.12)]',
				'transition active:scale-[0.96] hover:bg-slate-200/90',
				'disabled:pointer-events-none disabled:opacity-40',
				className,
			].join(' ')}
			{...rest}
		>
			<ChevronLeft
				className="h-[17px] w-[17px] stroke-[2.5] text-slate-900"
				aria-hidden
			/>
		</button>
	)
}

/** Reserve vertical space for a top-leading floating back control (36px + breathing room). */
export const BEAMIO_CIRCULAR_BACK_ROW_CLASS = 'relative mb-4 min-h-9'
