import { ChevronLeft } from 'lucide-react'
import type { ButtonHTMLAttributes } from 'react'

type BeamioCircularBackButtonProps = {
	onClick: () => void
	ariaLabel?: string
	className?: string
	disabled?: boolean
} & Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'type' | 'onClick' | 'children'>

/**
 * iOS POS `SheetCircularBackButton` parity — frosted circular chevron, floating with shadow.
 * @see src/CashTrees_iOS/iOS_NDEF/iOS_NDEF/ContentView.swift
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
				'border border-black/[0.06] bg-white/80 text-mkt-onSurface backdrop-blur-md',
				'shadow-[0_1px_3px_rgba(0,0,0,0.12)]',
				'transition active:scale-[0.96] disabled:pointer-events-none disabled:opacity-40',
				'hover:bg-white/95 dark:border-white/10 dark:bg-slate-900/75 dark:text-white dark:hover:bg-slate-900/90',
				className,
			].join(' ')}
			{...rest}
		>
			<ChevronLeft className="h-[17px] w-[17px] stroke-[2.5]" aria-hidden />
		</button>
	)
}

/** Reserve vertical space for a top-leading floating back control (36px + breathing room). */
export const BEAMIO_CIRCULAR_BACK_ROW_CLASS = 'relative mb-4 min-h-9'
