import type { ImgHTMLAttributes } from 'react'
import { useIpfsImageSrc } from '@/hooks/useIpfsImageSrc'

/** `<img>` with local-first IPFS fragment resolution. */
export function IpfsImg({ src, ...rest }: ImgHTMLAttributes<HTMLImageElement>) {
	const displaySrc = useIpfsImageSrc(typeof src === 'string' ? src : undefined)
	if (!displaySrc) return null
	return <img {...rest} src={displaySrc} />
}
