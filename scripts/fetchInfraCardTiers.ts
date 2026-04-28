/**
 * 从 Base 链上获取基础设施卡的 tiers 配置并分析
 * 运行：npx hardhat run scripts/fetchInfraCardTiers.ts --network base
 */
import { network as networkModule } from "hardhat";

const INFRA_CARD_ADDRESS = "0xC0F1c74fb95100a97b532be53B266a54f41DB615";

async function main() {
  const { ethers } = await networkModule.connect();
  const provider = ethers.provider;

  const code = await provider.getCode(INFRA_CARD_ADDRESS);
  if (!code || code === "0x") {
    console.error("❌ 地址无合约代码:", INFRA_CARD_ADDRESS);
    process.exit(1);
  }

  const card = await ethers.getContractAt("BeamioUserCard", INFRA_CARD_ADDRESS);

  const count = await card.getTiersCount();
  const upgradeType = await card.upgradeType();
  console.log("========== 基础设施卡 Tiers 配置 (Base) ==========\n");
  console.log("卡地址:", INFRA_CARD_ADDRESS);
  console.log("upgradeType (0=topup delta, 1=balance, 2=cumulative to admin):", upgradeType.toString());
  console.log("Tiers 数量:", count.toString());
  console.log();

  if (count === 0n) {
    console.log("⚠️ 无 tiers 配置！");
    console.log("   → _maybeUpgrade 会直接 return（tiers.length == 0）");
    console.log("   → _issueCardByPointsDelta_AssumingNoValidCard 会发 defaultAttrWhenNoTiers 的卡（无 tier 档位）");
    console.log("   → 需由 owner 调用 appendTier(minUsdc6, attr, tierExpirySeconds) 配置 50/100 CAD 等档位");
    return;
  }

  const POINTS_DECIMALS = 6;
  for (let i = 0; i < Number(count); i++) {
    const tier = await card.getTierAt(i);
    const minUsdc6 = tier.minUsdc6;
    const minCad = Number(minUsdc6) / 10 ** POINTS_DECIMALS;
    console.log(`--- Tier ${i} ---`);
    console.log("  minUsdc6:", minUsdc6.toString(), `(= ${minCad} CAD)`);
    console.log("  attr:", tier.attr.toString());
    console.log("  tierExpirySeconds:", tier.tierExpirySeconds.toString(), tier.tierExpirySeconds === 0n ? "(使用全局 expirySeconds)" : "");
    console.log();
  }

  // 同时查询该 redeem 交易涉及的用户状态（可选）
  const userAA = "0x891c8F9025BD758AC1D64C0E90969c730a19A77C";
  const activeId = await card.activeMembershipId(userAA);
  const activeTierIdx = await card.activeTierIndexOrMax(userAA);
  const pointsBalance = await card.balanceOf(userAA, 0); // POINTS_ID = 0

  console.log("========== 用户状态 (redeem 交易接收方) ==========\n");
  console.log("用户 AA:", userAA);
  console.log("activeMembershipId:", activeId.toString(), activeId === 0n ? "(无有效卡)" : "");
  console.log("activeTierIndexOrMax:", activeTierIdx.toString(), activeTierIdx === 2n ** 256n - 1n ? "(无/已过期)" : "");
  console.log("points 余额 (token#0):", pointsBalance.toString(), `(= ${Number(pointsBalance) / 10 ** POINTS_DECIMALS} CAD)`);
  console.log();

  // 分析：为何 200 CAD redeem 可能未触发 tier 升级
  console.log("========== 分析 ==========\n");
  if (count >= 2n) {
    const t0 = await card.getTierAt(0);
    const t1 = await card.getTierAt(1);
    const min0 = Number(t0.minUsdc6);
    const min1 = Number(t1.minUsdc6);
    const tier0Cad = min0 / 10 ** POINTS_DECIMALS;
    const tier1Cad = min1 / 10 ** POINTS_DECIMALS;
    console.log(`Tier 0: ${tier0Cad} CAD, Tier 1: ${tier1Cad} CAD`);
    console.log();
    if (activeId !== 0n && activeTierIdx < count) {
      const curTier = await card.getTierAt(activeTierIdx);
      const curMinCad = Number(curTier.minUsdc6) / 10 ** POINTS_DECIMALS;
      console.log(`用户当前已有 tier ${activeTierIdx} (${curMinCad} CAD)`);
      if (activeTierIdx === count - 1n) {
        console.log("→ 已是最高档，_maybeUpgrade 的 _nextTierIndexAbove 返回 max，不会升级");
      } else {
        const nextTier = await card.getTierAt(activeTierIdx + 1n);
        const nextMinCad = Number(nextTier.minUsdc6) / 10 ** POINTS_DECIMALS;
        console.log(`→ 下一档 tier ${Number(activeTierIdx) + 1} 需 ${nextMinCad} CAD`);
        console.log(`  200 CAD redeem 应满足，若未升级请检查 upgradeType 与 balance/delta 逻辑`);
      }
    } else {
      console.log("用户无有效卡 (activeMembershipId=0)，200 CAD redeem 应触发 _issueCardByPointsDelta_AssumingNoValidCard 发卡");
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
