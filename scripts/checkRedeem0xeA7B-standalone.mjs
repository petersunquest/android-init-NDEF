/**
 *  standalone 版本：直接从 Base RPC 拉取 redeem 数据
 *  运行：node scripts/checkRedeem0xeA7B-standalone.mjs
 */
import { ethers } from "ethers";

const CARD = "0xeA7B248CFcD457c4884371c55Ae5aFb0F428c483";
const CODE = "3UszMjLTvv3H57m2dpz3v0";
const BASE_RPC = "https://base-rpc.conet.network";

const CURRENCY_NAMES = { 0: "CAD", 1: "USD", 2: "JPY", 3: "CNY", 4: "USDC", 5: "HKD", 6: "EUR", 7: "SGD", 8: "TWD" };

async function main() {
  const provider = new ethers.JsonRpcProvider(BASE_RPC, { chainId: 8453, name: "base" });
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
  console.log("Hash:", hash);

  const code = await provider.getCode(CARD);
  if (!code || code === "0x") {
    console.log("\n❌ 卡地址无合约代码");
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

  console.log("\n1. getRedeemStatus: active=", active, ", totalPoints6=", totalPoints6.toString());
  console.log("2. owner:", owner);
  console.log("3. currency:", currencyNum.toString(), "(" + currency + ")");
  console.log("4. pointsUnitPriceInCurrencyE6:", priceE6Raw.toString());
  console.log("5. pointsHuman:", pointsHuman, ", ptsPer1Currency:", ptsPer1Currency);

  const amt = ptsPer1Currency > 0 ? pointsHuman / ptsPer1Currency : pointsHuman;
  console.log("6. 金额:", amt);

  if (!active) console.log("\n❌ active=false：redeem 不存在/已兑换/已取消");
  else if (totalPoints6 === 0n) console.log("\n❌ totalPoints6=0：旧合约或未配置");
  else if (priceE6 === 0) console.log("\n⚠️ priceE6=0：无法换算货币，应显示 points");
  else console.log("\n✅ 链上数据正常");
}

main().catch((e) => { console.error(e); process.exit(1); });
