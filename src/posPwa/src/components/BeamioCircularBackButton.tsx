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
				'border border-white/40 bg-white/20 text-white/80 backdrop-blur-md',
				'dark:border-white/40 dark:bg-white/20',
				'shadow-[0_1px_3px_rgba(0,0,0,0.12)]',
				'transition active:scale-[0.96] disabled:pointer-events-none disabled:opacity-40',
				'hover:bg-white/30',
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
