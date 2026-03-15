/**
 * 验证并修复 Factory 的 defaultRedeemModule
 *
 * 问题：createRedeem 时 UC_RedeemDelegateFailed(空 data)，通常表示 module 不支持 createRedeemBatch
 *（例如旧版 IRedeemModule 仅有 createRedeem）。
 *
 * 用法：
 *   npx hardhat run scripts/verifyAndFixRedeemModule.ts --network base
 *   # 仅检查（不部署）
 *   VERIFY_ONLY=1 npx hardhat run scripts/verifyAndFixRedeemModule.ts --network base
 *   # 强制部署新 Module 并 setRedeemModule（即使当前已有 createRedeemBatch）
 *   FORCE_UPDATE=1 npx hardhat run scripts/verifyAndFixRedeemModule.ts --network base
 */
import { network as networkModule } from "hardhat";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const CREATE_REDEEM_BATCH_SELECTOR = ethers.id("createRedeemBatch(bytes32[],uint256,uint256,uint64,uint64,uint256[],uint256[])").slice(0, 10);
const CREATE_REDEEM_ADMIN_5_SELECTOR = ethers.id("createRedeemAdmin(bytes32,string,uint64,uint64,uint256)").slice(0, 10);

function loadMasterSetup(): { settle_contractAdmin: string[] } {
  const setupPath = path.join(homedir(), ".master.json");
  if (!fs.existsSync(setupPath)) throw new Error("未找到 ~/.master.json");
  const data = JSON.parse(fs.readFileSync(setupPath, "utf-8"));
  if (!data.settle_contractAdmin?.length) throw new Error("settle_contractAdmin 为空");
  return {
    settle_contractAdmin: data.settle_contractAdmin.map((pk: string) => (pk.startsWith("0x") ? pk : `0x${pk}`)),
  };
}

