/**
 * 检查 BeamioUserCard 的 totalActiveMemberships 等链上数据
 * 用法: CARD=0x709dae38d65a87289597ee79cb0d5d251a282e59 npx hardhat run scripts/checkCardMembershipStats.ts --network base
 */
import { network as networkModule } from "hardhat";

const CARD = process.env.CARD || "0x709dae38d65a87289597ee79cb0d5d251a282e59";

const ABI = [
  "function totalActiveMemberships() view returns (uint256)",
  "function totalMembershipIssued() view returns (uint256)",
  "function totalMembershipUpgraded() view returns (uint256)",
  "function totalSupply(uint256) view returns (uint256)",
  "function getTiersCount() view returns (uint256)",
  "function activeMembershipCountByTierIndex(uint256) view returns (uint256)",
  "function gateway() view returns (address)",
  "function owner() view returns (address)",
  "function expiresAt(uint256) view returns (uint256)",
  "function expirySeconds() view returns (uint256)",
  "function activeMembershipId(address) view returns (uint256)",
  "function balanceOf(address,uint256) view returns (uint256)",
  "function tokenTierIndexOrMax(uint256) view returns (uint256)",
  "event MemberNFTIssued(address indexed user, uint256 indexed tokenId, uint256 tierIndexOrMax, uint256 minUsdc6, uint256 expiry)",
];

async function main() {
  const { ethers } = await networkModule.connect();
  const provider = ethers.provider;
  const card = new ethers.Contract(CARD, ABI, provider);

  console.log("========== BeamioUserCard 会员统计 (Base) ==========");
  console.log("卡地址:", CARD);
  console.log();

  const block = await provider.getBlock("latest");
  const now = block!.timestamp;

  const out: Record<string, string | number> = {};
  for (const name of ["gateway", "owner", "totalActiveMemberships", "totalMembershipIssued", "totalMembershipUpgraded", "totalSupply0", "tiersCount", "expirySeconds"]) {
    try {
      if (name === "totalSupply0") {
        out[name] = (await card.totalSupply(0)).toString();
      } else if (name === "tiersCount") {
        out[name] = (await card.getTiersCount()).toString();
      } else {
        const v = await (card as any)[name]();
        out[name] = typeof v === "bigint" ? v.toString() : v;
      }
    } catch (e: any) {
      out[name] = "ERR: " + (e?.shortMessage || e?.message || "").slice(0, 60);
    }
  }

  console.log("1. 基本配置");
  console.log("   gateway:", out.gateway);
  console.log("   owner:", out.owner);
  console.log("   expirySeconds:", out.expirySeconds);
  console.log();

  console.log("2. 会员统计");
  console.log("   totalActiveMemberships:", out.totalActiveMemberships);
  console.log("   totalMembershipIssued:", out.totalMembershipIssued);
  console.log("   totalMembershipUpgraded:", out.totalMembershipUpgraded);
  console.log("   totalSupply(0) [points]:", out.totalSupply0);
  console.log("   tiersCount:", out.tiersCount);
  console.log();

  const tiersCount = Number(out.tiersCount) || 0;
  const activeByTier: number[] = [];
  for (let i = 0; i < Math.min(tiersCount, 8); i++) {
    try {
      activeByTier.push(Number(await card.activeMembershipCountByTierIndex(i)));
    } catch {
      break;
    }
  }
  console.log("3. activeMembershipCountByTierIndex:", activeByTier.join(", "));
  console.log();

  // MemberNFTIssued events
  const filter = card.filters.MemberNFTIssued();
  const events = await card.queryFilter(filter, -10000);
  console.log("4. MemberNFTIssued 事件数:", events.length);
  for (let i = Math.max(0, events.length - 5); i < events.length; i++) {
    const e = events[i];
    const args = e.args ? (e.args as any) : {};
    const block = await provider.getBlock(e.blockNumber);
    const ts = block?.timestamp ? new Date(block.timestamp * 1000).toISOString() : "?";
    console.log(`   [${i}] user=${args.user} tokenId=${args.tokenId?.toString()} tier=${args.tierIndexOrMax?.toString()} block=${e.blockNumber} ${ts}`);
  }
  console.log();

  // If we have issued memberships, check first user's active state
  if (events.length > 0) {
    const last = events[events.length - 1];
    const user = (last.args as any)?.user;
    const tokenId = (last.args as any)?.tokenId;
    if (user && tokenId) {
      console.log("5. 最新会员检查 (user:", user, ")");
      try {
        const exp = await card.expiresAt(tokenId);
        const bal = await card.balanceOf(user, tokenId);
        const activeId = await card.activeMembershipId(user);
        const tierIndex = await card.tokenTierIndexOrMax(tokenId);
        console.log("   expiresAt(tokenId):", exp.toString(), exp > 0n ? `(${new Date(Number(exp) * 1000).toISOString()})` : "(never)");
        console.log("   balanceOf(user,tokenId):", bal.toString());
        console.log("   activeMembershipId(user):", activeId.toString());
        console.log("   tokenTierIndexOrMax(tokenId):", tierIndex.toString());
        const isExpired = exp > 0n && now >= Number(exp);
        console.log("   isExpired:", isExpired);
        console.log();

        const totalActive = Number(out.totalActiveMemberships) || 0;
        const totalIssued = Number(out.totalMembershipIssued);
        console.log("6. 设计校验");
        if (totalIssued > 0 && totalActive === 0 && activeId === 0n) {
          console.log("   ❌ totalActiveMemberships=0 但 totalMembershipIssued>0 且用户有有效 NFT");
          console.log("   → 可能为 mintFaucetByGateway 未调用 _activateIssuedMembership 的旧 bug（已修复）");
          console.log("   → 该卡可能由旧 bytecode 创建，需用新 bytecode 重新 createCard 后测试");
        } else if (totalActive > 0) {
          console.log("   ✅ totalActiveMemberships 正常");
        }
      } catch (e: any) {
        console.log("   查询失败:", e?.message || e);
      }
    }
  }

  const totalMembershipIssued = Number(out.totalMembershipIssued) || 0;
  const totalActive = Number(out.totalActiveMemberships) || 0;
  if (totalMembershipIssued > 0 && totalActive === 0) {
    console.log();
    console.log("========== 结论 ==========");
    console.log("totalActiveMemberships 未达到设计要求：已发行会员但 totalActiveMemberships=0");
    console.log("可能原因：该卡由修复前的 bytecode 创建，或 topup 走的是 mintFaucetByGateway 旧路径");
  }
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
