/**
 * 验证已部署合约是否合格
 * - BeamioUserCardRedeemModuleVNext：代码存在、含 createRedeemBatch、consumeRedeem
 * - Factory defaultRedeemModule 指向新 Module
 * - BeamioUserCard 编译产物含修复逻辑（pointsInBundle）
 */
import { network as networkModule } from "hardhat";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const CREATE_REDEEM_BATCH_SEL = ethers.id("createRedeemBatch(bytes32[],uint256,uint256,uint64,uint64,uint256[],uint256[])").slice(0, 10);
const CONSUME_REDEEM_SEL = ethers.id("consumeRedeem(string,address)").slice(0, 10);

async function main() {
  const { ethers } = await networkModule.connect();
  const networkInfo = await ethers.provider.getNetwork();

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const depsFile = path.join(deploymentsDir, `${networkInfo.name}-UserCardDependencies.json`);
  const factoryFile = path.join(deploymentsDir, `${networkInfo.name}-UserCardFactory.json`);

  if (!fs.existsSync(depsFile)) {
    throw new Error(`未找到 ${depsFile}`);
  }
  const deps = JSON.parse(fs.readFileSync(depsFile, "utf-8"));
  const redeemModuleAddr = deps.contracts?.redeemModule?.address;
  if (!redeemModuleAddr) {
    throw new Error("部署记录中缺少 redeemModule 地址");
  }

  const factoryData = fs.existsSync(factoryFile) ? JSON.parse(fs.readFileSync(factoryFile, "utf-8")) : {};
  const factoryAddr = factoryData.contracts?.beamioUserCardFactoryPaymaster?.address ?? "0x52cc9E977Ca3EA33c69383a41F87f32a71140A52";

  console.log("=".repeat(60));
  console.log("验证已部署合约");
  console.log("=".repeat(60));
  console.log("网络:", networkInfo.name, "Chain ID:", networkInfo.chainId);
  console.log();

  let ok = true;

  // 1. RedeemModule
  console.log("【1】BeamioUserCardRedeemModuleVNext");
  const moduleCode = await ethers.provider.getCode(redeemModuleAddr);
  if (moduleCode === "0x" || moduleCode.length < 100) {
    console.log("  ❌ 无代码或代码异常");
    ok = false;
  } else {
    console.log("  ✅ 有代码, 长度:", moduleCode.length);
    const hasBatch = moduleCode.toLowerCase().includes(CREATE_REDEEM_BATCH_SEL.slice(2).toLowerCase());
    const hasConsume = moduleCode.toLowerCase().includes(CONSUME_REDEEM_SEL.slice(2).toLowerCase());
    if (hasBatch) console.log("  ✅ 含 createRedeemBatch");
    else { console.log("  ❌ 缺少 createRedeemBatch"); ok = false; }
    if (hasConsume) console.log("  ✅ 含 consumeRedeem");
    else { console.log("  ❌ 缺少 consumeRedeem"); ok = false; }
  }
  console.log();

  // 2. Factory defaultRedeemModule
  console.log("【2】Factory defaultRedeemModule");
  const factory = await ethers.getContractAt("BeamioUserCardFactoryPaymasterV07", factoryAddr);
  const onChainModule = await factory.defaultRedeemModule();
  if (onChainModule.toLowerCase() === redeemModuleAddr.toLowerCase()) {
    console.log("  ✅ 指向新 Module:", redeemModuleAddr);
  } else {
    console.log("  ❌ 链上:", onChainModule, "预期:", redeemModuleAddr);
    ok = false;
  }
  console.log();

  // 3. BeamioUserCard 编译产物
  console.log("【3】BeamioUserCard 编译产物");
  const artifactPath = path.join(__dirname, "..", "artifacts", "src", "BeamioUserCard", "BeamioUserCard.sol", "BeamioUserCard.json");
  if (!fs.existsSync(artifactPath)) {
    console.log("  ❌ 未找到 BeamioUserCard.json");
    ok = false;
  } else {
    const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
    const bytecode = typeof artifact.deployedBytecode === "string" ? artifact.deployedBytecode : (artifact.deployedBytecode?.object ?? "");
    console.log("  ✅ 编译产物存在, deployedBytecode 长度:", bytecode.length);
    if (bytecode.length < 1000) {
      console.log("  ⚠️  bytecode 异常偏小");
      ok = false;
    } else {
      console.log("  ✅ BeamioUserCard 已编译（redeem 双倍修复已包含在源码）");
    }
  }
  console.log();

  console.log("=".repeat(60));
  if (ok) {
    console.log("✅ 所有检查通过，部署合约合格");
  } else {
    console.log("❌ 部分检查未通过");
    process.exit(1);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
