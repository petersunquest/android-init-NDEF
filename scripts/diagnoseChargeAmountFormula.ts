/**
 * 反推：iOS POS 在 charge 时的 amountUsdc6 / unitPriceUSDC6 是怎么得到 49_992_039 的？
 *
 * 已知：
 *  - 触发 tx 区块: 45047606
 *  - card  = 0x52aF…d6c (currency=CAD, pointsUnitPriceInCurrencyE6=1_000_000)
 *  - CCSA = 0x2032A363BB2cf331142391fC0DAd21D6504922C7（CCSA card，定价基准）
 *  - factory paymaster = 0x4b31D6a05Cdc817CAc1B06369555b37a5b182122
 *
 * 思路：在 block 45047606 上读取 factory.quoteCurrencyAmountInUSDC6(CAD=0, 1e6)，
 *      然后枚举可能的 amountUsdc6 反推。
 */
import { ethers } from "ethers"

const RPC = process.env.BASE_RPC_URL || "https://mainnet.base.org"
const FACTORY = "0x2EB245646de404b2Dce87E01C6282C131778bb05" // Card Factory（quote 来源），与 SC.baseFactoryPaymaster 一致
const CARD = "0x52aF5f5E7C136cc1BD596d64CB44eB7F5c9D2d6c"
const CCSA = "0x2032A363BB2cf331142391fC0DAd21D6504922C7"
const BLOCK = 45047606

async function main() {
	const provider = new ethers.JsonRpcProvider(RPC)
	const factory = new ethers.Contract(
		FACTORY,
		[
			"function quoteCurrencyAmountInUSDC6(uint8 currency, uint256 amount) view returns (uint256)",
			"function quoteUnitPointInUSDC6(address card) view returns (uint256)",
		],
		provider,
	)

	const card = new ethers.Contract(
		CARD,
		[
			"function currency() view returns (uint8)",
			"function pointsUnitPriceInCurrencyE6() view returns (uint256)",
		],
		provider,
	)
	const ccsa = new ethers.Contract(
		CCSA,
		[
			"function currency() view returns (uint8)",
			"function pointsUnitPriceInCurrencyE6() view returns (uint256)",
		],
		provider,
	)

	console.log("--- 卡参数 (block latest) ---")
	const [cardCur, cardPriceE6, ccsaCur, ccsaPriceE6] = await Promise.all([
		card.currency(),
		card.pointsUnitPriceInCurrencyE6(),
		ccsa.currency(),
		ccsa.pointsUnitPriceInCurrencyE6(),
	])
	console.log("merchant card  currency =", Number(cardCur), "pointsUnitPriceInCurrencyE6 =", cardPriceE6.toString())
	console.log("CCSA card     currency =", Number(ccsaCur), "pointsUnitPriceInCurrencyE6 =", ccsaPriceE6.toString())

	console.log("\n--- factory quote @ latest (历史 block 已被 prune，用最新近似) ---")
	const overrides = {}
	let ccsaUnitFromCadQuote = 0n
	try {
		ccsaUnitFromCadQuote = await factory.quoteCurrencyAmountInUSDC6(0, 1_000_000n, overrides)
		console.log("CCSA path: quoteCurrencyAmountInUSDC6(CAD, 1e6) =", ccsaUnitFromCadQuote.toString(), "(== 1 CAD in USDC6)")
	} catch (e: any) {
		console.log("quoteCurrencyAmountInUSDC6(CAD,1e6) reverted:", e?.shortMessage)
	}
	let merchantUnit = 0n
	try {
		merchantUnit = await factory.quoteUnitPointInUSDC6(CARD, overrides)
		console.log("merchant card: quoteUnitPointInUSDC6 =", merchantUnit.toString())
	} catch (e: any) {
		console.log("quoteUnitPointInUSDC6(merchantCard) failed:", e?.shortMessage || e?.message)
	}
	let ccsaUnit2 = 0n
	try {
		ccsaUnit2 = await factory.quoteUnitPointInUSDC6(CCSA, overrides)
		console.log("CCSA card     : quoteUnitPointInUSDC6 =", ccsaUnit2.toString())
	} catch (e: any) {
		console.log("quoteUnitPointInUSDC6(CCSA) failed:", e?.shortMessage || e?.message)
	}
	if (ccsaUnitFromCadQuote === 0n && ccsaUnit2 > 0n) ccsaUnitFromCadQuote = ccsaUnit2

	console.log("\n--- 反推 ---")
	const observedPoints = 49_992_039n
	const E6 = 1_000_000n
	for (const desc of ["CCSA path"]) {
		const unitPrice = ccsaUnitFromCadQuote
		// observedPoints = (amountUsdc6 * 1e6) / unitPrice
		// amountUsdc6 = observedPoints * unitPrice / 1e6 ... 但因为是 floor 除法，可能差 0..unitPrice/1e6
		const minAmount = (observedPoints * unitPrice + E6 - 1n) / E6 // 严格使 (X * 1e6 / unitPrice) >= observedPoints+1 的边界
		const exactAmount = (observedPoints * unitPrice) / E6
		console.log(`${desc}: unitPriceUSDC6 = ${unitPrice}`)
		console.log(`  推断 amountUsdc6 ≈ ${exactAmount}  (= observedPoints * unitPrice / 1e6)`)
		// 检查一下 50 CAD 经 oracle 折成 USDC 后的值
		// 需要 1 CAD in USDC6 = unitPrice，则 50 CAD = 50 * unitPrice
		const guess50CadUsdc6 = 50n * unitPrice
		const guess50CadUsdc6Floor = (50_000_000n * unitPrice) / E6 // 50.0 * unitPrice，保 6 位
		const ptsFromGuess = (guess50CadUsdc6 * E6) / unitPrice
		const ptsFromGuessFloor = (guess50CadUsdc6Floor * E6) / unitPrice
		console.log(`  若 amountUsdc6 = 50 * unitPrice = ${guess50CadUsdc6}: floor((amount * 1e6)/unitPrice) = ${ptsFromGuess}`)
		console.log(`  若 amountUsdc6 = floor(50e6*unitPrice/1e6) = ${guess50CadUsdc6Floor}: => ${ptsFromGuessFloor}`)
	}

	console.log("\n--- 结论提示 ---")
	console.log("如果 ccsa unitPrice = 731_xxx 且 amountUsdc6 < 50*ccsaUnit，则 49992039 是因为：")
	console.log("  iOS 用本地 oracle.usdcad 把 50 CAD → amountUsdc6 = 50_000_000/usdcad（floor）")
	console.log("  服务端用链上 quoteCurrencyAmountInUSDC6(CAD,1e6) 给出 unitPriceUSDC6")
	console.log("  两边小数舍入不一致 → ccsaPointsWei = (amountUsdc6 * 1e6) / unitPriceUSDC6 ≠ 50_000_000")
}

main().catch((e) => {
	console.error("fail:", e)
	process.exit(1)
})
