/**
 * 仅重部署 ChargeRewardModuleV2（onlyGatewayOrFactoryPaymaster），并更新 CoNET Factory defaultChargeRewardModule。
 * 使 Master relayer AA 直调 card（Plan A）可执行 dispatchEventReward13 / purchaseRewardProgram / recordTopupCumulativeStat，
 * 无需 Factory bytecode 含 gatewayInvokeCard。
 *
 * 运行:
 *   npm run clean && npm run compile
 *   npx hardhat run scripts/upgradeChargeRewardModulePaymasterRelayConet.ts --network conet
 *
 * 验证:
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardChargeRewardModuleV2 --full
 *   node scripts/exportConetUserCardModuleV2VerifyBuildinfo.mjs
 *   CONET_VERIFY_ONLY=BeamioUserCardChargeRewardModuleV2 npx tsx scripts/verifyConetUserCardModulesOnScan.ts
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";
import { ethers } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function loadSignerPk(): string {
  if (process.env.PRIVATE_KEY?.trim()) {
    return process.env.PRIVATE_KEY.startsWith("0x")
      ? process.env.PRIVATE_KEY
      : `0x${process.env.PRIVATE_KEY}`;
  }
  const setupPath = path.join(homedir(), ".master.json");
  if (!fs.existsSync(setupPath)) {
    throw new Error("未找到 PRIVATE_KEY，且 ~/.master.json 不存在");
  }
  const data = JSON.parse(fs.readFileSync(setupPath, "utf-8"));
  const pk = data?.settle_contractAdmin?.[0];
  if (!pk || typeof pk !== "string") {
    throw new Error("未找到 PRIVATE_KEY，且 ~/.master.json 缺少 settle_contractAdmin[0]");
  }
  return pk.startsWith("0x") ? pk : `0x${pk}`;
}

async function main() {
  const factoryAddress =
    process.env.FACTORY?.trim() || "0xfA52a0CcC96C19cF4b6Ea864615F6d52BD0774FB";

  const { ethers: hhEthers } = await networkModule.connect();
  const provider = hhEthers.provider;
  const network = await provider.getNetwork();
  if (Number(network.chainId) !== 224422) {
    throw new Error(`本脚本仅用于 CoNET 224422，当前 chainId=${network.chainId}`);
  }

  const pk = loadSignerPk();
  const signer = new hhEthers.NonceManager(new hhEthers.Wallet(pk, provider));
  const signerAddress = await signer.getAddress();

  const feeData = await provider.getFeeData();
  const txOverrides: { maxFeePerGas?: bigint; maxPriorityFeePerGas?: bigint } = {};
  if (feeData.maxFeePerGas) txOverrides.maxFeePerGas = feeData.maxFeePerGas * 2n;
  if (feeData.maxPriorityFeePerGas) txOverrides.maxPriorityFeePerGas = feeData.maxPriorityFeePerGas * 2n;

  const factoryReaderAbi = [
    "function owner() view returns (address)",
    "function defaultChargeRewardModule() view returns (address)",
    "function setChargeRewardModule(address m) external",
  ];
  const factoryReader = new hhEthers.Contract(factoryAddress, factoryReaderAbi, provider);

  try {
    const owner = (await factoryReader.owner()) as string;
    if (owner.toLowerCase() !== signerAddress.toLowerCase()) {
      throw new Error(`signer 非 factory owner：owner=${owner} signer=${signerAddress}`);
    }
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    if (msg.includes("signer")) throw e;
    console.warn("⚠️  owner() 校验跳过:", msg);
  }

  const oldCharge = (await factoryReader.defaultChargeRewardModule()) as string;

  const addrPath = path.join(__dirname, "..", "deployments", "conet-addresses.json");
  const addrData = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, string>;
  const referrerLib = hhEthers.getAddress(addrData.beamioUserCardReferrerLib);
  const transferLib = hhEthers.getAddress(addrData.beamioUserCardTransferLib);

  console.log("=".repeat(64));
  console.log("upgrade ChargeRewardModuleV2 (onlyGatewayOrFactoryPaymaster)");
  console.log("=".repeat(64));
  console.log("network", network.name, "chainId", network.chainId.toString());
  console.log("factory", factoryAddress);
  console.log("signer", signerAddress);
  console.log("replacing ChargeReward:", oldCharge);

  const ChargeFactory = await hhEthers.getContractFactory("BeamioUserCardChargeRewardModuleV2", {
    libraries: {
      BeamioUserCardReferrerLib: referrerLib,
      BeamioUserCardTransferLib: transferLib,
    },
  });

  const charge = await ChargeFactory.connect(signer).deploy(txOverrides);
  await charge.waitForDeployment();
  const newChargeAddr = await charge.getAddress();
  console.log("\n✅ new ChargeRewardModuleV2:", newChargeAddr);

  const factory = new hhEthers.Contract(factoryAddress, factoryReaderAbi, signer);
  await (await factory.setChargeRewardModule(newChargeAddr, txOverrides)).wait();

  const boundCharge = (await factory.defaultChargeRewardModule()) as string;
  if (boundCharge.toLowerCase() !== newChargeAddr.toLowerCase()) {
    throw new Error("setChargeRewardModule 未生效");
  }
  console.log("Factory defaultChargeRewardModule 已更新");

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const outPath = path.join(deploymentsDir, "conet-ChargeRewardModuleV2-paymaster-relay.json");
  const snapshot = {
    network: "conet",
    chainId: "224422",
    timestamp: new Date().toISOString(),
    signer: signerAddress,
    factory: factoryAddress,
    chargeRewardModule: newChargeAddr,
    replacedChargeRewardModule: oldCharge,
    version: "v2-charge-reward-paymaster-relay",
    note: "dispatchEventReward13 / purchaseRewardProgram / recordTopupCumulativeStat allow Factory isPaymaster (relayer AA)",
  };
  fs.writeFileSync(outPath, JSON.stringify(snapshot, null, 2));
  console.log("写入", outPath);

  const modulesPath = path.join(deploymentsDir, "conet-UserCardModules.json");
  if (fs.existsSync(modulesPath)) {
    const modMain = JSON.parse(fs.readFileSync(modulesPath, "utf-8")) as Record<string, unknown>;
    if (modMain.modules && typeof modMain.modules === "object") {
      (modMain.modules as Record<string, string>).chargeRewardModule = newChargeAddr;
    }
    if (modMain.replaced && typeof modMain.replaced === "object") {
      (modMain.replaced as Record<string, string>).chargeRewardModule = oldCharge;
    }
    fs.writeFileSync(modulesPath, JSON.stringify(modMain, null, 2));
    console.log("更新", modulesPath);
  }

  const v2Path = path.join(deploymentsDir, "conet-UserCardModules-v2-cumulative-reward.json");
  if (fs.existsSync(v2Path)) {
    const mod = JSON.parse(fs.readFileSync(modulesPath, "utf-8")) as Record<string, unknown>;
    if (mod.modules && typeof mod.modules === "object") {
      (mod.modules as Record<string, string>).chargeRewardModule = newChargeAddr;
    }
    if (mod.replaced && typeof mod.replaced === "object") {
      (mod.replaced as Record<string, string>).chargeRewardModule = oldCharge;
    }
    mod.chargeRewardPaymasterRelayUpgrade = snapshot;
    fs.writeFileSync(v2Path, JSON.stringify(mod, null, 2));
    console.log("更新", v2Path);
  }

  if (fs.existsSync(addrPath)) {
    const data = JSON.parse(fs.readFileSync(addrPath, "utf-8"));
    data.chargeRewardModule = newChargeAddr;
    fs.writeFileSync(addrPath, JSON.stringify(data, null, 2) + "\n", "utf-8");
    console.log("更新", addrPath);
  }

  console.log("\n下一步 Blockscout 验证:");
  console.log("  npm run clean && npm run compile");
  console.log("  node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardChargeRewardModuleV2 --full");
  console.log("  node scripts/exportConetUserCardModuleV2VerifyBuildinfo.mjs");
  console.log(
    "  CONET_VERIFY_POLL_MAX=180 CONET_VERIFY_ONLY=BeamioUserCardChargeRewardModuleV2 npx tsx scripts/verifyConetUserCardModulesOnScan.ts",
  );
}

main().catch((e: unknown) => {
  console.error(e);
  process.exit(1);
});
