/**
 * 诊断脚本：从 Base 链拉取用户 0xa3FBf07D4913AfD7Df8F6389f506EcEE67f2eA40 的 BeamioUserCard 资产数据，
 * 分析 NFT tierIndexOrMax 等字段，排查 USDCUserCardTopupControl 中 hasMembership/effectiveCurrentTier 异常原因。
 *
 * 用法: npx hardhat run scripts/debugUserCardOwnership0xa3FB.ts --network base
 */
import { network } from "hardhat"

const USER_EOA = "0xa3FBf07D4913AfD7Df8F6389f506EcEE67f2eA40"

// 常见卡地址：Sen PHO+CAFE (USDC Topup)、CCSA、基础设施卡
const CARD_ADDRESSES = [
  { name: "Sen USDC Topup", addr: "0xf99018DfFdb0c5657C93ca14DB2900CEbe1168A7" },
  { name: "CCSA", addr: "0x2032A363BB2cf331142391fC0DAd21D6504922C7" },
  { name: "BeamioUserCard Asset", addr: "0xa86a8406B06bD6c332b4b380A0EAced822218Eff" },
]

const CARD_ABI = [
  "function getOwnershipByEOA(address userEOA) view returns (uint256 pt, (uint256 tokenId, uint256 attribute, uint256 tierIndexOrMax, uint256 expiry, bool isExpired)[] nfts)",
  "function currency() view returns (uint8)",
  "function getTiersCount() view returns (uint256)",
  "function getTierAt(uint256 idx) view returns (uint256 minUsdc6, uint256 attr, uint256 tierExpirySeconds, bool upgradeByBalance)",
]

async function main() {
  const { ethers } = await network.connect()
  const provider = ethers.provider

  console.log("=".repeat(70))
  console.log("Base 链用户资产诊断: " + USER_EOA)
  console.log("=".repeat(70))

  const MaxUint256 = ethers.MaxUint256

  for (const { name, addr } of CARD_ADDRESSES) {
    console.log("\n--- 卡: " + name + " (" + addr + ") ---")
    try {
      const card = new ethers.Contract(addr, CARD_ABI, provider)
      const [pointsBalance, nfts] = await card.getOwnershipByEOA(USER_EOA)
      const currency = await card.currency()

      console.log("Points (points6):", pointsBalance.toString())
      console.log("Currency (uint8):", currency.toString())
      console.log("NFT 数量:", nfts.length)

      if (nfts.length > 0) {
        for (let i = 0; i < nfts.length; i++) {
          const n = nfts[i]
          const tierRaw = n.tierIndexOrMax
          const isMax = tierRaw === MaxUint256
          const tierDisplay = isMax ? "MaxUint256 (Default/Max)" : tierRaw.toString()
          console.log("\n  NFT[" + i + "]:")
          console.log("    tokenId:", n.tokenId.toString())
          console.log("    attribute:", n.attribute.toString())
          console.log("    tierIndexOrMax:", tierDisplay, isMax ? "→ getNumericTier 返回 -1" : "→ getNumericTier 返回 " + tierRaw.toString())
          console.log("    expiry:", n.expiry.toString(), n.expiry === 0n ? "(Never)" : "")
          console.log("    isExpired:", n.isExpired)
        }
      }

      // 拉取 tiers 以便对照
      try {
        const count = await card.getTiersCount()
        console.log("\n  Tiers 数量:", count.toString())
        for (let i = 0; i < Number(count) && i < 5; i++) {
          const [minUsdc6, attr, , upgradeByBalance] = await card.getTierAt(i)
          console.log("    Tier[" + i + "]: minUsdc6=" + minUsdc6.toString() + ", upgradeByBalance=" + upgradeByBalance)
        }
      } catch (e) {
        console.log("  (无法读取 tiers)")
      }
    } catch (e: any) {
      console.error("  查询失败:", e.message)
    }
  }

  console.log("\n" + "=".repeat(70))
  console.log("分析结论:")
  console.log("- 若 tierIndexOrMax === MaxUint256，getMyAssets 返回 tier: 'Default/Max'，getNumericTier 得 -1")
  console.log("- 此时 currentTierIndex=-1，需依赖 effectiveCurrentTier（由 points6 推导）")
  console.log("- hasEffectiveMembership = hasMembership || effectiveCurrentTier != null")
  console.log("=".repeat(70))
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e)
    process.exit(1)
  })
