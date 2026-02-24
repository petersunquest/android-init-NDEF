/**
 * 全面验证新部署的 BeamioAccount 和 BeamioUserCard（CCSA）两个新合约
 */
import { network as networkModule } from "hardhat";

const BEAMIO_ACCOUNT = "0x7FA89BEf84D5047AD9883d6f4A53dE7A0D2815f2";
const CCSA_CARD = "0x57052780925448Ce1dB7aC409cCcCf13Bcc4eb71"; // BASE_CCSA_CARD_ADDRESS
const AA_FACTORY = "0xD86403DD1755F7add19540489Ea10cdE876Cc1CE";
const CARD_FACTORY = "0xbDC8a165820bB8FA23f5d953632409F73E804eE5"; // BASE_CARD_FACTORY
const ENTRY_POINT_V07 = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";

async function main() {
  const { ethers } = await networkModule.connect();

  console.log("=".repeat(60));
  console.log("验证新部署的 BeamioAccount 和 BeamioUserCard");
  console.log("=".repeat(60));

  let allPass = true;

  // ========== 1. BeamioAccount ==========
  console.log("\n【1】BeamioAccount:", BEAMIO_ACCOUNT);
  const accountCode = await ethers.provider.getCode(BEAMIO_ACCOUNT);
  const accountExists = accountCode !== "0x";
  console.log("  合约代码存在:", accountExists ? "✅" : "❌");
  if (!accountExists) allPass = false;

  if (accountExists) {
    const beamioAccount = await ethers.getContractAt("BeamioAccount", BEAMIO_ACCOUNT);
    const ep = await beamioAccount.entryPoint();
    const epOk = ep.toLowerCase() === ENTRY_POINT_V07.toLowerCase();
    console.log("  entryPoint:", ep, epOk ? "✅" : "❌");
    if (!epOk) allPass = false;
  }

  // ========== 2. BeamioUserCard (CCSA) ==========
  console.log("\n【2】BeamioUserCard (CCSA):", CCSA_CARD);
  const cardCode = await ethers.provider.getCode(CCSA_CARD);
  const cardExists = cardCode !== "0x";
  console.log("  合约代码存在:", cardExists ? "✅" : "❌");
  if (!cardExists) allPass = false;

  if (cardExists) {
    const userCard = await ethers.getContractAt("BeamioUserCard", CCSA_CARD);
    const owner = await userCard.owner();
    const gateway = await userCard.factoryGateway();
    const currency = await userCard.currency();
    const priceE6 = await userCard.pointsUnitPriceInCurrencyE6();
    const uri = await userCard.uri(0);

    const gatewayOk = gateway.toLowerCase() === AA_FACTORY.toLowerCase();
    const priceOk = priceE6 === 1000000n;

    console.log("  owner:", owner);
    console.log("  factoryGateway:", gateway, gatewayOk ? "✅" : "❌");
    console.log("  currency:", currency.toString(), currency === 4n ? "(USDC) ✅" : "❌");
    console.log("  priceE6:", priceE6.toString(), priceOk ? "✅" : "❌");
    console.log("  uri:", uri);

    if (!gatewayOk || !priceOk) allPass = false;
  }

  // ========== 3. AA Factory 配置 ==========
  console.log("\n【3】AA Factory 与 CCSA 卡联动");
  const aa = await ethers.getContractAt("BeamioFactoryPaymasterV07", AA_FACTORY);
  const beamioUserCard = await aa.beamioUserCard();
  const aaPointsToCard = beamioUserCard.toLowerCase() === CCSA_CARD.toLowerCase();
  console.log("  beamioUserCard:", beamioUserCard);
  console.log("  指向 CCSA 卡:", aaPointsToCard ? "✅" : "❌");
  if (!aaPointsToCard) allPass = false;

  // ========== 4. Card Factory 存在 ==========
  console.log("\n【4】Card Factory 存在性");
  const cfCode = await ethers.provider.getCode(CARD_FACTORY);
  console.log("  Card Factory 代码存在:", cfCode !== "0x" ? "✅" : "❌");
  if (cfCode === "0x") allPass = false;

  // ========== 总结 ==========
  console.log("\n" + "=".repeat(60));
  console.log(allPass ? "✅ 所有检查通过" : "❌ 部分检查未通过");
  console.log("=".repeat(60));
}

main().catch(console.error);
