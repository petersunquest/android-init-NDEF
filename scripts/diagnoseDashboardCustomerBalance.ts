/**
 * 排查：bizSite Dashboard "Customer Balance" 始终为 0。
 *
 * 复现 biz.tsx 中 `fetchCustomerHeldPointsToken0Display` 的链上读法：
 *   customerHeld = totalSupply(token #0) − Σ balanceOf(merchantAccount, 0)
 * merchantAccount = card.owner() + getAdminListWithMetadata().admins，
 * 每个 EOA 再补充其 BeamioAA（通过 BASE_CARD_FACTORY._aaFactory().beamioAccountOf）。
 *
 * 用法（默认 Base 主网）：
 *   npx hardhat run scripts/diagnoseDashboardCustomerBalance.ts --network base
 *
 * 可选环境变量：
 *   AA=0x...          要诊断的 AA 账户（默认值见下方常量）
 *   CARD=0x...        指定 BeamioUserCard 合约地址（跳过 cardsOfOwner / latestCardOfOwner 解析）
 *   BASE_RPC_URL=...  覆盖 hardhat 默认 Base RPC
 */

import { network as networkModule } from "hardhat"
import type { ethers as EthersNS } from "ethers"

const TARGET_AA = (process.env.AA || "0x73706772A6D22A4DD1B36A793D10c538C7e7210D").trim()
const FORCE_CARD = (process.env.CARD || "").trim()
const BASE_CARD_FACTORY = "0x52cc9E977Ca3EA33c69383a41F87f32a71140A52"
const POINTS_TOKEN_ID = 0n
const E6 = 1_000_000n

const cardFactoryAbi = [
	"function cardsOfOwner(address) view returns (address[])",
	"function latestCardOfOwner(address) view returns (address)",
	"function _aaFactory() view returns (address)",
] as const

const aaFactoryAbi = [
	"function beamioAccountOf(address) view returns (address)",
	"function primaryAccountOf(address) view returns (address)",
] as const

const beamioAccountAbi = ["function owner() view returns (address)"] as const

const cardAbi = [
	"function totalSupply(uint256 id) view returns (uint256)",
	"function balanceOf(address account, uint256 id) view returns (uint256)",
	"function owner() view returns (address)",
	"function getAdminListWithMetadata() view returns (address[] admins, string[] metadatas, address[] parents)",
	"function currency() view returns (uint8)",
	"function pointsUnitPriceInCurrencyE6() view returns (uint256)",
] as const

const formatE6 = (raw: bigint): string => {
	const whole = raw / E6
	const frac = (raw % E6).toString().padStart(6, "0")
	return `${whole}.${frac}`
}

async function getCodeOk(provider: EthersNS.Provider, addr: string): Promise<boolean> {
	const c = await provider.getCode(addr)
	return !!c && c !== "0x" && c.length > 2
}

async function resolveAaForEoa(
	ethers: typeof EthersNS,
	provider: EthersNS.Provider,
	aaFactoryAddr: string,
	eoa: string,
): Promise<string | null> {
	const f = new ethers.Contract(aaFactoryAddr, aaFactoryAbi, provider)
	let aa: string = ethers.ZeroAddress
	try {
		aa = await f.beamioAccountOf(eoa)
	} catch {
		/* ignore */
	}
	if (!aa || aa === ethers.ZeroAddress) {
		try {
			aa = await f.primaryAccountOf(eoa)
		} catch {
			/* ignore */
		}
	}
	if (!aa || aa === ethers.ZeroAddress) return null
	if (!(await getCodeOk(provider, aa))) return null
	return ethers.getAddress(aa)
}

async function pickPrimaryCardForOwner(
	ethers: typeof EthersNS,
	factory: EthersNS.Contract,
	candidates: string[],
	knownCards: string[],
): Promise<string | null> {
	const known = new Set(knownCards.map((c) => c.toLowerCase()))
	for (const o of candidates) {
		try {
			const lc: string = await factory.latestCardOfOwner(o)
			if (lc && lc !== ethers.ZeroAddress && known.has(lc.toLowerCase())) {
				return ethers.getAddress(lc)
			}
		} catch {
			/* ignore */
		}
	}
	return knownCards.length > 0 ? ethers.getAddress(knownCards[knownCards.length - 1]) : null
}

