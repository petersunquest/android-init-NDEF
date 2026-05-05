/**
 * 部署 IssuedNftModule + AdminStatsQueryModule（含 issuedNftSharedMetadataHash 路由）并仅更新 Factory 上这两处绑定。
 * 其余模块保持链上原地址（通过 env 传入与当前 factory 一致），避免误替换。
 *
 * 运行（Base 主网）：
 *   FACTORY=0x52cc9E977Ca3EA33c69383a41F87f32a71140A52 \
 *   REDEEM_MODULE_ADDRESS=0x17Db9029dEd9d5F4e4cF819d3E8eC742cf0c79e6 \
 *   FAUCET_MODULE_ADDRESS=0xb84d74E08Ea519ffCFBD8F8c5D988943e3a82a0F \
 *   GOVERNANCE_MODULE_ADDRESS=0xc12fBEA081aD0B8143747Fd2935CE6b61734eB41 \
 *   MEMBERSHIP_STATS_MODULE_ADDRESS=0xbf2e5F463dF31FD483faA738FB05d9ffb17031c0 \
 *   npx hardhat run scripts/upgradeIssuedNftAndAdminStatsModulesRegisterSeries.ts --network base
 *
 * 未传四个 *_MODULE_ADDRESS 时，脚本从当前 factory 只读地址（避免误写错）。
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";
import { ethers } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ROUTE_REDEEM = 0;
const ROUTE_STATS_QUERY = 254;
const ROUTE_ISSUED_NFT = 2;

function loadSignerPk(): string {
  if (process.env.PRIVATE_KEY && process.env.PRIVATE_KEY.trim()) {
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
    process.env.FACTORY?.trim() || "0x52cc9E977Ca3EA33c69383a41F87f32a71140A52";

  const { ethers: hhEthers } = await networkModule.connect();
  const provider = hhEthers.provider;
  const network = await provider.getNetwork();
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
    "function defaultIssuedNftModule() view returns (address)",
    "function defaultAdminStatsQueryModule() view returns (address)",
    "function setIssuedNftModule(address m) external",
    "function setAdminStatsQueryModule(address m) external",
  ];
  const factoryReader = new hhEthers.Contract(factoryAddress, factoryReaderAbi, provider);

  const envOr = async (envName: string, reader: () => Promise<string>): Promise<string> => {
    const v = process.env[envName]?.trim();
    if (v && hhEthers.isAddress(v)) return hhEthers.getAddress(v);
    return hhEthers.getAddress(await reader());
  };

  const keepRedeem = await envOr("REDEEM_MODULE_ADDRESS", () => factoryReader.defaultRedeemModule() as Promise<string>);
  const keepFaucet = await envOr(
    "FAUCET_MODULE_ADDRESS",
    () => factoryReader.defaultFaucetModule() as Promise<string>,
  );
  const keepGov = await envOr(
    "GOVERNANCE_MODULE_ADDRESS",
    () => factoryReader.defaultGovernanceModule() as Promise<string>,
  );
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
  const oldAdminStats = (await factoryReader.defaultAdminStatsQueryModule()) as string;

  console.log("=".repeat(64));
  console.log("upgrade IssuedNftModule + AdminStatsQueryModule (registerSeries hash read)");
  console.log("=".repeat(64));
  console.log("network", network.name, "chainId", network.chainId.toString());
  console.log("factory", factoryAddress);
  console.log("signer", signerAddress);
  console.log("keeping redeem/faucet/gov/membershipStats:", keepRedeem, keepFaucet, keepGov, keepMem);
  console.log("replacing IssuedNft:", oldIssued);
  console.log("replacing AdminStatsQuery:", oldAdminStats);

  const IssuedFactory = await hhEthers.getContractFactory("BeamioUserCardIssuedNftModuleV1");
  const AdminStatsFactory = await hhEthers.getContractFactory("BeamioUserCardAdminStatsQueryModuleV1");

  const issued = await IssuedFactory.connect(signer).deploy(txOverrides);
  await issued.waitForDeployment();
  const newIssuedAddr = await issued.getAddress();

  const adminStats = await AdminStatsFactory.connect(signer).deploy(txOverrides);
  await adminStats.waitForDeployment();
  const newAdminAddr = await adminStats.getAddress();

  console.log("\n✅ new IssuedNftModule:", newIssuedAddr);
  console.log("✅ new AdminStatsQueryModule:", newAdminAddr);

  const routeAbi = ["function selectorModuleKind(bytes4) view returns (uint8)"];
  const routeReader = new hhEthers.Contract(newAdminAddr, routeAbi, provider);

  const checks: Array<{ label: string; signature: string; expected: number }> = [
    {
      label: "createRedeemAdmin(...,uint256)",
      signature: "createRedeemAdmin(bytes32,string,uint64,uint64,uint256)",
      expected: ROUTE_REDEEM,
    },
    {
      label: "getGlobalAdminToAdminHourlyData(uint256)",
      signature: "getGlobalAdminToAdminHourlyData(uint256)",
      expected: ROUTE_STATS_QUERY,
    },
    {
      label: "getGlobalAdminToAdminCounters()",
      signature: "getGlobalAdminToAdminCounters()",
      expected: ROUTE_STATS_QUERY,
    },
    {
      label: "issuedNftSharedMetadataHash(uint256) -> ISSUED_NFT route",
      signature: "issuedNftSharedMetadataHash(uint256)",
      expected: ROUTE_ISSUED_NFT,
    },
    {
      label: "createIssuedNft -> ISSUED_NFT route",
      signature: "createIssuedNft(bytes32,uint64,uint64,uint256,uint256,bytes32)",
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
  console.log("新 AdminStatsQueryModule selector 校验通过");

  const factory = new hhEthers.Contract(factoryAddress, factoryReaderAbi, signer);

  await (await factory.setIssuedNftModule(newIssuedAddr, txOverrides)).wait();
  await (await factory.setAdminStatsQueryModule(newAdminAddr, txOverrides)).wait();

  const boundIssued = (await factory.defaultIssuedNftModule()) as string;
  const boundAdmin = (await factory.defaultAdminStatsQueryModule()) as string;
  if (boundIssued.toLowerCase() !== newIssuedAddr.toLowerCase()) throw new Error("setIssuedNftModule 未生效");
  if (boundAdmin.toLowerCase() !== newAdminAddr.toLowerCase()) throw new Error("setAdminStatsQueryModule 未生效");
  console.log("Factory 已绑定新模块并已验证");

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const factoryPath = path.join(deploymentsDir, "base-UserCardFactory.json");
  const modulesPath = path.join(deploymentsDir, "base-UserCardModules.json");

  if (fs.existsSync(factoryPath)) {
    const data = JSON.parse(fs.readFileSync(factoryPath, "utf-8"));
    if (data.contracts?.beamioUserCardFactoryPaymaster) {
      const bp = data.contracts.beamioUserCardFactoryPaymaster;
      bp.issuedNftModule = newIssuedAddr;
      bp.adminStatsQueryModule = newAdminAddr;
      bp.redeemModule = keepRedeem;
      bp.faucetModule = keepFaucet;
      bp.governanceModule = keepGov;
      bp.membershipStatsModule = keepMem;
      data.timestamp = new Date().toISOString();
      data.note =
        `IssuedNft + AdminStatsQuery upgrade (${newIssuedAddr.slice(0, 10)}… / ${newAdminAddr.slice(0, 10)}…) registerSeries`;
      fs.writeFileSync(factoryPath, JSON.stringify(data, null, 2));
      console.log("写入", factoryPath);
    }
  }

  const moduleSnapshot = {
    network: network.name,
    chainId: network.chainId.toString(),
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
    },
    replaced: { issuedNftModule: oldIssued, adminStatsQueryModule: oldAdminStats },
    checks: { issuedNftSharedMetadataHashRoutedToIssuedNft: true },
  };
  fs.writeFileSync(modulesPath, JSON.stringify(moduleSnapshot, null, 2));
  console.log("写入", modulesPath);

  const slugIssued = `${newIssuedAddr.slice(0, 10)}`;
  const slugAdmin = `${newAdminAddr.slice(0, 10)}`;

  const verifyIssuedPath = path.join(
    deploymentsDir,
    `base-BeamioUserCardIssuedNftModuleV1-${slugIssued}-basescan-verify-meta.txt`,
  );
  const verifyAdminPath = path.join(
    deploymentsDir,
    `base-AdminStatsQueryModule-${slugAdmin}-basescan-verify-meta.txt`,
  );

  const issuedTxt = `# BaseScan verification — BeamioUserCardIssuedNftModuleV1 (coupon registerSeries support)

Deployed: https://basescan.org/address/${newIssuedAddr}
Script: scripts/upgradeIssuedNftAndAdminStatsModulesRegisterSeries.ts

## Adds

- issuedNftSharedMetadataHash(uint256) view (delegatecall storage read)

## Standard JSON input

deployments/base-BeamioUserCardIssuedNftModuleV1-standard-input-FULL.json

Regenerate:
  npm run clean && npm run compile
  node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardIssuedNftModuleV1 --full

## Contract Name

  project/src/BeamioUserCard/IssuedNftModule.sol:BeamioUserCardIssuedNftModuleV1

## Constructor arguments

**None**

## Compiler

Solidity **0.8.33**, optimizer runs **0**, **viaIR: true**, **cancun**, **bytecodeHash: none**, **strip** (matches Hardhat / FULL JSON).

## Previous module

${oldIssued}

## Factory configuration

FACTORY=${factoryAddress}
`;
  const adminTxt = `# BaseScan 验证 — AdminStatsQueryModule ${newAdminAddr}

## 路由（registerSeries）

| Selector | ROUTE_ISSUED_NFT (=2) / 备注 |
|---------|-----------------------------|
| issuedNftSharedMetadataHash(uint256) | ROUTE_ISSUED_NFT (${ROUTE_ISSUED_NFT}) |
| createIssuedNft(...) | ROUTE_ISSUED_NFT (${ROUTE_ISSUED_NFT}) |

## Contract Name

project/src/BeamioUserCard/AdminStatsQueryModule.sol:BeamioUserCardAdminStatsQueryModuleV1

## Standard JSON

deployments/base-AdminStatsQueryModule-standard-input-FULL.json

\`\`\`bash
npm run clean && npm run compile
node scripts/exportStandardJsonFromBuildInfo.mjs AdminStatsQueryModule --full
\`\`\`

## Factory

${factoryAddress}

## Previous module

${oldAdminStats}

## BaseScan

https://basescan.org/address/${newAdminAddr}#code
`;
  fs.writeFileSync(verifyIssuedPath, issuedTxt.trim() + "\n", "utf-8");
  fs.writeFileSync(verifyAdminPath, adminTxt.trim() + "\n", "utf-8");
  console.log("写入", verifyIssuedPath);
  console.log("写入", verifyAdminPath);
  console.log("\n下一步: BaseScan 验证两个模块；重启 API Cluster/Master（无合约常量变更时仅部署记录即可）。");
}

main().catch((e: unknown) => {
  console.error(e);
  process.exit(1);
});