async function main() {
  const { ethers } = await networkModule.connect();
  const networkInfo = await ethers.provider.getNetwork();
  const chainId = Number(networkInfo.chainId);
  const verifyOnly = process.env.VERIFY_ONLY === "1";
  const forceUpdate = process.env.FORCE_UPDATE === "1";

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const factoryFile = path.join(deploymentsDir, `${networkInfo.name}-UserCardFactory.json`);
  if (!fs.existsSync(factoryFile)) {
    throw new Error(`未找到部署文件: ${factoryFile}`);
  }
  const deployment = JSON.parse(fs.readFileSync(factoryFile, "utf-8"));
  const factoryAddress = deployment.contracts?.beamioUserCardFactoryPaymaster?.address;
  const currentModule = deployment.contracts?.beamioUserCardFactoryPaymaster?.redeemModule;
  if (!factoryAddress || !currentModule) {
    throw new Error("部署文件中缺少 factory 或 redeemModule 地址");
  }

  console.log("=".repeat(60));
  console.log("验证 RedeemModule");
  console.log("=".repeat(60));
  console.log("网络:", networkInfo.name, "Chain ID:", chainId);
  console.log("Factory:", factoryAddress);
  console.log("当前 RedeemModule:", currentModule);
  console.log("createRedeemBatch 预期 selector:", CREATE_REDEEM_BATCH_SELECTOR);
  console.log("createRedeemAdmin(5参) 预期 selector:", CREATE_REDEEM_ADMIN_5_SELECTOR);
  console.log();

  const factory = await ethers.getContractAt("BeamioUserCardFactoryPaymasterV07", factoryAddress);
  const onChainModule = await factory.defaultRedeemModule();
  if (onChainModule.toLowerCase() !== currentModule.toLowerCase()) {
    console.log("⚠️  链上 defaultRedeemModule 与部署记录不一致:");
    console.log("   链上:", onChainModule);
    console.log("   记录:", currentModule);
    console.log("   以链上为准继续检查。\n");
  }

  const moduleCode = await ethers.provider.getCode(onChainModule);
  if (moduleCode === "0x") {
    throw new Error(`RedeemModule 地址 ${onChainModule} 没有合约代码`);
  }
  console.log("✅ RedeemModule 有代码，长度:", moduleCode.length, "字符");

  const batchSelectorHex = CREATE_REDEEM_BATCH_SELECTOR.slice(2).toLowerCase();
  const admin5SelectorHex = CREATE_REDEEM_ADMIN_5_SELECTOR.slice(2).toLowerCase();
  const hasBatchSelector = moduleCode.toLowerCase().includes(batchSelectorHex);
  const hasAdmin5Selector = moduleCode.toLowerCase().includes(admin5SelectorHex);
  if (hasBatchSelector && hasAdmin5Selector && !forceUpdate) {
    console.log("✅ RedeemModule 同时包含 createRedeemBatch 与 createRedeemAdmin(5参) selector");
    console.log("\n若仍出现 UC_RedeemDelegateFailed(空)，请检查:");
    console.log("  1. hashes 中是否有重复或已存在的 active redeem");
    console.log("  2. tokenIds/amounts 是否合法（同长、amounts>0）");
    console.log("  3. validAfter/validBefore 时间范围");
    return;
  }
  if (forceUpdate && hasBatchSelector && hasAdmin5Selector) {
    console.log("FORCE_UPDATE=1: 当前 Module 已包含所需 selector，将仍部署新版并更新");
  }

  console.log("❌ RedeemModule 缺少所需 selector，需要更新为新版 BeamioUserCardRedeemModuleVNext");
  console.log("   createRedeemBatch:", hasBatchSelector ? "✅" : "❌");
  console.log("   createRedeemAdmin(5参):", hasAdmin5Selector ? "✅" : "❌");
  if (verifyOnly) {
    console.log("\n仅检查模式，未部署。要修复请去掉 VERIFY_ONLY=1 重新运行。");
    return;
  }

  const master = loadMasterSetup();
  const deployerPk = master.settle_contractAdmin[0];
  if (!deployerPk) throw new Error("settle_contractAdmin[0] 为空");
  const deployer = new ethers.NonceManager(new ethers.Wallet(deployerPk, ethers.provider));
  const deployerAddress = await deployer.getAddress();
  const owner = await factory.owner();
  if (deployerAddress.toLowerCase() !== owner.toLowerCase()) {
    console.log("\n⚠️  当前账户", deployerAddress, "不是 Factory owner");
    console.log("   Owner:", owner);
    console.log("   将只部署新 Module，owner 需自行调用 setRedeemModule。\n");
  }

  let newModuleAddress = process.env.NEW_REDEEM_MODULE_ADDRESS;
  if (newModuleAddress && ethers.isAddress(newModuleAddress)) {
    console.log("\n使用已部署的 RedeemModule (NEW_REDEEM_MODULE_ADDRESS):", newModuleAddress);
  } else {
    console.log("\n部署新的 BeamioUserCardRedeemModuleVNext...");
    const ModuleFactory = await ethers.getContractFactory("BeamioUserCardRedeemModuleVNext");
    const newModule = await ModuleFactory.connect(deployer).deploy();
    await newModule.waitForDeployment();
    newModuleAddress = await newModule.getAddress();
    console.log("✅ 新 RedeemModule 已部署:", newModuleAddress);
  }

  const newCode = await ethers.provider.getCode(newModuleAddress);
  const newHasBatchSelector = newCode.toLowerCase().includes(batchSelectorHex);
  const newHasAdmin5Selector = newCode.toLowerCase().includes(admin5SelectorHex);
  if (newHasBatchSelector && newHasAdmin5Selector) {
    console.log("✅ 新 Module 包含 createRedeemBatch 与 createRedeemAdmin(5参) selector");
  } else {
    console.log("⚠️  bytecode 中未检测到完整 selector 集合（编译器优化可能导致），继续执行");
    console.log("   createRedeemBatch:", newHasBatchSelector ? "✅" : "❌");
    console.log("   createRedeemAdmin(5参):", newHasAdmin5Selector ? "✅" : "❌");
  }

  if (deployerAddress.toLowerCase() === owner.toLowerCase()) {
    console.log("\n调用 setRedeemModule...");
    const ownerFactory = factory.connect(deployer);
    const tx = await ownerFactory.setRedeemModule(newModuleAddress);
    await tx.wait();
    console.log("✅ setRedeemModule 成功, tx:", tx.hash);
  } else {
    console.log("\n请 Factory owner 执行:");
    console.log(`  factory.setRedeemModule("${newModuleAddress}")`);
    const iface = factory.interface;
    const data = iface.encodeFunctionData("setRedeemModule", [newModuleAddress]);
    console.log("  Calldata:", data);
  }

  const outFile = path.join(deploymentsDir, `${networkInfo.name}-UserCardDependencies.json`);
  const depData: Record<string, unknown> = fs.existsSync(outFile)
    ? JSON.parse(fs.readFileSync(outFile, "utf-8"))
    : { network: networkInfo.name, chainId, deployer: deployerAddress, timestamp: new Date().toISOString(), contracts: {} };
  (depData.contracts as Record<string, unknown>).redeemModule = {
    address: newModuleAddress,
    previous: onChainModule,
    note: "BeamioUserCardRedeemModuleVNext (with createRedeemBatch)",
  };
  fs.writeFileSync(outFile, JSON.stringify(depData, null, 2));
  console.log("\n部署记录已更新:", outFile);

  const factoryDeployPath = path.join(deploymentsDir, `${networkInfo.name}-UserCardFactory.json`);
  if (fs.existsSync(factoryDeployPath)) {
    const factoryData = JSON.parse(fs.readFileSync(factoryDeployPath, "utf-8"));
    if (factoryData.contracts?.beamioUserCardFactoryPaymaster) {
      factoryData.contracts.beamioUserCardFactoryPaymaster.redeemModule = newModuleAddress;
      fs.writeFileSync(factoryDeployPath, JSON.stringify(factoryData, null, 2));
      console.log("部署记录已更新:", factoryDeployPath);
    }
  }

  const modulesPath = path.join(deploymentsDir, `${networkInfo.name}-UserCardModules.json`);
  if (fs.existsSync(modulesPath)) {
    const modulesData = JSON.parse(fs.readFileSync(modulesPath, "utf-8"));
    if (modulesData.modules) modulesData.modules.redeemModule = newModuleAddress;
    modulesData.redeemModule = newModuleAddress;
    fs.writeFileSync(modulesPath, JSON.stringify(modulesData, null, 2));
    console.log("部署记录已更新:", modulesPath);
  }
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
