/**
 * 检查 Card Factory / AA Factory 的 QuoteHelper 与 Oracle 链是否正确。
 * 若重新部署过 BeamioUserCardFactoryPaymasterV07 或 BeamioFactoryPaymasterV07，
 * 必须确保：
 *   1. Card Factory.quoteHelper() = 正确的 BeamioQuoteHelperV07 地址
 *   2. QuoteHelper.oracle() = 正确的 BeamioOracle 地址
 *   3. Oracle 已配置卡币种汇率（如 CAD：npm run set:oracle-cad:base）
 *
 * 运行：CARD_FACTORY=0x... QUOTE_HELPER=0x... ORACLE=0x... npx hardhat run scripts/checkOracleQuoteHelperChain.ts --network base
 * 或不带 env，从 config / deployments/base-UserCardFactory.json 解析 Card Factory，Oracle/QuoteHelper 可仍从 FullAccountAndUserCard 读取。
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { resolveBaseCardFactoryAddress } from "./readCanonicalBaseCardFactory.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function main() {
  const { ethers } = await networkModule.connect();
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const fullPath = path.join(deploymentsDir, "base-FullAccountAndUserCard.json");

  let CARD_FACTORY = process.env.CARD_FACTORY || "";
  let AA_FACTORY = process.env.AA_FACTORY || "";
  let EXPECTED_QUOTE_HELPER = process.env.QUOTE_HELPER || "";
  let EXPECTED_ORACLE = process.env.ORACLE || "";

  if (!CARD_FACTORY) CARD_FACTORY = resolveBaseCardFactoryAddress(deploymentsDir);

  if (!CARD_FACTORY || !EXPECTED_QUOTE_HELPER || !EXPECTED_ORACLE || !AA_FACTORY) {
    if (fs.existsSync(fullPath)) {
      const data = JSON.parse(fs.readFileSync(fullPath, "utf-8"));
      const existing = data.existing || {};
      const contracts = data.contracts || {};
      if (!EXPECTED_ORACLE) EXPECTED_ORACLE = existing.beamioOracle || "";
      if (!EXPECTED_QUOTE_HELPER) EXPECTED_QUOTE_HELPER = existing.beamioQuoteHelper || "";
      const aaf = contracts.beamioFactoryPaymaster;
      if (!AA_FACTORY && aaf?.address) AA_FACTORY = aaf.address;
    }
  }

  if (!CARD_FACTORY) {
    console.error("请设置 CARD_FACTORY、或维护 config/base-addresses.json / deployments/base-UserCardFactory.json");
    process.exit(1);
  }

  console.log("========== 两个 Factory 的 QuoteHelper / Oracle 链检查 ==========");
  console.log("期望 QuoteHelper (BeamioQuoteHelperV07):", EXPECTED_QUOTE_HELPER || "(未指定)");
  console.log("期望 Oracle (BeamioOracle):", EXPECTED_ORACLE || "(未指定)");
  console.log();

  const factoryAbi = [
    "function quoteHelper() view returns (address)",
    "function owner() view returns (address)",
  ];
  const quoteHelperAbi = [
    "function oracle() view returns (address)",
    "function owner() view returns (address)",
  ];
  const oracleAbi = ["function getRate(uint8) view returns (uint256)"];

  const checkQuoteHelper = (name: string, factoryAddr: string, expected: string) => {
    return async () => {
      const c = new ethers.Contract(factoryAddr, factoryAbi, ethers.provider);
      const qh = await c.quoteHelper();
      const ok = expected && qh.toLowerCase() === expected.toLowerCase();
      console.log(name + ".quoteHelper():", qh, ok ? "✅" : "❌");
      if (expected && !ok) {
        console.log("   需由 owner 调用 setQuoteHelper(" + expected + ")");
      }
      return qh;
    };
  };

  // 1. Card Factory
  console.log("1. BeamioUserCardFactoryPaymasterV07 (Card Factory):", CARD_FACTORY);
  const cardQuoteHelper = await checkQuoteHelper("   Card Factory", CARD_FACTORY, EXPECTED_QUOTE_HELPER)();
  console.log();

  // 2. AA Factory
  if (AA_FACTORY) {
    console.log("2. BeamioFactoryPaymasterV07 (AA Factory):", AA_FACTORY);
    const aaQuoteHelper = await checkQuoteHelper("   AA Factory", AA_FACTORY, EXPECTED_QUOTE_HELPER)();
    console.log();
  }

  const currentQuoteHelper = cardQuoteHelper;
  if (currentQuoteHelper === ethers.ZeroAddress) {
    console.log("QuoteHelper 未设置于 Card Factory，无法检查 Oracle。请先对 Card Factory 调用 setQuoteHelper(BeamioQuoteHelperV07 地址)");
    process.exit(1);
  }

  // 3. QuoteHelper -> Oracle
  console.log("3. BeamioQuoteHelperV07 (共享):", currentQuoteHelper);
  const quoteHelper = new ethers.Contract(currentQuoteHelper, quoteHelperAbi, ethers.provider);
  const currentOracle = await quoteHelper.oracle();
  const oracleOk = EXPECTED_ORACLE && currentOracle.toLowerCase() === EXPECTED_ORACLE.toLowerCase();
  console.log("   QuoteHelper.oracle():", currentOracle, oracleOk ? "✅" : "❌");
  if (EXPECTED_ORACLE && !oracleOk) {
    console.log("   需由 QuoteHelper owner 调用 setOracle(" + EXPECTED_ORACLE + ")");
  }
  console.log();

  if (currentOracle === ethers.ZeroAddress) {
    console.log("Oracle 未设置。请对 QuoteHelper 调用 setOracle(BeamioOracle 地址)");
    process.exit(1);
  }

  // 4. Oracle CAD 汇率
  console.log("4. BeamioOracle:", currentOracle);
  const oracle = new ethers.Contract(currentOracle, oracleAbi, ethers.provider);
  const CAD = 0;
  let cadRate = 0n;
  try {
    cadRate = await oracle.getRate(CAD);
  } catch (e: any) {
    console.log("   Oracle.getRate(CAD): revert -", e?.message || e);
    console.log("   ❌ 请执行：npm run set:oracle-cad:base");
    process.exit(1);
  }
  console.log("   Oracle.getRate(CAD):", cadRate.toString(), cadRate !== 0n ? "✅" : "❌");
  if (cadRate === 0n) {
    console.log("   ❌ CAD 汇率为 0，请执行：npm run set:oracle-cad:base");
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
