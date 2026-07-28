import {
	createContext,
	useCallback,
	useContext,
	useEffect,
	type ReactNode,
} from 'react'
import { usePosSession } from '@/providers/PosSessionProvider'
import {
	getLocalIpfsImageRecord,
	isIpfsFragmentImageUrl,
	parseFragmentHashFromUrl,
	putLocalIpfsImageFromDataUrl,
	resolveIpfsImageUrlToObjectUrl,
	warmIpfsImageUrls,
} from '@/utils/ipfsImageLibrary'

export type IpfsImageLibraryContextValue = {
	resolveObjectUrl: (url: string) => Promise<string>
	warmUrls: (urls: Array<string | undefined | null>) => void
	cacheUploadDataUrl: (hash: string, dataUrl: string) => void
	hasLocalHash: (hashOrUrl: string) => Promise<boolean>
}

const defaultValue: IpfsImageLibraryContextValue = {
	resolveObjectUrl: resolveIpfsImageUrlToObjectUrl,
	warmUrls: warmIpfsImageUrls,
	cacheUploadDataUrl: (hash, dataUrl) => {
		void putLocalIpfsImageFromDataUrl(hash, dataUrl).catch(() => {})
	},
	hasLocalHash: async (hashOrUrl) => {
		const hash = parseFragmentHashFromUrl(hashOrUrl) ?? hashOrUrl
		const rec = await getLocalIpfsImageRecord(hash).catch(() => null)
		return !!rec
	},
}

const IpfsImageLibraryContext = createContext<IpfsImageLibraryContextValue>(defaultValue)

export function useIpfsImageLibrary(): IpfsImageLibraryContextValue {
	return useContext(IpfsImageLibraryContext)
}

export function IpfsImageLibraryProvider({ children }: { children: ReactNode }) {
	const {
		adminProfile,
		parentProfile,
		terminalProfile,
		activeCoupons,
	} = usePosSession()

	const resolveObjectUrl = useCallback(
		(url: string) => resolveIpfsImageUrlToObjectUrl(url),
		[],
	)

	const warmUrls = useCallback((urls: Array<string | undefined | null>) => {
		warmIpfsImageUrls(urls)
	}, [])

	const cacheUploadDataUrl = useCallback((hash: string, dataUrl: string) => {
		void putLocalIpfsImageFromDataUrl(hash, dataUrl).catch(() => {})
	}, [])

	const hasLocalHash = useCallback(async (hashOrUrl: string) => {
		const hash = parseFragmentHashFromUrl(hashOrUrl) ?? hashOrUrl
		const rec = await getLocalIpfsImageRecord(hash).catch(() => null)
		return !!rec
	}, [])

	useEffect(() => {
		const urls: string[] = []
		for (const p of [adminProfile, parentProfile, terminalProfile]) {
			const img = p?.image
			if (img && isIpfsFragmentImageUrl(img)) urls.push(img)
		}
		for (const c of activeCoupons ?? []) {
			if (c.iconUrl && isIpfsFragmentImageUrl(c.iconUrl)) urls.push(c.iconUrl)
			if (c.backgroundImageUrl && isIpfsFragmentImageUrl(c.backgroundImageUrl)) {
				urls.push(c.backgroundImageUrl)
			}
		}
		if (urls.length) warmIpfsImageUrls(urls)
	}, [adminProfile, parentProfile, terminalProfile, activeCoupons])

	const value: IpfsImageLibraryContextValue = {
		resolveObjectUrl,
		warmUrls,
		cacheUploadDataUrl,
		hasLocalHash,
	}

	return (
		<IpfsImageLibraryContext.Provider value={value}>
			{children}
		</IpfsImageLibraryContext.Provider>
	)
}
