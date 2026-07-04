/**
 * Deploy AdminStatsQueryModuleV3 (`userHasAnyProgramAsset`) and bind on CoNET Factory.
 * Factory + merchant card addresses unchanged.
 *
 * Run:
 *   npm run clean && npm run compile
 *   npx hardhat run scripts/upgradeAdminStatsQueryModuleV3Conet.ts --network conet
 *
 * Verify:
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardAdminStatsQueryModuleV3 --full
 *   node scripts/exportConetAdminStatsQueryModuleV3VerifyBuildinfo.mjs
 *   CONET_VERIFY_POLL_MAX=180 CONET_VERIFY_ONLY=BeamioUserCardAdminStatsQueryModuleV3 \
 *     npx tsx scripts/verifyConetUserCardModulesOnScan.ts
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ROUTE_STATS_QUERY = 254;
const SMOKE_CARD = process.env.SMOKE_CARD?.trim() || "0xB24D242A320b8dd756572b410645FE41Cd07FC8C";
const SMOKE_EOA = process.env.SMOKE_EOA?.trim() || "0x4728BEeFa5b68E87a611EEC6965f5C5f9b2D5060";

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

  const factoryAbi = [
    "function owner() view returns (address)",
    "function defaultAdminStatsQueryModule() view returns (address)",
    "function setAdminStatsQueryModule(address m) external",
  ];
  const factoryReader = new hhEthers.Contract(factoryAddress, factoryAbi, provider);

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

  const oldAdminStats = (await factoryReader.defaultAdminStatsQueryModule()) as string;

  console.log("=".repeat(64));
  console.log("upgrade AdminStatsQueryModuleV3 (userHasAnyProgramAsset)");
  console.log("=".repeat(64));
  console.log("network", network.name, "chainId", network.chainId.toString());
  console.log("factory", factoryAddress);
  console.log("signer", signerAddress);
  console.log("replacing AdminStatsQuery:", oldAdminStats);

  const AdminStatsFactory = await hhEthers.getContractFactory("BeamioUserCardAdminStatsQueryModuleV3");
  const adminStats = await AdminStatsFactory.connect(signer).deploy(txOverrides);
  await adminStats.waitForDeployment();
  const newAdminAddr = await adminStats.getAddress();
  console.log("\n✅ new AdminStatsQueryModuleV3:", newAdminAddr);

  const routeAbi = ["function selectorModuleKind(bytes4) view returns (uint8)"];
  const routeReader = new hhEthers.Contract(newAdminAddr, routeAbi, provider);

  const checks: Array<{ label: string; signature: string; expected: number }> = [
    {
      label: "userHasAnyProgramAsset -> STATS_QUERY",
      signature: "userHasAnyProgramAsset(address)",
      expected: ROUTE_STATS_QUERY,
    },
    {
      label: "getGlobalAdminToAdminCounters (V1 fallback)",
      signature: "getGlobalAdminToAdminCounters()",
      expected: ROUTE_STATS_QUERY,
    },
    {
      label: "recordUserCumulativeStat (V2 fallback)",
      signature: "recordUserCumulativeStat(address,uint8,uint8,uint256,uint256)",
      expected: 2,
    },
  ];

  for (const c of checks) {
    const sel = hhEthers.id(c.signature).slice(0, 10) as `0x${string}`;
    const route = Number(await routeReader.selectorModuleKind(sel));
    console.log(`selectorModuleKind ${c.label}:`, route, `(expected ${c.expected})`);
    if (route !== c.expected) {
      throw new Error(`路由校验失败: ${c.signature} => ${route}, expected ${c.expected}`);
    }
  }

  const factory = new hhEthers.Contract(factoryAddress, factoryAbi, signer);
  await (await factory.setAdminStatsQueryModule(newAdminAddr, txOverrides)).wait();

  const boundAdmin = (await factoryReader.defaultAdminStatsQueryModule()) as string;
  if (boundAdmin.toLowerCase() !== newAdminAddr.toLowerCase()) {
    throw new Error("setAdminStatsQueryModule 未生效");
  }
  console.log("Factory 已绑定 AdminStatsQueryModuleV3");

  const holdingsAbi = ["function userHasAnyProgramAsset(address userEOA) view returns (bool)"];
  const card = new hhEthers.Contract(SMOKE_CARD, holdingsAbi, provider);
  const smoke = (await card.userHasAnyProgramAsset(SMOKE_EOA)) as boolean;
  console.log(`smoke userHasAnyProgramAsset(${SMOKE_EOA} @ ${SMOKE_CARD}):`, smoke);
  if (!smoke) {
    console.warn("⚠️  smoke 期望 true；若链上持仓已变请忽略");
  }

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const modulesPath = path.join(deploymentsDir, "conet-UserCardModules.json");
  const v3Path = path.join(deploymentsDir, "conet-UserCardModules-v3-program-asset-view.json");

  let prior: Record<string, unknown> = {};
  if (fs.existsSync(modulesPath)) {
    prior = JSON.parse(fs.readFileSync(modulesPath, "utf-8")) as Record<string, unknown>;
  }
  const modules = (prior.modules as Record<string, string>) ?? {};

  const moduleSnapshot = {
    ...prior,
    network: "conet",
    chainId: "224422",
    timestamp: new Date().toISOString(),
    signer: signerAddress,
    factory: factoryAddress,
    modules: {
      ...modules,
      adminStatsQueryModule: newAdminAddr,
    },
    replaced: {
      ...((prior.replaced as Record<string, string>) ?? {}),
      adminStatsQueryModule: oldAdminStats,
    },
    version: "v3-user-has-any-program-asset",
    checks: {
      userHasAnyProgramAssetRoutedToStatsQuery: true,
      smokeCard: SMOKE_CARD,
      smokeEoa: SMOKE_EOA,
      smokeResult: smoke,
    },
  };
  fs.writeFileSync(modulesPath, JSON.stringify(moduleSnapshot, null, 2));
  fs.writeFileSync(v3Path, JSON.stringify(moduleSnapshot, null, 2));
  console.log("写入", modulesPath);
  console.log("写入", v3Path);

  const conetAddressesPath = path.join(deploymentsDir, "conet-addresses.json");
  if (fs.existsSync(conetAddressesPath)) {
    const data = JSON.parse(fs.readFileSync(conetAddressesPath, "utf-8"));
    data.adminStatsQueryModule = newAdminAddr;
    fs.writeFileSync(conetAddressesPath, JSON.stringify(data, null, 2) + "\n", "utf-8");
    console.log("写入", conetAddressesPath);
  }

  console.log("\n下一步 Blockscout 验证:");
  console.log("  node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardAdminStatsQueryModuleV3 --full");
  console.log("  node scripts/exportConetAdminStatsQueryModuleV3VerifyBuildinfo.mjs");
  console.log(
    "  CONET_VERIFY_POLL_MAX=180 CONET_VERIFY_ONLY=BeamioUserCardAdminStatsQueryModuleV3 npx tsx scripts/verifyConetUserCardModulesOnScan.ts",
  );
}

main().catch((e: unknown) => {
  console.error(e);
  process.exit(1);
});
