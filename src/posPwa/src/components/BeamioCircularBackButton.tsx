import { ChevronLeft } from 'lucide-react'
import type { ButtonHTMLAttributes } from 'react'

type BeamioCircularBackButtonProps = {
	onClick: () => void
	ariaLabel?: string
	className?: string
	disabled?: boolean
	/**
	 * `onLight` (default): dark chevron on frosted white — POS sheets / white shells.
	 * `onDark`: white chevron glass — only when floating over dark / photo heroes.
	 */
	variant?: 'onLight' | 'onDark'
} & Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'type' | 'onClick' | 'children'>

/**
 * iOS POS `SheetCircularBackButton` parity — circular chevron with visible shadow.
 * Default `onLight` matches SwiftUI `.primary` chevron + material fill (readable on white POS pages).
 * @see src/CashTrees_iOS/iOS_NDEF/iOS_NDEF/ContentView.swift
 */
export function BeamioCircularBackButton({
	onClick,
	ariaLabel = 'Back',
	className = '',
	disabled = false,
	variant = 'onLight',
	...rest
}: BeamioCircularBackButtonProps) {
	const chrome =
		variant === 'onDark'
			? [
					'border border-white/40 bg-white/20 text-white/80 backdrop-blur-md',
					'dark:border-white/40 dark:bg-white/20',
					'hover:bg-white/30',
					'shadow-[0_2px_10px_rgba(0,0,0,0.28),0_1px_3px_rgba(0,0,0,0.18)]',
				]
			: [
					'border border-black/[0.08] bg-white/90 text-[#2c2f31] backdrop-blur-md',
					'dark:border-white/25 dark:bg-slate-800/90 dark:text-slate-100',
					'hover:bg-white dark:hover:bg-slate-800',
					'shadow-[0_2px_10px_rgba(0,0,0,0.16),0_1px_3px_rgba(0,0,0,0.12)]',
				]

	return (
		<button
			type="button"
			tabIndex={-1}
			disabled={disabled}
			onClick={onClick}
			aria-label={ariaLabel}
			className={[
				'inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-full',
				...chrome,
				'transition active:scale-[0.96] disabled:pointer-events-none disabled:opacity-40',
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
