/**
 * 从 Base RPC 直接拉取卡 0xeA7B248CFcD457c4884371c55Ae5aFb0F428c483 + redeemcode 3UszMjLTvv3H57m2dpz3v0 的链上数据
 * 排查 Redeem Asset 面板无法显示正确卡信息的原因
 * 运行：npx hardhat run scripts/checkRedeem0xeA7B.ts --network base
 */
import { network as networkModule } from "hardhat";

const CARD = "0xeA7B248CFcD457c4884371c55Ae5aFb0F428c483";
const CODE = "3UszMjLTvv3H57m2dpz3v0";

const CURRENCY_NAMES: Record<number, string> = {
  0: "CAD",
  1: "USD",
  2: "JPY",
  3: "CNY",
  4: "USDC",
  5: "HKD",
  6: "EUR",
  7: "SGD",
  8: "TWD",
};

async function main() {
  const { ethers } = await networkModule.connect();
  const provider = ethers.provider;

  const cardAbi = [
    "function getRedeemStatus(bytes32 hash) view returns (bool active, uint256 totalPoints6)",
    "function owner() view returns (address)",
    "function currency() view returns (uint8)",
    "function pointsUnitPriceInCurrencyE6() view returns (uint256)",
  ];

  const hash = ethers.keccak256(ethers.toUtf8Bytes(CODE.trim()));
  const card = new ethers.Contract(CARD, cardAbi, provider);

  console.log("========== Redeem 链上数据检查 (Base RPC) ==========");
  console.log("Card:", CARD);
  console.log("Code:", CODE);
  console.log("Hash (keccak256):", hash);
  console.log();

  try {
    // 1. 检查合约是否存在（获取 code）
    const code = await provider.getCode(CARD);
    if (!code || code === "0x") {
      console.log("❌ 卡地址无合约代码，可能未部署或地址错误");
      return;
    }
    console.log("✅ 卡地址有合约代码");

    const [[active, totalPoints6], owner, currencyNum, priceE6Raw] = await Promise.all([
      card.getRedeemStatus(hash),
      card.owner(),
      card.currency(),
      card.pointsUnitPriceInCurrencyE6(),
    ]);

    const priceE6 = Number(priceE6Raw);
    const ptsPer1Currency = priceE6 > 0 ? 1_000_000 / priceE6 : 0;
    const pointsHuman = Number(ethers.formatUnits(totalPoints6, 6));
    const currency = CURRENCY_NAMES[Number(currencyNum)] ?? "?";

    console.log("\n1. getRedeemStatus(hash):");
    console.log("   active:", active);
    console.log("   totalPoints6 (raw):", totalPoints6.toString());
    console.log("   pointsHuman (formatUnits 6):", pointsHuman);

    console.log("\n2. owner():", owner);

    console.log("\n3. currency():", currencyNum.toString(), "(" + currency + ")");

    console.log("\n4. pointsUnitPriceInCurrencyE6():", priceE6Raw.toString(), "(priceE6 =", priceE6, ")");
    console.log("   ptsPer1Currency = 1e6/priceE6 =", ptsPer1Currency);

    const amt = ptsPer1Currency > 0 ? pointsHuman / ptsPer1Currency : pointsHuman;
    console.log("\n5. 计算金额:");
    console.log("   amount = pointsHuman / ptsPer1Currency =", pointsHuman, "/", ptsPer1Currency, "=", amt);

    if (!active) {
      console.log("\n❌ 原因：active=false。该 redeem 不存在、已兑换或已取消。");
    } else if (totalPoints6 === 0n) {
      console.log("\n❌ 原因：totalPoints6 = 0。新合约 getRedeemStatus 已含 token bundle 中 POINTS_ID；旧合约则 points 在 bundle 中，需升级后可见。");
    } else if (priceE6 === 0) {
      console.log("\n❌ 原因：pointsUnitPriceInCurrencyE6 = 0，卡片未配置单价，无法换算货币金额");
      console.log("   应显示 pointsHuman =", pointsHuman, "pts");
    } else if (amt < 0.01) {
      console.log("\n⚠️ 原因：金额过小 (", amt, ")，2 位小数会四舍五入为 0.00");
      console.log("   应使用 4 位小数显示:", amt.toFixed(4));
    } else {
      console.log("\n✅ 链上数据正常，金额应为", amt);
    }
  } catch (e) {
    console.error("\n❌ RPC 调用失败:", e);
    throw e;
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
