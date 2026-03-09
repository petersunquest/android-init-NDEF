/**
 * 对比 UserCard 0xeA7B... 与 CCSA 卡 0xA1A9... 在 Redeem Asset 获取卡信息时的差异
 * 运行：npx hardhat run scripts/compareRedeemUserCardVsCCSA.ts --network base
 */
import { ethers } from "ethers";

const USER_CARD = "0xeA7B248CFcD457c4884371c55Ae5aFb0F428c483";
const CCSA_CARD = "0xA1A9f6f942dc0ED9Aa7eF5df7337bd878c2e157b";

// UserCard 的 redeem code（之前报错时使用的）
const USER_CARD_CODE = "57W0hZPEmC3Y0IKSsWYa1V";
// CCSA 的 redeem code（用户说可正常显示）
const CCSA_CODE = "1NhO3xhyQAumyOsetfMERh";

const ABI = {
  getRedeemStatus: "function getRedeemStatus(bytes32 hash) view returns (bool active, uint256 totalPoints6)",
  getRedeemStatusBatch: "function getRedeemStatusBatch(string[] codes) view returns (bool[] active, uint256[] totalPoints6)",
  getRedeemStatusEx: "function getRedeemStatusEx(bytes32 hash, address claimer) view returns (bool active, uint128 points6, bool isPool)",
  owner: "function owner() view returns (address)",
  currency: "function currency() view returns (uint8)",
  pointsUnitPriceInCurrencyE6: "function pointsUnitPriceInCurrencyE6() view returns (uint256)",
};

async function testCard(
  label: string,
  cardAddr: string,
  code: string,
  provider: ethers.Provider
) {
  const hash = ethers.keccak256(ethers.toUtf8Bytes(code.trim()));
  const card = new ethers.Contract(cardAddr, Object.values(ABI), provider);

  console.log(`\n========== ${label} ==========`);
  console.log("Card:", cardAddr);
  console.log("Code:", code);
  console.log("Hash:", hash);

  const results: Record<string, string> = {};

  // 1. getRedeemStatus
  try {
    const [active, totalPoints6] = await card.getRedeemStatus(hash);
    results["getRedeemStatus"] = `OK: active=${active}, totalPoints6=${totalPoints6}`;
  } catch (e: any) {
    results["getRedeemStatus"] = `REVERT: ${(e?.message ?? e).slice(0, 120)}`;
  }

  // 2. getRedeemStatusBatch
  try {
    const [aList, tList] = await card.getRedeemStatusBatch([code.trim()]);
    results["getRedeemStatusBatch"] = `OK: active=${aList[0]}, totalPoints6=${tList[0]}`;
  } catch (e: any) {
    results["getRedeemStatusBatch"] = `REVERT: ${(e?.message ?? e).slice(0, 120)}`;
  }

  // 3. getRedeemStatusEx
  try {
    const [active, pts6, isPool] = await card.getRedeemStatusEx(hash, ethers.ZeroAddress);
    results["getRedeemStatusEx"] = `OK: active=${active}, points6=${pts6}, isPool=${isPool}`;
  } catch (e: any) {
    results["getRedeemStatusEx"] = `REVERT: ${(e?.message ?? e).slice(0, 120)}`;
  }

  // 4. owner, currency, price（Redeem Asset 也需要这些）
  try {
    const [owner, currencyNum, priceE6] = await Promise.all([
      card.owner(),
      card.currency(),
      card.pointsUnitPriceInCurrencyE6(),
    ]);
    results["owner/currency/price"] = `OK: owner=${owner}, currency=${currencyNum}, priceE6=${priceE6}`;
  } catch (e: any) {
    results["owner/currency/price"] = `REVERT: ${(e?.message ?? e).slice(0, 120)}`;
  }

  for (const [k, v] of Object.entries(results)) {
    console.log(`  ${k}: ${v}`);
  }
  return results;
}

async function main() {
  const provider = new ethers.JsonRpcProvider(
    process.env.BASE_RPC || "https://1rpc.io/base"
  );

  console.log("========== Redeem Asset 诊断：UserCard vs CCSA ==========");
  console.log("RPC:", process.env.BASE_RPC || "https://1rpc.io/base");

  const userResults = await testCard("UserCard 0xeA7B...", USER_CARD, USER_CARD_CODE, provider);
  const ccsResults = await testCard("CCSA 0xA1A9...", CCSA_CARD, CCSA_CODE, provider);

  // 额外：用 CCSA 的 code 在 UserCard 上试（应返回 active=false，不 revert）
  console.log("\n========== 交叉测试：UserCard + CCSA 的 code ==========");
  await testCard("UserCard + CCSA code", USER_CARD, CCSA_CODE, provider);

  console.log("\n========== 交叉测试：CCSA + UserCard 的 code ==========");
  await testCard("CCSA + UserCard code", CCSA_CARD, USER_CARD_CODE, provider);

  console.log("\n========== 结论 ==========");
  const userReverts = Object.values(userResults).filter((v) => v.startsWith("REVERT"));
  const ccsReverts = Object.values(ccsResults).filter((v) => v.startsWith("REVERT"));
  if (userReverts.length > 0 && ccsReverts.length === 0) {
    console.log("UserCard 在读取 redeem 时 revert，CCSA 正常。");
    console.log("可能原因：UserCard 的 redeem 存储数据异常，导致 _redeemTotalPoints/_poolTotalPoints 迭代 revert。");
  } else if (userReverts.length > 0 && ccsReverts.length > 0) {
    console.log("两卡均有 revert，可能是 RPC 或合约问题。");
  } else {
    console.log("两卡均无 revert，前端可能为其他原因失败。");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
