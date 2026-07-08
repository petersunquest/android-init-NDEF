/**
 * 批量 configureEventRewardRulesBatch：重部署 ChargeReward V2 + AdminStatsQuery V3，
 * 更新 CoNET Factory 两处 default 模块绑定。不重部署 Factory / IssuedNft / 商家卡地址。
 *
 * 运行:
 *   npm run clean && npm run compile
 *   npx hardhat run scripts/upgradeChargeRewardBatchConfigureModulesConet.ts --network conet
 *
 * 验证（部署成功后）:
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardChargeRewardModuleV2 --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardAdminStatsQueryModuleV3 --full
 *   node scripts/exportConetUserCardModuleV2VerifyBuildinfo.mjs
 *   CONET_VERIFY_POLL_MAX=180 CONET_VERIFY_ONLY=BeamioUserCardChargeRewardModuleV2,BeamioUserCardAdminStatsQueryModuleV3 \
 *     npx tsx scripts/verifyConetUserCardModulesOnScan.ts
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ROUTE_CHARGE_REWARD = 5;
const ROUTE_STATS_QUERY = 254; // type(uint8).max - 1

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
    "function defaultIssuedNftModule() view returns (address)",
    "function defaultChargeRewardModule() view returns (address)",
    "function defaultAdminStatsQueryModule() view returns (address)",
    "function setChargeRewardModule(address m) external",
    "function setAdminStatsQueryModule(address m) external",
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
  const oldAdminStats = (await factoryReader.defaultAdminStatsQueryModule()) as string;
  const keepIssued = (await factoryReader.defaultIssuedNftModule()) as string;

  const addrPath = path.join(__dirname, "..", "deployments", "conet-addresses.json");
  const addrData = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, string>;
  const referrerLib = hhEthers.getAddress(addrData.beamioUserCardReferrerLib);
  const transferLib = hhEthers.getAddress(addrData.beamioUserCardTransferLib);

  console.log("=".repeat(64));
  console.log("upgrade ChargeReward batch configure (ChargeReward V2 + AdminStats V3)");
  console.log("=".repeat(64));
  console.log("network", network.name, "chainId", network.chainId.toString());
  console.log("factory", factoryAddress);
  console.log("signer", signerAddress);
  console.log("keeping IssuedNft:", keepIssued);
  console.log("replacing ChargeReward:", oldCharge);
  console.log("replacing AdminStatsQuery:", oldAdminStats);

  const ChargeFactory = await hhEthers.getContractFactory("BeamioUserCardChargeRewardModuleV2", {
    libraries: {
      BeamioUserCardReferrerLib: referrerLib,
      BeamioUserCardTransferLib: transferLib,
    },
  });

  const preCharge = process.env.CHARGE_REWARD_MODULE_ADDRESS?.trim();
  const preAdminStats = process.env.ADMIN_STATS_QUERY_MODULE_ADDRESS?.trim();
  let newChargeAddr: string;
  let newAdminStatsAddr: string;

  if (preCharge && hhEthers.isAddress(preCharge) && preAdminStats && hhEthers.isAddress(preAdminStats)) {
    newChargeAddr = hhEthers.getAddress(preCharge);
    newAdminStatsAddr = hhEthers.getAddress(preAdminStats);
    console.log("\n↪️  复用已部署模块（跳过 deploy）");
    console.log("   ChargeRewardModuleV2:", newChargeAddr);
    console.log("   AdminStatsQueryModuleV3:", newAdminStatsAddr);
  } else {
    const charge = await ChargeFactory.connect(signer).deploy(txOverrides);
    await charge.waitForDeployment();
    newChargeAddr = await charge.getAddress();

    const AdminStatsFactory = await hhEthers.getContractFactory("BeamioUserCardAdminStatsQueryModuleV3");
    const adminStats = await AdminStatsFactory.connect(signer).deploy(txOverrides);
    await adminStats.waitForDeployment();
    newAdminStatsAddr = await adminStats.getAddress();

    console.log("\n✅ new ChargeRewardModuleV2:", newChargeAddr);
    console.log("✅ new AdminStatsQueryModuleV3:", newAdminStatsAddr);
  }

  const chargeIface = new hhEthers.Interface([
    "function configureEventRewardRule(uint256,bool,uint8,uint8,uint256,uint256,uint256)",
    "function configureEventRewardRulesBatch((uint256,bool,uint8,uint8,uint256,uint256,uint256)[])",
    "function dispatchEventReward13(uint256,address,address,uint8,uint256,uint256)",
    "function getRewardRule(uint256)",
  ]);
  const chargeCode = await provider.getCode(newChargeAddr);
  for (const fn of [
    "configureEventRewardRule(uint256,bool,uint8,uint8,uint256,uint256,uint256)",
    "configureEventRewardRulesBatch((uint256,bool,uint8,uint8,uint256,uint256,uint256)[])",
    "dispatchEventReward13(uint256,address,address,uint8,uint256,uint256)",
    "getRewardRule(uint256)",
  ]) {
    const sel = chargeIface.getFunction(fn)?.selector;
    if (!sel || !chargeCode.toLowerCase().includes(sel.slice(2).toLowerCase())) {
      throw new Error(`ChargeRewardModuleV2 缺少 selector ${fn} (${sel})`);
    }
    console.log("ChargeReward bytecode selector ok:", fn, sel);
  }

  const routeAbi = ["function selectorModuleKind(bytes4) view returns (uint8)"];
  const routeReader = new hhEthers.Contract(newAdminStatsAddr, routeAbi, provider);
  const routeChecks: Array<{ label: string; signature: string; expected: number }> = [
    {
      label: "configureEventRewardRulesBatch -> CHARGE_REWARD",
      signature: "configureEventRewardRulesBatch((uint256,bool,uint8,uint8,uint256,uint256,uint256)[])",
      expected: ROUTE_CHARGE_REWARD,
    },
    {
      label: "configureEventRewardRule -> CHARGE_REWARD (regression)",
      signature: "configureEventRewardRule(uint256,bool,uint8,uint8,uint256,uint256,uint256)",
      expected: ROUTE_CHARGE_REWARD,
    },
    {
      label: "dispatchEventReward13 -> CHARGE_REWARD (regression)",
      signature: "dispatchEventReward13(uint256,address,address,uint8,uint256,uint256)",
      expected: ROUTE_CHARGE_REWARD,
    },
    {
      label: "getGlobalAdminToAdminCounters -> STATS_QUERY (regression)",
      signature: "getGlobalAdminToAdminCounters()",
      expected: ROUTE_STATS_QUERY,
    },
    {
      label: "userHasAnyProgramAsset -> STATS_QUERY (V3 regression)",
      signature: "userHasAnyProgramAsset(address)",
      expected: ROUTE_STATS_QUERY,
    },
    {
      label: "applyUserLikeWithSignature -> ISSUED_NFT (regression)",
      signature: "applyUserLikeWithSignature(address,uint8,uint256,bool,uint256,bytes32,bytes)",
      expected: 2,
    },
    {
      label: "fundSocialExchangeUsdcEscrow -> CHARGE_REWARD (regression)",
      signature: "fundSocialExchangeUsdcEscrow(address,uint256)",
      expected: ROUTE_CHARGE_REWARD,
    },
  ];
  for (const c of routeChecks) {
    const sel = hhEthers.id(c.signature).slice(0, 10) as `0x${string}`;
    const route = Number(await routeReader.selectorModuleKind(sel));
    console.log(`AdminStats selectorModuleKind ${c.label}:`, route, `(expected ${c.expected})`);
    if (route !== c.expected) {
      throw new Error(`AdminStats 路由校验失败: ${c.signature} => ${route}, expected ${c.expected}`);
    }
  }
  console.log("AdminStats batch + regression selector 校验通过");

  const factory = new hhEthers.Contract(factoryAddress, factoryReaderAbi, signer);
  await (await factory.setChargeRewardModule(newChargeAddr, txOverrides)).wait();
  await (await factory.setAdminStatsQueryModule(newAdminStatsAddr, txOverrides)).wait();

  const boundCharge = (await factory.defaultChargeRewardModule()) as string;
  const boundAdminStats = (await factory.defaultAdminStatsQueryModule()) as string;
  if (boundCharge.toLowerCase() !== newChargeAddr.toLowerCase()) throw new Error("setChargeRewardModule 未生效");
  if (boundAdminStats.toLowerCase() !== newAdminStatsAddr.toLowerCase()) {
    throw new Error("setAdminStatsQueryModule 未生效");
  }
  console.log("Factory 已绑定 ChargeReward + AdminStats 模块并已验证");

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const modulesPath = path.join(deploymentsDir, "conet-UserCardModules.json");
  const outPath = path.join(deploymentsDir, "conet-ChargeRewardBatchConfigureModules.json");

  const prev = fs.existsSync(modulesPath)
    ? (JSON.parse(fs.readFileSync(modulesPath, "utf-8")) as Record<string, unknown>)
    : {};

  const moduleSnapshot = {
    ...prev,
    network: "conet",
    chainId: "224422",
    timestamp: new Date().toISOString(),
    signer: signerAddress,
    factory: factoryAddress,
    modules: {
      ...((prev.modules as Record<string, string>) ?? {}),
      chargeRewardModule: newChargeAddr,
      adminStatsQueryModule: newAdminStatsAddr,
    },
    replaced: {
      ...((prev.replaced as Record<string, string>) ?? {}),
      chargeRewardModule: oldCharge,
      adminStatsQueryModule: oldAdminStats,
    },
    version: "v6-charge-reward-batch-configure",
    checks: {
      configureEventRewardRulesBatchRoutedToChargeReward: true,
      configureEventRewardRuleRoutedToChargeReward: true,
      dispatchEventReward13RoutedToChargeReward: true,
    },
    note: "ChargeReward configureEventRewardRulesBatch + AdminStats V3 routes batch selector to kind 5",
  };
  fs.writeFileSync(modulesPath, JSON.stringify(moduleSnapshot, null, 2));
  fs.writeFileSync(outPath, JSON.stringify(moduleSnapshot, null, 2));
  console.log("写入", modulesPath);
  console.log("写入", outPath);

  if (fs.existsSync(addrPath)) {
    const data = JSON.parse(fs.readFileSync(addrPath, "utf-8"));
    data.chargeRewardModule = newChargeAddr;
    data.adminStatsQueryModule = newAdminStatsAddr;
    fs.writeFileSync(addrPath, JSON.stringify(data, null, 2) + "\n", "utf-8");
    console.log("更新", addrPath);
  }

  console.log("\n下一步 Blockscout 验证:");
  console.log("  node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardChargeRewardModuleV2 --full");
  console.log("  node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardAdminStatsQueryModuleV3 --full");
  console.log("  node scripts/exportConetUserCardModuleV2VerifyBuildinfo.mjs");
  console.log(
    "  CONET_VERIFY_POLL_MAX=180 CONET_VERIFY_ONLY=BeamioUserCardChargeRewardModuleV2,BeamioUserCardAdminStatsQueryModuleV3 npx tsx scripts/verifyConetUserCardModulesOnScan.ts",
  );
  console.log("\n同步 ABI / API:");
  console.log("  node scripts/syncBeamioUserCardToX402sdk.mjs");
  console.log("  cd src/x402sdk && npm run build && git commit/push && 重启 API");
}

main().catch((e: unknown) => {
  console.error(e);
  process.exit(1);
});
