import { useEffect, useState } from 'react'
import {
	isIpfsFragmentImageUrl,
	resolveIpfsImageUrlToObjectUrl,
} from '@/utils/ipfsImageLibrary'

/** Local-first IPFS fragment URL → display src (blob URL for cached fragments). */
export function useIpfsImageSrc(src?: string): string {
	const [imgSrc, setImgSrc] = useState(() => {
		const s = String(src ?? '').trim()
		if (!s) return ''
		if (s.startsWith('data:image/') || s.startsWith('blob:')) return s
		if (!isIpfsFragmentImageUrl(s)) return s
		return ''
	})

	useEffect(() => {
		const s = String(src ?? '').trim()
		if (!s) {
			setImgSrc('')
			return
		}

		if (s.startsWith('data:image/') || s.startsWith('blob:')) {
			setImgSrc(s)
			return
		}

		if (!isIpfsFragmentImageUrl(s)) {
			setImgSrc(s)
			return
		}

		let alive = true
		let objUrl = ''

		void (async () => {
			try {
				objUrl = await resolveIpfsImageUrlToObjectUrl(s)
				if (alive) setImgSrc(objUrl)
			} catch {
				if (alive) setImgSrc(s)
			}
		})()

		return () => {
			alive = false
			if (objUrl.startsWith('blob:')) URL.revokeObjectURL(objUrl)
		}
	}, [src])

	return imgSrc
}
