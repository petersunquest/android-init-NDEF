import { Link } from 'react-router-dom'

export const VERRA_LOGO_URL = '/verra-logo.png'

type BrandLogoProps = {
	/** `null` = not wrapped in Link */
	to?: string | null
	className?: string
	imgClassName?: string
	showWordmark?: boolean
	wordmark?: string
	wordmarkClassName?: string
	/** Lighten mark on dark backgrounds (single-color mark → reads as white) */
	logoOnDark?: boolean
}

export function BrandLogo({
	to = '/',
	className = 'flex items-center gap-2',
	imgClassName = 'h-8 w-8 shrink-0 object-contain',
	showWordmark = true,
	wordmark = 'Verra',
	wordmarkClassName = '',
	logoOnDark = false,
}: BrandLogoProps) {
	const markClasses = [imgClassName, logoOnDark ? 'brightness-0 invert' : '']
		.filter(Boolean)
		.join(' ')

	const inner = (
		<>
			<img src={VERRA_LOGO_URL} alt="" width={512} height={512} className={markClasses} />
			{showWordmark ? <span className={wordmarkClassName}>{wordmark}</span> : null}
		</>
	)

	if (to != null) {
		return (
			<Link to={to} className={className}>
				{inner}
			</Link>
		)
	}

	return <div className={className}>{inner}</div>
}
