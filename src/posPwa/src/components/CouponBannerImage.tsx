import { useIpfsImageSrc } from '@/hooks/useIpfsImageSrc'

/** Banner fill — blurred cover backdrop + full-height foreground (coupon ticket render protocol). */
export function CouponBannerImage({ src }: { src: string }) {
	const displaySrc = useIpfsImageSrc(src)

	if (!displaySrc) return null

	return (
		<div className="absolute inset-0 overflow-hidden">
			<div
				className="absolute inset-0 scale-110 bg-cover bg-center bg-no-repeat blur-xl"
				style={{ backgroundImage: `url("${displaySrc}")` }}
				aria-hidden
			/>
			<img
				src={displaySrc}
				alt=""
				className="absolute left-1/2 top-0 z-[1] h-full w-auto max-w-none -translate-x-1/2 object-contain"
				draggable={false}
			/>
		</div>
	)
}
