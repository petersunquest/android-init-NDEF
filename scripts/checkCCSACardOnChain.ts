/**
 * 检查 CCSA 卡链上状态，排查 UC_PriceZero 原因。
 *
 * 可能原因：
 * 1) 卡 pointsUnitPriceInCurrencyE6() 为 0
 * 2) Oracle 未配置 CAD/USDC
 * 3) 链上 BeamioQuoteHelperV07 参数顺序与当前源码相反（先 price 后 currency），
 *    Factory 传 (currency, price) 被读成 (price=0, currency=…) 导致返回 0 → 需重部署 QuoteHelper 并 setQuoteHelper
 *
 * 运行：npx hardhat run scripts/checkCCSACardOnChain.ts --network base
 * 或：CCSA_CARD=0x... npx hardhat run scripts/checkCCSACardOnChain.ts --network base
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { resolveBaseCardFactoryAddress } from "./readCanonicalBaseCardFactory.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

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
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const fullPath = path.join(deploymentsDir, "base-FullAccountAndUserCard.json");

  let CCSA_CARD = process.env.CCSA_CARD || "";
  let CARD_FACTORY = resolveBaseCardFactoryAddress(deploymentsDir);
  let EXPECTED_QUOTE_HELPER = "";

  if (fs.existsSync(fullPath)) {
    const data = JSON.parse(fs.readFileSync(fullPath, "utf-8"));
    const existing = data.existing || {};
    if (!CCSA_CARD) {
      // 从 x402sdk/chainAddresses BASE_CCSA_CARD_ADDRESS（与 chainAddresses.ts 一致）
      CCSA_CARD = "0x57052780925448Ce1dB7aC409cCcCf13Bcc4eb71";
    }
    if (existing.beamioQuoteHelper) EXPECTED_QUOTE_HELPER = existing.beamioQuoteHelper;
  }
  if (!CCSA_CARD) {
    console.error("请设置 CCSA_CARD 或确保有默认 CCSA 地址");
    process.exit(1);
  }

  const cardAbi = [
    "function factoryGateway() view returns (address)",
    "function currency() view returns (uint8)",
    "function pointsUnitPriceInCurrencyE6() view returns (uint256)",
    "function gateway() view returns (address)",
    "function transferWhitelistEnabled() view returns (bool)",
  ];
  const factoryAbi = [
    "function quoteHelper() view returns (address)",
    "function quoteUnitPointInUSDC6(address) view returns (uint256)",
  ];

  const card = new ethers.Contract(CCSA_CARD, cardAbi, ethers.provider);
  console.log("========== CCSA 卡链上状态 ==========");
  console.log("卡地址:", CCSA_CARD);
  console.log();

  const gateway = await card.factoryGateway();
  const currency = await card.currency();
  const priceE6 = await card.pointsUnitPriceInCurrencyE6();

  console.log("1. factoryGateway():", gateway);
  if (CARD_FACTORY && gateway.toLowerCase() !== CARD_FACTORY.toLowerCase()) {
    console.log("   ❌ 与当前 Card Factory 不一致，当前 Factory:", CARD_FACTORY);
  } else if (CARD_FACTORY) {
    console.log("   ✅ 与部署文件中的 Card Factory 一致");
  }
  console.log();

  console.log("2. currency():", currency.toString(), "(" + (CURRENCY_NAMES[Number(currency)] || "?") + ")");
  console.log();

  console.log("3. pointsUnitPriceInCurrencyE6():", priceE6.toString());
  if (priceE6 === 0n) {
    console.log("   ❌ 为 0 → Factory.quoteUnitPointInUSDC6(card) 会返回 0 → 购卡 revert UC_PriceZero()");
    console.log("   修复：需在卡上调用 setPointsUnitPriceInCurrencyE6(正确单价E6)，或由 gateway 调 setCardPointsUnitPrice。");
  } else {
    console.log("   ✅ 非 0");
  }
  console.log();

  let transferWhitelistEnabled = false;
  try {
    transferWhitelistEnabled = await card.transferWhitelistEnabled();
  } catch (e: any) {
    console.log("4. transferWhitelistEnabled(): (call failed)", e?.message || e);
  }
  console.log("4. transferWhitelistEnabled():", transferWhitelistEnabled);
  console.log("   ", transferWhitelistEnabled ? "✅ 开（仅白名单地址可转出）" : "❌ 关（无白名单限制）");
  console.log();

  if (gateway !== ethers.ZeroAddress) {
    const factory = new ethers.Contract(gateway, factoryAbi, ethers.provider);
    const quoteHelperAddr = await factory.quoteHelper();

    // 先查 Oracle 的 CAD(0) 和 USDC(4)：若未配置，QuoteHelper 会 revert QH_OracleError，部分 RPC 可能把 view revert 解析成 0
    const oracleAbi = ["function getRate(uint8) view returns (uint256)"];
    const qhAbi = ["function oracle() view returns (address)"];
    const qhForOracle = new ethers.Contract(quoteHelperAddr, qhAbi, ethers.provider);
    const oracleAddr = await qhForOracle.oracle();
    if (oracleAddr) {
      const oracle = new ethers.Contract(oracleAddr, oracleAbi, ethers.provider);
      try {
        const r0 = await oracle.getRate(0);
        const r4 = await oracle.getRate(4);
        console.log("5. Oracle.getRate(CAD=0):", r0.toString(), r0 !== 0n ? "✅" : "❌");
        console.log("   Oracle.getRate(USDC=4):", r4.toString(), r4 !== 0n ? "✅" : "❌");
        if (r0 === 0n || r4 === 0n) console.log("   → 未配置会导致 QuoteHelper revert，部分节点会把 view revert 当作 0，进而触发 UC_PriceZero。");
      } catch (e: any) {
        console.log("5. Oracle.getRate: revert -", e?.message || e);
      }
      console.log();
    }

    let quoteResult: bigint;
    try {
      quoteResult = await factory.quoteUnitPointInUSDC6(CCSA_CARD);
    } catch (e: any) {
      console.log("6. Factory.quoteUnitPointInUSDC6(卡): revert -", e?.message || e);
      console.log("   （若为 QH_OracleError，表示 Oracle 未配置该 currency 或 USDC 汇率）");
      process.exit(1);
    }
    console.log("6. Factory.quoteUnitPointInUSDC6(卡):", quoteResult.toString());
    if (quoteResult === 0n) {
      console.log("   ❌ 返回 0，购卡会 revert UC_PriceZero()。");
      // 直接调 QuoteHelper(currency=CAD, 1000000)：若返回非 0 说明 Factory 读卡时拿到的是 0
      const qhAbi2 = ["function quoteUnitPointInUSDC6(uint8,uint256) view returns (uint256)"];
      const qh2 = new ethers.Contract(quoteHelperAddr, qhAbi2, ethers.provider);
      try {
        const direct = await Promise.race([
          qh2.quoteUnitPointInUSDC6(0, 1000000n),
          new Promise<bigint>((_, rej) => setTimeout(() => rej(new Error("timeout")), 8000)),
        ]);
        console.log("7. QuoteHelper.quoteUnitPointInUSDC6(CAD, 1000000):", direct.toString());
        if (direct !== 0n) {
          console.log("   → 用 (CAD, 1e6) 报价正常，说明 Factory 读卡时 pointsUnitPriceInCurrencyE6 得到的是 0，需由卡 admin 调用 setPointsUnitPrice(1000000) 或检查卡实现与存储布局。");
        } else {
          console.log("   → 直接传 (CAD, 1e6) 也返回 0：链上 QuoteHelper 很可能参数顺序与源码相反（先 price 后 currency），");
          console.log("     Factory 传 (0, 1000000) 被读成 price=0 故返回 0。修复：重部署 BeamioQuoteHelperV07（当前参数顺序 cardCurrency, unitPointPriceInCurrencyE6）并在两个 Factory 上 setQuoteHelper(新地址)。");
        }
      } catch (e: any) {
        if (e?.message === "timeout") console.log("7. QuoteHelper 直接调用超时，已跳过");
        else console.log("7. QuoteHelper.quoteUnitPointInUSDC6(CAD,1e6):", e?.message || e);
      }
    } else {
      console.log("   ✅ 非 0，链上报价正常");
    }
  }
  console.log();
  console.log("========== 检查完成 ==========");
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
