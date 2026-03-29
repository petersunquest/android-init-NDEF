import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

type ModuleAddresses = {
  redeemModule: string;
  issuedNftModule: string;
  faucetModule: string;
  governanceModule: string;
  membershipStatsModule: string;
  adminStatsQueryModule: string;
};

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

function ensureCode(code: string, name: string, address: string) {
  if (code === "0x" || code === "0x0") {
    throw new Error(`${name} 无合约代码: ${address}`);
  }
}

async function resolveModuleAddress(
  provider: { getCode(address: string): Promise<string> },
  providedAddress: string | undefined,
  name: string
): Promise<string | undefined> {
  const address = providedAddress?.trim();
  if (!address) return undefined;
  const code = await provider.getCode(address);
  ensureCode(code, name, address);
  return address;
}

function selector(signature: string): string {
  return ethers.id(signature).slice(2, 10).toLowerCase();
}

function assertSelectorPresent(code: string, signature: string) {
  const sel = selector(signature);
  if (!code.toLowerCase().includes(sel)) {
    throw new Error(`Factory bytecode 缺少函数选择器: ${signature} (${sel})`);
  }
}

async function main() {
  // 未设置 *_MODULE_ADDRESS 时会重新部署缺失模块；仅升级某一模块时，请对其余模块传入链上已有地址，避免误替换工厂绑定。
  const { ethers: hhEthers } = await networkModule.connect();
  const provider = hhEthers.provider;
  const network = await provider.getNetwork();
  const pk = loadSignerPk();
  const signer = new ethers.NonceManager(new hhEthers.Wallet(pk, provider));
  const signerAddress = await signer.getAddress();
  const feeData = await provider.getFeeData();
  const txOverrides: { maxFeePerGas?: bigint; maxPriorityFeePerGas?: bigint } = {};
  if (feeData.maxFeePerGas) txOverrides.maxFeePerGas = feeData.maxFeePerGas * 2n;
  if (feeData.maxPriorityFeePerGas) txOverrides.maxPriorityFeePerGas = feeData.maxPriorityFeePerGas * 2n;

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const factoryFile = path.join(deploymentsDir, "base-UserCardFactory.json");
  const modulesFile = path.join(deploymentsDir, "base-UserCardModules.json");

  if (!fs.existsSync(factoryFile)) {
    throw new Error("缺少 deployments/base-UserCardFactory.json，请先完成 Factory 部署");
  }

  const factoryData = JSON.parse(fs.readFileSync(factoryFile, "utf-8"));
  const factoryAddress = factoryData?.contracts?.beamioUserCardFactoryPaymaster?.address;
  if (!factoryAddress) {
    throw new Error("base-UserCardFactory.json 中缺少 beamioUserCardFactoryPaymaster.address");
  }

  const factoryCode = await provider.getCode(factoryAddress);
  ensureCode(factoryCode, "Factory", factoryAddress);

  console.log("=".repeat(60));
  console.log("部署并绑定 UserCard 模块");
  console.log("=".repeat(60));
  console.log("网络:", network.name, "chainId:", Number(network.chainId));
  console.log("签名账户:", signerAddress);
  console.log("Factory:", factoryAddress);

  try {
    const ownerAbi = ["function owner() view returns (address)"];
    const ownerReader = new hhEthers.Contract(factoryAddress, ownerAbi, provider);
    const owner = (await ownerReader.owner()) as string;
    console.log("Factory owner:", owner);
    if (owner.toLowerCase() !== signerAddress.toLowerCase()) {
      throw new Error(`当前 signer 非 factory owner。owner=${owner}, signer=${signerAddress}`);
    }
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    console.log("⚠️  跳过 owner() 预检查，继续尝试链上绑定:", msg);
  }

  const RedeemFactory = await hhEthers.getContractFactory("BeamioUserCardRedeemModuleVNext");
  const IssuedFactory = await hhEthers.getContractFactory("BeamioUserCardIssuedNftModuleV1");
  const FaucetFactory = await hhEthers.getContractFactory("BeamioUserCardFaucetModuleV1");
  const GovernanceFactory = await hhEthers.getContractFactory("BeamioUserCardGovernanceModuleV1");
  const MembershipStatsFactory = await hhEthers.getContractFactory("BeamioUserCardMembershipStatsModuleV1");
  const AdminStatsQueryFactory = await hhEthers.getContractFactory("BeamioUserCardAdminStatsQueryModuleV1");
  const existingRedeem = await resolveModuleAddress(provider, process.env.REDEEM_MODULE_ADDRESS, "RedeemModule");
  const existingIssued = await resolveModuleAddress(provider, process.env.ISSUED_NFT_MODULE_ADDRESS, "IssuedNftModule");
  const existingFaucet = await resolveModuleAddress(provider, process.env.FAUCET_MODULE_ADDRESS, "FaucetModule");
  const existingGovernance = await resolveModuleAddress(provider, process.env.GOVERNANCE_MODULE_ADDRESS, "GovernanceModule");
  const existingMembershipStats = await resolveModuleAddress(provider, process.env.MEMBERSHIP_STATS_MODULE_ADDRESS, "MembershipStatsModule");
  const existingAdminStatsQuery =
    await resolveModuleAddress(provider, process.env.ADMIN_STATS_QUERY_MODULE_ADDRESS, "AdminStatsQueryModule");

  const redeem = existingRedeem ? undefined : await RedeemFactory.connect(signer).deploy(txOverrides);
  if (redeem) await redeem.waitForDeployment();
  const issued = existingIssued ? undefined : await IssuedFactory.connect(signer).deploy(txOverrides);
  if (issued) await issued.waitForDeployment();
  const faucet = existingFaucet ? undefined : await FaucetFactory.connect(signer).deploy(txOverrides);
  if (faucet) await faucet.waitForDeployment();
  const governance = existingGovernance ? undefined : await GovernanceFactory.connect(signer).deploy(txOverrides);
  if (governance) await governance.waitForDeployment();
  const membershipStats =
    existingMembershipStats ? undefined : await MembershipStatsFactory.connect(signer).deploy(txOverrides);
  if (membershipStats) await membershipStats.waitForDeployment();
  const adminStatsQuery =
    existingAdminStatsQuery ? undefined : await AdminStatsQueryFactory.connect(signer).deploy(txOverrides);
  if (adminStatsQuery) await adminStatsQuery.waitForDeployment();

  const modules: ModuleAddresses = {
    redeemModule: existingRedeem ?? await redeem!.getAddress(),
    issuedNftModule: existingIssued ?? await issued!.getAddress(),
    faucetModule: existingFaucet ?? await faucet!.getAddress(),
    governanceModule: existingGovernance ?? await governance!.getAddress(),
    membershipStatsModule: existingMembershipStats ?? await membershipStats!.getAddress(),
    adminStatsQueryModule: existingAdminStatsQuery ?? await adminStatsQuery!.getAddress(),
  };

  console.log("RedeemModule:", modules.redeemModule);
  console.log("IssuedNftModule:", modules.issuedNftModule);
  console.log("FaucetModule:", modules.faucetModule);
  console.log("GovernanceModule:", modules.governanceModule);
  console.log("MembershipStatsModule:", modules.membershipStatsModule);
  console.log("AdminStatsQueryModule:", modules.adminStatsQueryModule);

  const factoryAbi = [
    "function setRedeemModule(address m) external",
    "function setIssuedNftModule(address m) external",
    "function setFaucetModule(address m) external",
    "function setGovernanceModule(address m) external",
    "function setMembershipStatsModule(address m) external",
    "function setAdminStatsQueryModule(address m) external",
    "function defaultRedeemModule() view returns (address)",
    "function defaultIssuedNftModule() view returns (address)",
    "function defaultFaucetModule() view returns (address)",
    "function defaultGovernanceModule() view returns (address)",
    "function defaultMembershipStatsModule() view returns (address)",
    "function defaultAdminStatsQueryModule() view returns (address)",
  ];
  const factory = new hhEthers.Contract(factoryAddress, factoryAbi, signer);

  await (await factory.setRedeemModule(modules.redeemModule, txOverrides)).wait();
  await (await factory.setIssuedNftModule(modules.issuedNftModule, txOverrides)).wait();
  await (await factory.setFaucetModule(modules.faucetModule, txOverrides)).wait();
  await (await factory.setGovernanceModule(modules.governanceModule, txOverrides)).wait();
  await (await factory.setMembershipStatsModule(modules.membershipStatsModule, txOverrides)).wait();
  await (await factory.setAdminStatsQueryModule(modules.adminStatsQueryModule, txOverrides)).wait();

  const bound = {
    redeem: (await factory.defaultRedeemModule()) as string,
    issued: (await factory.defaultIssuedNftModule()) as string,
    faucet: (await factory.defaultFaucetModule()) as string,
    governance: (await factory.defaultGovernanceModule()) as string,
    membershipStats: (await factory.defaultMembershipStatsModule()) as string,
    adminStatsQuery: (await factory.defaultAdminStatsQueryModule()) as string,
  };

  if (bound.redeem.toLowerCase() !== modules.redeemModule.toLowerCase()) throw new Error("setRedeemModule 未生效");
  if (bound.issued.toLowerCase() !== modules.issuedNftModule.toLowerCase()) throw new Error("setIssuedNftModule 未生效");
  if (bound.faucet.toLowerCase() !== modules.faucetModule.toLowerCase()) throw new Error("setFaucetModule 未生效");
  if (bound.governance.toLowerCase() !== modules.governanceModule.toLowerCase()) throw new Error("setGovernanceModule 未生效");
  if (bound.membershipStats.toLowerCase() !== modules.membershipStatsModule.toLowerCase()) throw new Error("setMembershipStatsModule 未生效");
  if (bound.adminStatsQuery.toLowerCase() !== modules.adminStatsQueryModule.toLowerCase()) throw new Error("setAdminStatsQueryModule 未生效");

  const deployedFactoryCode = await provider.getCode(factoryAddress);
  assertSelectorPresent(
    deployedFactoryCode,
    "appendTierForCardWithOwnerSignature(address,uint256,uint256,uint256,uint256,bytes32,bytes)"
  );
  assertSelectorPresent(
    deployedFactoryCode,
    "createCardCollectionWithInitCodeAndTiers(address,uint8,uint256,bytes,(uint256,uint256,uint256)[])"
  );

  const moduleDeployment = {
    network: network.name,
    chainId: network.chainId.toString(),
    timestamp: new Date().toISOString(),
    signer: signerAddress,
    factory: factoryAddress,
    modules,
    checks: {
      appendTierForCardWithOwnerSignature: true,
      createCardCollectionWithInitCodeAndTiers: true,
    },
  };
  fs.writeFileSync(modulesFile, JSON.stringify(moduleDeployment, null, 2));

  factoryData.contracts.beamioUserCardFactoryPaymaster.redeemModule = modules.redeemModule;
  factoryData.contracts.beamioUserCardFactoryPaymaster.issuedNftModule = modules.issuedNftModule;
  factoryData.contracts.beamioUserCardFactoryPaymaster.faucetModule = modules.faucetModule;
  factoryData.contracts.beamioUserCardFactoryPaymaster.governanceModule = modules.governanceModule;
  factoryData.contracts.beamioUserCardFactoryPaymaster.membershipStatsModule = modules.membershipStatsModule;
  factoryData.contracts.beamioUserCardFactoryPaymaster.adminStatsQueryModule = modules.adminStatsQueryModule;
  fs.writeFileSync(factoryFile, JSON.stringify(factoryData, null, 2));

  console.log("绑定完成并写入:");
  console.log(" -", modulesFile);
  console.log(" -", factoryFile);
  console.log("功能检查通过: appendTierForCardWithOwnerSignature / createCardCollectionWithInitCodeAndTiers");
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