async function main() {
	const { ethers } = await networkModule.connect()
	const provider = ethers.provider

	const aa = ethers.getAddress(TARGET_AA)
	console.log("========== Dashboard Customer Balance 诊断 ==========")
	console.log("AA 账号 :", aa)
	console.log("CARD_FACTORY:", BASE_CARD_FACTORY)
	console.log("BASE RPC:", process.env.BASE_RPC_URL || "https://base-rpc.conet.network")
	console.log("")

	const aaHasCode = await getCodeOk(provider, aa)
	console.log("1) AA 链上状态:")
	console.log("   has code:", aaHasCode ? "✅" : "❌（未部署）")

	let aaOwnerEoa: string | null = null
	if (aaHasCode) {
		try {
			const aaCtr = new ethers.Contract(aa, beamioAccountAbi, provider)
			const o: string = await aaCtr.owner()
			if (o && ethers.isAddress(o) && o !== ethers.ZeroAddress) {
				aaOwnerEoa = ethers.getAddress(o)
			}
			console.log("   owner() =", aaOwnerEoa ?? "(空)")
		} catch (e) {
			console.log("   owner() 调用失败:", (e as Error).message)
		}
	}

	const factory = new ethers.Contract(BASE_CARD_FACTORY, cardFactoryAbi, provider)

	const ownerCandidates: string[] = []
	const pushCand = (a: string | null | undefined) => {
		if (!a || !ethers.isAddress(a)) return
		const x = ethers.getAddress(a)
		if (!ownerCandidates.includes(x)) ownerCandidates.push(x)
	}
	pushCand(aa)
	pushCand(aaOwnerEoa)

	console.log("")
	console.log("2) cardsOfOwner 候选 owners:", ownerCandidates)
	const cards: string[] = []
	for (const o of ownerCandidates) {
		try {
			const list: string[] = await factory.cardsOfOwner(o)
			console.log(`   cardsOfOwner(${o}) →`, list.length === 0 ? "[]" : list)
			for (const c of list ?? []) {
				if (c && ethers.isAddress(c)) cards.push(ethers.getAddress(c))
			}
		} catch (e) {
			console.log(`   cardsOfOwner(${o}) 失败:`, (e as Error).message)
		}
	}
	const dedupedCards = [...new Set(cards.map((c) => c.toLowerCase()))].map((l) => ethers.getAddress(l))

	let cardAddr: string | null = null
	if (FORCE_CARD) {
		if (!ethers.isAddress(FORCE_CARD)) {
			console.log("   ❌ CARD env 不是合法地址:", FORCE_CARD)
			process.exit(1)
		}
		cardAddr = ethers.getAddress(FORCE_CARD)
		console.log("   使用环境变量 CARD =", cardAddr)
	} else {
		cardAddr = await pickPrimaryCardForOwner(ethers, factory, ownerCandidates, dedupedCards)
	}

	if (!cardAddr) {
		console.log("")
		console.log("❌ 该账号在 BeamioCardFactory 上找不到任何 BeamioUserCard。")
		console.log("   → biz.tsx 中 staffProgramBeamioCardAddress=null，retainedCapitalDisplay 永远不会被设值，")
		console.log("     所以 Dashboard 「Customer Balance」就一直显示 C$0.00。")
		console.log("   → 可能原因：")
		console.log("     a) Card 是用 EOA（不是 AA）作为 cardOwner 创建的，而 profile 只有 AA、没有 keyID/EOA。")
		console.log("     b) 该用户其实还没有发行过自己的 Program Card。")
		console.log("     c) 解析 AA→EOA 失败（_aaFactory.beamioAccountOf 返回 0），导致没有补 EOA 候选。")
		return
	}

	console.log("")
	console.log("3) 选定 BeamioUserCard:", cardAddr)
	const cardCodeOk = await getCodeOk(provider, cardAddr)
	console.log("   has code:", cardCodeOk ? "✅" : "❌")
	if (!cardCodeOk) return

	const card = new ethers.Contract(cardAddr, cardAbi, provider)

	const [supplyRaw, ownerRaw, triple, currencyRaw, priceRaw] = await Promise.all([
		card.totalSupply(POINTS_TOKEN_ID) as Promise<bigint>,
		card.owner() as Promise<string>,
		card.getAdminListWithMetadata() as Promise<[string[], string[], string[]]>,
		card.currency().catch(() => -1) as Promise<number>,
		card.pointsUnitPriceInCurrencyE6().catch(() => 0n) as Promise<bigint>,
	])
	const totalSupply = BigInt(supplyRaw.toString())
	const ownerEoa = ethers.isAddress(ownerRaw) ? ethers.getAddress(ownerRaw) : null
	const adminEoas = (triple[0] ?? [])
		.filter((a) => ethers.isAddress(a))
		.map((a) => ethers.getAddress(a))

	console.log("   currency() =", currencyRaw)
	console.log("   pointsUnitPriceInCurrencyE6 =", priceRaw.toString())
	console.log("   owner() =", ownerEoa)
	console.log("   admins:", adminEoas.length === 0 ? "[]" : adminEoas)
	console.log("   totalSupply(token#0) raw =", totalSupply.toString(), `(=${formatE6(totalSupply)} pts)`)

	let aaFactoryAddr: string | null = null
	try {
		const fac: string = await factory._aaFactory()
		if (fac && fac !== ethers.ZeroAddress) aaFactoryAddr = ethers.getAddress(fac)
	} catch {
		/* ignore */
	}
	console.log("")
	console.log("4) 商户侧账号集合 (owner + admins，扩展 AA):")
	console.log("   _aaFactory =", aaFactoryAddr ?? "(unset)")

	const merchantAccountsLower = new Set<string>()
	const eoaSet = new Set<string>()
	if (ownerEoa) eoaSet.add(ownerEoa)
	for (const a of adminEoas) eoaSet.add(a)

	for (const eoa of eoaSet) {
		merchantAccountsLower.add(eoa.toLowerCase())
		if (aaFactoryAddr) {
			const aaForEoa = await resolveAaForEoa(ethers, provider, aaFactoryAddr, eoa)
			if (aaForEoa) {
				console.log(`   EOA ${eoa} → AA ${aaForEoa}`)
				merchantAccountsLower.add(aaForEoa.toLowerCase())
			} else {
				console.log(`   EOA ${eoa} → AA (未解析)`)
			}
		}
	}

	const merchantAccounts = [...merchantAccountsLower].map((l) => ethers.getAddress(l))
	console.log("   去重后 merchantAccounts (", merchantAccounts.length, "):", merchantAccounts)

	console.log("")
	console.log("5) 各账号 token#0 余额（merchant 侧应被扣减）:")
	let merchantHeld = 0n
	for (const acct of merchantAccounts) {
		const raw: bigint = BigInt((await card.balanceOf(acct, POINTS_TOKEN_ID)).toString())
		merchantHeld += raw
		console.log(`   balanceOf(${acct}) = ${raw.toString()} (=${formatE6(raw)} pts)`)
	}

	const customerHeld = totalSupply > merchantHeld ? totalSupply - merchantHeld : 0n
	console.log("")
	console.log("6) 计算结果:")
	console.log("   Σ merchantHeld =", merchantHeld.toString(), `(=${formatE6(merchantHeld)} pts)`)
	console.log("   totalSupply    =", totalSupply.toString(), `(=${formatE6(totalSupply)} pts)`)
	console.log("   customerHeld   =", customerHeld.toString(), `(=${formatE6(customerHeld)} pts)`)
	console.log("")
	console.log("   Dashboard 显示 C$ =", formatE6(customerHeld))

	console.log("")
	if (totalSupply === 0n) {
		console.log("结论：totalSupply(token#0) = 0，说明这张 BeamioUserCard 还没有发行/铸造任何积分；")
		console.log("       所以 Customer Balance 永远 = 0 是正确预期，需要用户先做 Top-up / Mint。")
	} else if (customerHeld === 0n) {
		console.log("结论：totalSupply > 0，但商户侧（owner + admins + 各 AA）的余额之和 = totalSupply，")
		console.log("       即所有积分仍在商户控制的账户里，没有发到顾客手上 →")
		console.log("       这往往是只做了 mint 但没有真正向用户卡 transfer，或全部 redeem 回流，")
		console.log("       UI 数学上正确显示为 0。可对比 Top-ups / Charges / Redeem 数据交叉验证。")
	} else {
		console.log("结论：链上确实有正数 customerHeld。如果 UI 仍为 0，请检查：")
		console.log("       a) profile 里是否真把这张卡当作 staffProgramBeamioCardAddress（getCardsOfOwnerWithDetailsForProfile 是否返回了它）；")
		console.log("       b) 浏览器中 trusted cache key 是否被串号到别的卡（hard refresh / clear LS）；")
		console.log("       c) 是否处于 isAdminForUI=false 路径，从而走 `?? 0` 回落。")
	}
}

main().catch((e) => {
	console.error("诊断脚本失败:", e)
	process.exit(1)
})
