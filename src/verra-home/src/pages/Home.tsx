const AVATAR_IMAGE =
	'https://lh3.googleusercontent.com/aida-public/AB6AXuDgrKqgkovyf9vMk-CmZ_kTzqI5HEMjqn_XHND9aeRvk56wzYhmOywBMBY12z7UajvV0_pSq5z11uaXxyN4EWF70SEueaG4AZKSlXwQT18NZHCb5OQVpeeem6rId3sqG-TXJ3l1esb3uYftCK1Ot2Y2s04ggDlyWSU5I2XD9RXXItPOzq56Vu3p6iaJpDUZgdngA0Kqvdpx6uKBLRNJKQqcW2-xTuf1F2k5fxb0riVfor6K2kh_8VsiqpEmqsiyLS3kyAm55yKmUVwDv'

const BRAND_STARBUCKS =
	'https://lh3.googleusercontent.com/aida-public/AB6AXuDm-gTDYWdORP6GeFHbNzrLEwdKW8Nt8OwSgLUS2tiaY40wgmngHOWy2SlH358bOgaXZtxXW2nIhAJJ5ZaU5g0E9DJjN16rkAFhZJ_mQUg2CEsG-g7iDtG72FnMbXHwhbs-QNRCPVAFo0kDc1adWAUfI0XVI7HvTO3CDiMxhM6CkP1eAdx7rU-2gMt9ZPWIkdNtPB1K5bbspc3wEJlWbHztiI6cDbvvkdzN4kk8It0WOnzEQpdxI7IUROFmFt5_oQTHAj5JIjBb2ALe'

const BRAND_WHOLE_FOODS =
	'https://lh3.googleusercontent.com/aida-public/AB6AXuATIGoXydBEGP2q20mc3EjoqWQEYJkTLMh2xR_P3w2nGUiU6jokQ0-ljQuIFy1dg4cwLlSIFF2lBCl3447r4iHsR2orQqHyHvENmrsORo1w92o14DoMEMsqxA4oGwNixaF189e0XGrfZ_htpugnvdXyGt2TBH_1OTdxvvvMWuhgIzH7CBGdHz9Mgr2h58vVR4D5g10CvwiGoeuDxzNTrpaNJjmNpNerCIgDzkF9W53kNfjUjOhsTkLbL1_h8Ybtjj_FYu5b1gG2fQXj'

const BRAND_LULU =
	'https://lh3.googleusercontent.com/aida-public/AB6AXuDcvZ5F4HraCf2BkGDxYaLb5lCrVGvTLQNgOR2CIF0zcPhkxrRmWoVk_A1P17GBKcjpKIHusmxga2uIMN-pmArvfyJAieNGu5mLXJtEJgvzBdYgUUGda4JpBLz0dKHEvceRC2WM-sio3gfAoDOMFvMSP9Znvqn5HZXY6WahS2ARp_34bWcX7wNLy8eSL2XB9w27z8nBbAd04ZQFHJ3XUxjwVfrOYGH2i5M-ss3id3eIZzn4Wh0bLmMCIdLcEJSyVefXgELYAxwtavYO'

const iconFill = { fontVariationSettings: "'FILL' 1" as const }

