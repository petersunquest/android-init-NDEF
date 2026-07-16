/**
 * 部署 IssuedNft V2 + ChargeReward V2 + AdminStatsQuery V2（用户累计统计 + #13 奖励池 + Plan A 用户点赞），
 * 并更新 CoNET Factory 三处 default 模块绑定。不重发商户卡、不重部署 Factory 本体。
 *
 * Stat mint/burn 经 BeamioUserCardModuleMintLib → cardSelfMint / cardSelfBurn（维护 TotalSupplyStorage）。
 * 已部署商户卡须 bytecode 含 cardSelfMint（V27+ 有）；无 cardSelfBurn 的旧卡 POS 核销走 module legacy `_burn` fallback。
 * 仅 mint 的 KPI（点赞等）在旧卡上可随本脚本生效；Unlike 统计需 cardSelfMint/cardSelfBurn 或 legacy fallback。
 *
 * Plan A：`IssuedNftModuleV2.applyUserLikeWithSignature` — 用户 EIP-712 点赞/取消，Master 直调 card（无需 gatewayInvokeCard）。
 * Plan A：`IssuedNftModuleV2.applyDiscoverShareClickWithSignature` — Discover 分享点击（USER_CLICK + REF_CLICK），Master 直调 card。
 *
 * 运行:
 *   npx hardhat run scripts/upgradeUserCumulativeAndRewardPoolModulesConet.ts --network conet
 *
 * 验证（部署成功后）:
 *   npm run clean && npm run compile
 *   # 优先使用 deployments/conet-*-verify-buildinfo.json（与链上 bytecode 一致）
 *   CONET_VERIFY_ONLY=BeamioUserCardIssuedNftModuleV2,BeamioUserCardChargeRewardModuleV2,BeamioUserCardAdminStatsQueryModuleV2 \
 *     npx tsx scripts/verifyConetUserCardModulesOnScan.ts
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";
import { ethers } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ROUTE_ISSUED_NFT = 2;
const ROUTE_CHARGE_REWARD = 5;
const ROUTE_STATS_QUERY = 254;

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
    "function defaultRedeemModule() view returns (address)",
    "function defaultFaucetModule() view returns (address)",
    "function defaultGovernanceModule() view returns (address)",
    "function defaultMembershipStatsModule() view returns (address)",
    "function defaultChargeRewardModule() view returns (address)",
    "function defaultIssuedNftModule() view returns (address)",
    "function defaultAdminStatsQueryModule() view returns (address)",
    "function setIssuedNftModule(address m) external",
    "function setChargeRewardModule(address m) external",
    "function setAdminStatsQueryModule(address m) external",
  ];
  const factoryReader = new hhEthers.Contract(factoryAddress, factoryReaderAbi, provider);

  const envOr = async (envName: string, reader: () => Promise<string>): Promise<string> => {
    const v = process.env[envName]?.trim();
    if (v && hhEthers.isAddress(v)) return hhEthers.getAddress(v);
    return hhEthers.getAddress(await reader());
  };

  const keepRedeem = await envOr("REDEEM_MODULE_ADDRESS", () => factoryReader.defaultRedeemModule() as Promise<string>);
  const keepFaucet = await envOr("FAUCET_MODULE_ADDRESS", () => factoryReader.defaultFaucetModule() as Promise<string>);
  const keepGov = await envOr("GOVERNANCE_MODULE_ADDRESS", () => factoryReader.defaultGovernanceModule() as Promise<string>);
  const keepMem = await envOr(
    "MEMBERSHIP_STATS_MODULE_ADDRESS",
    () => factoryReader.defaultMembershipStatsModule() as Promise<string>,
  );

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

  const oldIssued = (await factoryReader.defaultIssuedNftModule()) as string;
  const oldCharge = (await factoryReader.defaultChargeRewardModule()) as string;
  const oldAdminStats = (await factoryReader.defaultAdminStatsQueryModule()) as string;

  const addrPath = path.join(__dirname, "..", "deployments", "conet-addresses.json");
  const addrData = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, string>;
  const referrerLib = hhEthers.getAddress(addrData.beamioUserCardReferrerLib);
  const transferLib = hhEthers.getAddress(addrData.beamioUserCardTransferLib);

  console.log("=".repeat(64));
  console.log("upgrade UserCumulative + RewardPool (IssuedNft V2 / ChargeReward V2 / AdminStats V2)");
  console.log("=".repeat(64));
  console.log("network", network.name, "chainId", network.chainId.toString());
  console.log("factory", factoryAddress);
  console.log("signer", signerAddress);
  console.log("keeping redeem/faucet/gov/membershipStats:", keepRedeem, keepFaucet, keepGov, keepMem);
  console.log("replacing IssuedNft:", oldIssued);
  console.log("replacing ChargeReward:", oldCharge);
  console.log("replacing AdminStatsQuery:", oldAdminStats);

  const IssuedFactory = await hhEthers.getContractFactory("BeamioUserCardIssuedNftModuleV2");
  const ChargeFactory = await hhEthers.getContractFactory("BeamioUserCardChargeRewardModuleV2", {
    libraries: {
      BeamioUserCardReferrerLib: referrerLib,
      BeamioUserCardTransferLib: transferLib,
    },
  });
  const AdminStatsFactory = await hhEthers.getContractFactory("BeamioUserCardAdminStatsQueryModuleV2");

  const issued = await IssuedFactory.connect(signer).deploy(txOverrides);
  await issued.waitForDeployment();
  const newIssuedAddr = await issued.getAddress();

  const charge = await ChargeFactory.connect(signer).deploy(txOverrides);
  await charge.waitForDeployment();
  const newChargeAddr = await charge.getAddress();

  const adminStats = await AdminStatsFactory.connect(signer).deploy(txOverrides);
  await adminStats.waitForDeployment();
  const newAdminAddr = await adminStats.getAddress();

  console.log("\n✅ new IssuedNftModuleV2:", newIssuedAddr);
  console.log("✅ new ChargeRewardModuleV2:", newChargeAddr);
  console.log("✅ new AdminStatsQueryModuleV2:", newAdminAddr);

  const routeAbi = ["function selectorModuleKind(bytes4) view returns (uint8)"];
  const routeReader = new hhEthers.Contract(newAdminAddr, routeAbi, provider);

  const checks: Array<{ label: string; signature: string; expected: number }> = [
    {
      label: "recordUserCumulativeStat -> ISSUED_NFT",
      signature: "recordUserCumulativeStat(address,uint8,uint8,uint256,uint256)",
      expected: ROUTE_ISSUED_NFT,
    },
    {
      label: "dispatchEventReward13 -> CHARGE_REWARD",
      signature: "dispatchEventReward13(uint256,address,address,uint8,uint256,uint256)",
      expected: ROUTE_CHARGE_REWARD,
    },
    {
      label: "purchaseRewardProgram -> CHARGE_REWARD",
      signature: "purchaseRewardProgram(address,uint8,uint256,uint256,uint8,uint256)",
      expected: ROUTE_CHARGE_REWARD,
    },
    {
      label: "getGlobalAdminToAdminCounters (V1 fallback)",
      signature: "getGlobalAdminToAdminCounters()",
      expected: ROUTE_STATS_QUERY,
    },
    {
      label: "createIssuedNft (V1 fallback)",
      signature: "createIssuedNft(bytes32,uint64,uint64,uint256,uint256,bytes32)",
      expected: ROUTE_ISSUED_NFT,
    },
    {
      label: "applyUserLikeWithSignature -> ISSUED_NFT",
      signature: "applyUserLikeWithSignature(address,uint8,uint256,bool,uint256,bytes32,bytes)",
      expected: ROUTE_ISSUED_NFT,
    },
    {
      label: "applyDiscoverShareClickWithSignature -> ISSUED_NFT",
      signature:
        "applyDiscoverShareClickWithSignature(address,address,uint8,uint256,uint256,bytes32,bytes)",
      expected: ROUTE_ISSUED_NFT,
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
  console.log("新 AdminStatsQueryModuleV2 selector 校验通过");

  const factory = new hhEthers.Contract(factoryAddress, factoryReaderAbi, signer);

  await (await factory.setIssuedNftModule(newIssuedAddr, txOverrides)).wait();
  await (await factory.setChargeRewardModule(newChargeAddr, txOverrides)).wait();
  await (await factory.setAdminStatsQueryModule(newAdminAddr, txOverrides)).wait();

  const boundIssued = (await factory.defaultIssuedNftModule()) as string;
  const boundCharge = (await factory.defaultChargeRewardModule()) as string;
  const boundAdmin = (await factory.defaultAdminStatsQueryModule()) as string;
  if (boundIssued.toLowerCase() !== newIssuedAddr.toLowerCase()) throw new Error("setIssuedNftModule 未生效");
  if (boundCharge.toLowerCase() !== newChargeAddr.toLowerCase()) throw new Error("setChargeRewardModule 未生效");
  if (boundAdmin.toLowerCase() !== newAdminAddr.toLowerCase()) throw new Error("setAdminStatsQueryModule 未生效");
  console.log("Factory 已绑定三个 V2 模块并已验证");

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const modulesPath = path.join(deploymentsDir, "conet-UserCardModules.json");
  const v2Path = path.join(deploymentsDir, "conet-UserCardModules-v2-cumulative-reward.json");

  const moduleSnapshot = {
    network: "conet",
    chainId: "224422",
    timestamp: new Date().toISOString(),
    signer: signerAddress,
    factory: factoryAddress,
    modules: {
      redeemModule: keepRedeem,
      issuedNftModule: newIssuedAddr,
      faucetModule: keepFaucet,
      governanceModule: keepGov,
      membershipStatsModule: keepMem,
      adminStatsQueryModule: newAdminAddr,
      chargeRewardModule: newChargeAddr,
    },
    replaced: {
      issuedNftModule: oldIssued,
      chargeRewardModule: oldCharge,
      adminStatsQueryModule: oldAdminStats,
    },
    version: "v2-user-cumulative-reward-pool",
    checks: {
      recordUserCumulativeStatRoutedToIssuedNft: true,
      dispatchEventReward13RoutedToChargeReward: true,
    },
  };
  fs.writeFileSync(modulesPath, JSON.stringify(moduleSnapshot, null, 2));
  fs.writeFileSync(v2Path, JSON.stringify(moduleSnapshot, null, 2));
  console.log("写入", modulesPath);
  console.log("写入", v2Path);

  const conetAddressesPath = path.join(deploymentsDir, "conet-addresses.json");
  if (fs.existsSync(conetAddressesPath)) {
    const data = JSON.parse(fs.readFileSync(conetAddressesPath, "utf-8"));
    data.issuedNftModule = newIssuedAddr;
    data.chargeRewardModule = newChargeAddr;
    data.adminStatsQueryModule = newAdminAddr;
    fs.writeFileSync(conetAddressesPath, JSON.stringify(data, null, 2) + "\n", "utf-8");
    console.log("写入", conetAddressesPath);
  }

  console.log("\n下一步 Blockscout 验证（见 .cursor/rules/conet-mainnet-blockscout-verify.mdc）:");
  console.log("  node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardIssuedNftModuleV2 --full");
  console.log("  node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardChargeRewardModuleV2 --full");
  console.log("  node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardAdminStatsQueryModuleV2 --full");
  console.log("  node scripts/exportConetUserCardModuleV2VerifyBuildinfo.mjs");
  console.log(
    "  CONET_VERIFY_POLL_MAX=180 CONET_VERIFY_ONLY=BeamioUserCardIssuedNftModuleV2,BeamioUserCardChargeRewardModuleV2,BeamioUserCardAdminStatsQueryModuleV2 npx tsx scripts/verifyConetUserCardModulesOnScan.ts",
  );
}

main().catch((e: unknown) => {
  console.error(e);
  process.exit(1);
});
