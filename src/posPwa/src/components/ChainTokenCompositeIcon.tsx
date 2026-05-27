const USDC_ICON_URL = 'https://assets.coingecko.com/coins/images/6319/small/usdc.png'
const BASE_ICON_URL = 'https://beamio.app/app/static/media/base-logo.275b67e94556e30ce59b.png'
const CADD_ICON_URL = `${import.meta.env.BASE_URL}cadd-icon.png`

function CompositeIcon({
	src,
	alt,
	size = 18,
	badgeSize,
}: {
	src: string
	alt: string
	size?: number
	badgeSize?: number
}) {
	const bs = badgeSize ?? Math.round(size * 0.625)
	return (
		<div
			className="relative shrink-0"
			style={{ width: size, height: size, minWidth: size, minHeight: size }}
		>
			<img src={src} alt={alt} className="block h-full w-full rounded-full object-contain" />
			<img
				src={BASE_ICON_URL}
				alt="Base"
				className="absolute -bottom-0.5 -right-0.5 block rounded-full border border-white bg-white"
				style={{ width: bs, height: bs }}
			/>
		</div>
	)
}

export function UsdcBaseCompositeIcon({
	size = 18,
	badgeSize,
}: {
	size?: number
	badgeSize?: number
}) {
	return <CompositeIcon src={USDC_ICON_URL} alt="USDC" size={size} badgeSize={badgeSize} />
}

export function CaddBaseCompositeIcon({
	size = 18,
	badgeSize,
}: {
	size?: number
	badgeSize?: number
}) {
	return <CompositeIcon src={CADD_ICON_URL} alt="CADD" size={size} badgeSize={badgeSize} />
}
