import { CheckCircle2 } from 'lucide-react'
import { ReadBalancePassHeroCard } from '@/components/ReadBalancePassHeroCard'
import { PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { readBalanceFormatUsdcThousands } from '@/utils/readBalanceDisplay'
import type { DeductExecuteSuccess } from '@/utils/deductPointsExecute'

const CHECK_GREEN = '#16a34a'

/** iOS `DeductPointsSuccessView`. */
export function DeductPointsSuccessView({
	result,
	pointSystemEnabled,
	onDone,
}: {
	result: DeductExecuteSuccess
	pointSystemEnabled: boolean
	onDone: () => void
}) {
	const hero = result.passHero
	const post6 = Number(result.postPointBalance6)
	const postPts =
		pointSystemEnabled && Number.isFinite(post6)
			? readBalanceFormatUsdcThousands(post6 / 1_000_000)
			: null
	const memberDisplayName = (() => {
		const tag = result.customerBeamioTag?.trim()
		if (tag) return tag.startsWith('@') ? tag : `@${tag}`
		return hero.memberDisplayName
	})()

	return (
		<PosScreenShell bg="bg-[#f2f2f7]">
			<div className="relative flex min-h-0 flex-1 flex-col">
				<div className="absolute right-0 top-[max(0.375rem,env(safe-area-inset-top))] z-10">
					<button
						type="button"
						onClick={onDone}
						className="px-5 py-3 text-[17px] font-semibold text-brand-blue"
					>
						Done
					</button>
				</div>
				<PosScreenMain className="overflow-y-auto px-6 pb-[max(1rem,env(safe-area-inset-bottom))] pt-3">
					<div className="space-y-5 pb-6">
						<div className="flex flex-col items-center pt-2 text-center">
							<CheckCircle2 className="h-14 w-14" style={{ color: CHECK_GREEN }} aria-hidden />
							<h1 className="mt-5 text-[28px] font-bold text-slate-900">Points Deducted</h1>
							<p className="mt-2 text-base font-medium text-slate-500">
								{result.amount} point deducted
							</p>
						</div>
						<ReadBalancePassHeroCard
							memberDisplayName={memberDisplayName}
							memberNo={hero.memberNo}
							tierDisplayName={hero.tierDisplayName}
							tierDiscountPercent={hero.tierDiscountPercent}
							programCardDisplayName={hero.programCardDisplayName}
							tierCardBackgroundHex={hero.tierCardBackgroundHex}
							cardMetadataImageUrl={hero.cardMetadataImageUrl}
							balanceParts={hero.balanceParts}
							pointRewardPts={postPts}
						/>
						{result.txHash ? (
							<p className="break-all text-center text-xs text-slate-500">
								Tx: {result.txHash}
							</p>
						) : null}
					</div>
				</PosScreenMain>
			</div>
		</PosScreenShell>
	)
}