export function Home() {
	return (
		<div className="min-h-dvh bg-[#f8f9fa] dark:bg-slate-900">
			{/* Top App Bar — aligned with temp1.html */}
			<header className="fixed top-0 z-50 w-full bg-slate-50/80 backdrop-blur-xl transition-colors duration-300 dark:bg-slate-900/80">
				<div className="flex w-full items-center justify-between px-6 py-4">
					<div className="flex items-center gap-3">
						<img
							src={AVATAR_IMAGE}
							alt="Profile"
							className="h-10 w-10 rounded-full object-cover shadow-sm transition-transform active:scale-95"
						/>
					</div>
					<h1 className="font-['Inter'] text-base font-semibold tracking-tight text-slate-900 dark:text-slate-100">
						Good morning, Sarah
					</h1>
					<div className="flex items-center">
						<button
							type="button"
							className="rounded-full p-2 text-blue-600 transition-transform hover:bg-slate-100/50 active:scale-95 dark:text-blue-400"
							aria-label="Scan QR"
						>
							<span className="material-symbols-outlined" data-icon="qr_code_scanner">
								qr_code_scanner
							</span>
						</button>
					</div>
				</div>
			</header>

			{/* Content — temp1.html main */}
			<main className="mx-auto max-w-md px-5 pb-32 pt-24 font-body text-on-surface antialiased">
				{/* NFC Status — temp1.html 122–128 */}
				<section className="mb-8">
					<div className="flex flex-col items-center gap-2">
						<div className="flex h-14 w-14 items-center justify-center rounded-full bg-emerald-50 dark:bg-emerald-950/40">
							<span
								className="material-symbols-outlined text-3xl text-emerald-500"
								style={iconFill}
							>
								auto_awesome
							</span>
						</div>
						<p className="text-xs font-bold uppercase tracking-wide text-emerald-600 dark:text-emerald-400">
							NFC Active &amp; Ready
						</p>
					</div>
				</section>

				{/* Pay hub (no top card wrapper) */}
				<section className="mb-8 space-y-8 text-center">
					<div className="space-y-4">
						<h1 className="text-2xl font-bold leading-tight text-[#1C1C1E] dark:text-slate-100">
							Tap at any Verra SoftPOS to pay seamlessly.
						</h1>
						<div className="relative mx-auto flex h-48 w-48 items-center justify-center">
							<div className="absolute inset-0 animate-ping rounded-full border-2 border-primary/10 opacity-20" />
							<div className="absolute inset-4 rounded-full border-2 border-primary/20" />
							<div className="flex h-24 w-24 items-center justify-center rounded-full bg-primary-fixed-dim/30">
								<span className="material-symbols-outlined text-5xl text-primary">contactless</span>
							</div>
						</div>
					</div>
					<div className="w-full space-y-6">
						<button
							type="button"
							className="signature-gradient flex w-full items-center justify-center gap-3 rounded-full py-5 px-8 text-lg font-bold text-white shadow-lg shadow-primary/20 transition-all duration-300 hover:opacity-90 active:scale-95"
						>
							<span className="material-symbols-outlined text-2xl">qr_code_2</span>
							<span>Show Pay Code</span>
						</button>
						<div className="text-center">
							<p className="mb-1 text-xs font-medium tracking-wide text-slate-400">Total Power</p>
							<h3 className="text-3xl font-extrabold tracking-tight text-slate-900 dark:text-slate-100">
								CA$ 152.00
							</h3>
						</div>
					</div>
				</section>

				{/* Quick Actions */}
				<section className="mb-10 flex gap-3">
					<button
						type="button"
						className="flex flex-1 flex-col items-start gap-3 rounded-lg bg-surface-container-low p-4 text-left transition-transform active:scale-95"
					>
						<div className="flex h-10 w-10 items-center justify-center rounded-md bg-primary-fixed-dim/30 text-primary">
							<span className="material-symbols-outlined" data-icon="account_balance_wallet">
								account_balance_wallet
							</span>
						</div>
						<div>
							<p className="text-sm font-bold">Top Up</p>
							<p className="mt-1 text-[10px] leading-tight text-on-surface-variant">
								Let the cashier scan this to add funds.
							</p>
						</div>
					</button>
					<button
						type="button"
						className="flex flex-1 flex-col items-start gap-3 rounded-lg bg-surface-container-low p-4 text-left transition-transform active:scale-95"
					>
						<div className="flex h-10 w-10 items-center justify-center rounded-md bg-primary-fixed-dim/30 text-primary">
							<span className="material-symbols-outlined" data-icon="featured_seasonal_and_gifts">
								featured_seasonal_and_gifts
							</span>
						</div>
						<div>
							<p className="text-sm font-bold">Transfer</p>
							<p className="mt-1 text-[10px] leading-tight text-on-surface-variant">
								Send Money or Gift Pack.
							</p>
						</div>
					</button>
				</section>

				{/* My Brands */}
				<section className="mb-10">
					<div className="mb-4 flex items-end justify-between px-1">
						<h2 className="text-xl font-extrabold tracking-tight">My Brands</h2>
						<button type="button" className="text-xs font-semibold text-primary">
							See all
						</button>
					</div>
					<div className="flex flex-col rounded-lg bg-surface-container-low p-2">
						<div className="group flex cursor-pointer items-center gap-4 rounded-lg p-3 transition-colors hover:bg-surface-container">
							<div className="flex h-12 w-12 items-center justify-center overflow-hidden rounded-md border border-outline-variant/10 bg-white shadow-sm">
								<img src={BRAND_STARBUCKS} alt="Starbucks" className="h-full w-full object-cover" />
							</div>
							<div className="flex-1">
								<p className="text-sm font-bold">Starbucks</p>
								<p className="text-[11px] text-on-surface-variant">Coffee &amp; Refreshments</p>
							</div>
							<div className="text-right">
								<p className="text-sm font-bold text-on-surface">CA$ 12.50</p>
								<p className="text-[10px] font-medium text-emerald-600">+15 pts</p>
							</div>
						</div>
						<div className="group flex cursor-pointer items-center gap-4 rounded-lg p-3 transition-colors hover:bg-surface-container">
							<div className="flex h-12 w-12 items-center justify-center overflow-hidden rounded-md border border-outline-variant/10 bg-white shadow-sm">
								<img src={BRAND_WHOLE_FOODS} alt="Whole Foods" className="h-full w-full object-cover" />
							</div>
							<div className="flex-1">
								<p className="text-sm font-bold">Whole Foods</p>
								<p className="text-[11px] text-on-surface-variant">Organic Groceries</p>
							</div>
							<div className="text-right">
								<p className="text-sm font-bold text-on-surface">CA$ 84.20</p>
								<p className="text-[10px] font-medium text-emerald-600">+120 pts</p>
							</div>
						</div>
						<div className="group flex cursor-pointer items-center gap-4 rounded-lg p-3 transition-colors hover:bg-surface-container">
							<div className="flex h-12 w-12 items-center justify-center overflow-hidden rounded-md border border-outline-variant/10 bg-white shadow-sm">
								<img src={BRAND_LULU} alt="Lululemon" className="h-full w-full object-cover" />
							</div>
							<div className="flex-1">
								<p className="text-sm font-bold">Lululemon</p>
								<p className="text-[11px] text-on-surface-variant">Activewear</p>
							</div>
							<div className="text-right">
								<p className="text-sm font-bold text-on-surface">CA$ 55.30</p>
								<p className="text-[10px] font-medium text-on-surface-variant">Expires in 12d</p>
							</div>
						</div>
					</div>
				</section>

				{/* Recent Activity */}
				<section>
					<div className="mb-4 flex items-end justify-between px-1">
						<h2 className="text-lg font-bold tracking-tight">Recent</h2>
						<button type="button" aria-label="Filter" className="cursor-pointer">
							<span className="material-symbols-outlined text-on-surface-variant text-xl" data-icon="filter_list">
								filter_list
							</span>
						</button>
					</div>
					<div className="space-y-4">
						<div className="group flex items-center gap-4">
							<div className="flex h-10 w-10 items-center justify-center rounded-full bg-emerald-50 text-emerald-600">
								<span className="material-symbols-outlined" data-icon="currency_bitcoin">
									currency_bitcoin
								</span>
							</div>
							<div className="flex-1">
								<p className="text-sm font-semibold">USDC Deposit</p>
								<p className="text-[11px] text-on-surface-variant">Completed • Today, 09:41</p>
							</div>
							<p className="text-sm font-bold text-emerald-600">+ CA$ 50.00</p>
						</div>
						<div className="group flex items-center gap-4">
							<div className="flex h-10 w-10 items-center justify-center rounded-full bg-slate-100 text-slate-600">
								<span className="material-symbols-outlined" data-icon="shopping_bag">
									shopping_bag
								</span>
							</div>
							<div className="flex-1">
								<p className="text-sm font-semibold">Starbucks Purchase</p>
								<p className="text-[11px] text-on-surface-variant">Toronto Union • Yesterday</p>
							</div>
							<p className="text-sm font-bold text-on-surface">- CA$ 6.75</p>
						</div>
					</div>
				</section>
			</main>

			{/* Bottom Navigation */}
			<nav className="fixed bottom-0 left-0 z-50 flex w-full items-center justify-around rounded-t-[32px] border-t border-slate-100/10 bg-white/80 px-4 pb-8 pt-3 shadow-[0_-10px_40px_rgba(0,0,0,0.05)] backdrop-blur-2xl dark:border-slate-800/20 dark:bg-slate-950/80">
				<a
					className="flex flex-col items-center justify-center rounded-full bg-blue-50/50 px-4 py-1 text-blue-600 transition-all duration-300 ease-out active:scale-90 dark:bg-blue-900/20 dark:text-blue-400"
					href="#"
				>
					<span className="material-symbols-outlined" data-icon="home" style={iconFill}>
						home
					</span>
					<span className="font-['Inter'] text-[11px] font-medium tracking-wide">Home</span>
				</a>
				<a
					className="flex flex-col items-center justify-center text-slate-400 transition-all duration-300 ease-out hover:text-blue-500 active:scale-90 dark:text-slate-500 dark:hover:text-blue-300"
					href="#"
				>
					<span className="material-symbols-outlined" data-icon="account_balance_wallet">
						account_balance_wallet
					</span>
					<span className="font-['Inter'] text-[11px] font-medium tracking-wide">Wallet</span>
				</a>
				<a
					className="flex flex-col items-center justify-center text-slate-400 transition-all duration-300 ease-out hover:text-blue-500 active:scale-90 dark:text-slate-500 dark:hover:text-blue-300"
					href="#"
				>
					<span className="material-symbols-outlined" data-icon="explore">
						explore
					</span>
					<span className="font-['Inter'] text-[11px] font-medium tracking-wide">Discovery</span>
				</a>
				<a
					className="flex flex-col items-center justify-center text-slate-400 transition-all duration-300 ease-out hover:text-blue-500 active:scale-90 dark:text-slate-500 dark:hover:text-blue-300"
					href="#"
				>
					<span className="material-symbols-outlined" data-icon="chat_bubble">
						chat_bubble
					</span>
					<span className="font-['Inter'] text-[11px] font-medium tracking-wide">Chat</span>
				</a>
				<a
					className="flex flex-col items-center justify-center text-slate-400 transition-all duration-300 ease-out hover:text-blue-500 active:scale-90 dark:text-slate-500 dark:hover:text-blue-300"
					href="#"
				>
					<span className="material-symbols-outlined" data-icon="receipt_long">
						receipt_long
					</span>
					<span className="font-['Inter'] text-[11px] font-medium tracking-wide">Activity</span>
				</a>
			</nav>
		</div>
	)
}
