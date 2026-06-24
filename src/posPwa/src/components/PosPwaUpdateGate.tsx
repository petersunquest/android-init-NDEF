import { useCallback, useEffect, useRef, useState } from 'react'
import { useRegisterSW } from 'virtual:pwa-register/react'
import { Loader2, RefreshCw, Sparkles } from 'lucide-react'

/**
 * POS PWA Service Worker 更新门闸。
 *
 * - registerType: 'prompt'（vite.config.ts）→ Workbox 预缓存全部产物，打开时本地缓存秒开，无黑屏。
 * - 运行中每 10 分钟（setTimeout 链，遵守 beamio-no-setinterval）调用 registration.update() 后台检测新版。
 * - 检测到新版静默后台下载（SW install / waiting），完成后 needRefresh=true → 显示「有更新版」。
 * - POS 用户点击「Update now」→ updateServiceWorker(true)（skipWaiting + 刷新）启用新版 PWA。
 */
const UPDATE_CHECK_INTERVAL_MS = 10 * 60 * 1000

export function PosPwaUpdateGate() {
	const registrationRef = useRef<ServiceWorkerRegistration | undefined>(undefined)
	const updateTimerRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
	const [applying, setApplying] = useState(false)
	const [dismissed, setDismissed] = useState(false)

	const {
		needRefresh: [needRefresh],
		updateServiceWorker,
	} = useRegisterSW({
		onRegisteredSW(_swUrl, registration) {
			registrationRef.current = registration ?? undefined
			scheduleUpdateCheck()
		},
		onRegisterError(error) {
			// SW 不可用（如部分 WebView）时静默降级：仍走网络加载，不阻断 POS。
			console.warn('[posPwa] service worker register error', error)
		},
	})

	const runUpdateCheck = useCallback(() => {
		const registration = registrationRef.current
		if (!registration) return
		// update() 按 SW 规范绕过 HTTP 缓存重新拉取 sw.js，做字节比对决定是否安装新版。
		registration.update().catch(() => {
			/* 离线/瞬时失败：忽略，下一拍重试 */
		})
	}, [])

	const scheduleUpdateCheck = useCallback(() => {
		if (updateTimerRef.current !== undefined) clearTimeout(updateTimerRef.current)
		updateTimerRef.current = setTimeout(() => {
			runUpdateCheck()
			// 串行链：本轮检查后再排下一轮，避免重叠（beamio-interval-daemon-no-overlap）。
			scheduleUpdateCheck()
		}, UPDATE_CHECK_INTERVAL_MS)
	}, [runUpdateCheck])

	// 回到前台时也补一次检查（POS 终端常长时间挂起）。
	useEffect(() => {
		const onVisible = () => {
			if (document.visibilityState === 'visible') runUpdateCheck()
		}
		document.addEventListener('visibilitychange', onVisible)
		return () => {
			document.removeEventListener('visibilitychange', onVisible)
			if (updateTimerRef.current !== undefined) clearTimeout(updateTimerRef.current)
		}
	}, [runUpdateCheck])

	const handleApply = useCallback(() => {
		if (applying) return
		setApplying(true)
		// skipWaiting + 由 hook 触发 controllerchange 自动 reload 到新版。
		void updateServiceWorker(true)
	}, [applying, updateServiceWorker])

	if (!needRefresh || dismissed) return null

	return (
		<div
			className="pointer-events-none fixed inset-x-0 bottom-0 z-[1000] flex justify-center px-4"
			style={{ paddingBottom: 'max(1rem, env(safe-area-inset-bottom, 0px))' }}
			role="status"
			aria-live="polite"
		>
			<div className="pointer-events-auto flex w-full max-w-md items-center gap-3 rounded-2xl border border-white/12 bg-[#10162b] px-4 py-3 shadow-[0_12px_40px_rgba(0,0,0,0.5)]">
				<div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-emerald-500/15 text-emerald-400">
					<Sparkles className="h-5 w-5" strokeWidth={2.25} aria-hidden />
				</div>
				<div className="min-w-0 flex-1">
					<p className="truncate text-sm font-semibold text-white">New version available</p>
					<p className="truncate text-xs text-white/55">
						Update downloaded — tap to apply.
					</p>
				</div>
				<button
					type="button"
					onClick={() => setDismissed(true)}
					disabled={applying}
					className="shrink-0 rounded-full px-3 py-2 text-xs font-medium text-white/55 transition hover:text-white/80 disabled:opacity-40"
				>
					Later
				</button>
				<button
					type="button"
					onClick={handleApply}
					disabled={applying}
					className="inline-flex shrink-0 items-center gap-1.5 rounded-full bg-emerald-500 px-4 py-2 text-xs font-semibold text-[#04130c] transition active:scale-[0.97] hover:bg-emerald-400 disabled:cursor-not-allowed disabled:opacity-70"
				>
					{applying ? (
						<>
							<Loader2 className="h-4 w-4 animate-spin" strokeWidth={2.5} aria-hidden />
							Updating
						</>
					) : (
						<>
							<RefreshCw className="h-4 w-4" strokeWidth={2.5} aria-hidden />
							Update now
						</>
					)}
				</button>
			</div>
		</div>
	)
}
