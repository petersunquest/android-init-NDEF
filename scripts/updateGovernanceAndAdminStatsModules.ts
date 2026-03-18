/**
 * 部署新的 GovernanceModule 和 AdminStatsQueryModule（含 transferAmountFromClear 等更新），
 * 并更新 Factory 的 defaultGovernanceModule 和 defaultAdminStatsQueryModule。
 *
 * 运行：
 *   npx hardhat run scripts/updateGovernanceAndAdminStatsModules.ts --network base
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function loadSignerPk(): string {
  if (process.env.PRIVATE_KEY && process.env.PRIVATE_KEY.trim()) {
    return process.env.PRIVATE_KEY.startsWith("0x")
      ? process.env.PRIVATE_KEY
      : `0x${process.env.PRIVATE_KEY}`;
  }
  const setupPath = path.join(homedir(), ".master.json");
  if (!fs.existsSync(setupPath)) throw new Error("未找到 PRIVATE_KEY，且 ~/.master.json 不存在");
  const data = JSON.parse(fs.readFileSync(setupPath, "utf-8"));
  const pk = data?.settle_contractAdmin?.[0];
  if (!pk || typeof pk !== "string") throw new Error("未找到 settle_contractAdmin[0]");
  return pk.startsWith("0x") ? pk : `0x${pk}`;
}

async function main() {
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const factoryPath = path.join(deploymentsDir, "base-UserCardFactory.json");
  const modulesPath = path.join(deploymentsDir, "base-UserCardModules.json");

  if (!fs.existsSync(factoryPath)) throw new Error("缺少 deployments/base-UserCardFactory.json");
  const factoryData = JSON.parse(fs.readFileSync(factoryPath, "utf-8"));
  const factoryAddress = factoryData?.contracts?.beamioUserCardFactoryPaymaster?.address;
  if (!factoryAddress) throw new Error("base-UserCardFactory.json 中缺少 beamioUserCardFactoryPaymaster.address");

  const { ethers: hhEthers } = await networkModule.connect();
  const signer = new hhEthers.NonceManager(new hhEthers.Wallet(loadSignerPk(), hhEthers.provider));

  console.log("=".repeat(60));
  console.log("部署 GovernanceModule 和 AdminStatsQueryModule，更新 Factory");
  console.log("=".repeat(60));
  console.log("Factory:", factoryAddress);

  const GovernanceFactory = await hhEthers.getContractFactory("BeamioUserCardGovernanceModuleV1");
  const AdminStatsQueryFactory = await hhEthers.getContractFactory("BeamioUserCardAdminStatsQueryModuleV1");

  const governance = await GovernanceFactory.connect(signer).deploy();
  await governance.waitForDeployment();
  const newGovernanceAddr = await governance.getAddress();
  console.log("\n新 GovernanceModule:", newGovernanceAddr);

  const adminStatsQuery = await AdminStatsQueryFactory.connect(signer).deploy();
  await adminStatsQuery.waitForDeployment();
  const newAdminStatsAddr = await adminStatsQuery.getAddress();
  console.log("新 AdminStatsQueryModule:", newAdminStatsAddr);

  const factoryAbi = [
    "function setGovernanceModule(address m) external",
    "function setAdminStatsQueryModule(address m) external",
    "function defaultGovernanceModule() view returns (address)",
    "function defaultAdminStatsQueryModule() view returns (address)",
  ];
  const factory = new hhEthers.Contract(factoryAddress, factoryAbi, signer);

  const oldGov = (await factory.defaultGovernanceModule()) as string;
  const oldAdmin = (await factory.defaultAdminStatsQueryModule()) as string;
  console.log("\n旧 GovernanceModule:", oldGov);
  console.log("旧 AdminStatsQueryModule:", oldAdmin);

  await (await factory.setGovernanceModule(newGovernanceAddr)).wait();
  console.log("Factory.setGovernanceModule 已更新");
  await (await factory.setAdminStatsQueryModule(newAdminStatsAddr)).wait();
  console.log("Factory.setAdminStatsQueryModule 已更新");

  const boundGov = (await factory.defaultGovernanceModule()) as string;
  const boundAdmin = (await factory.defaultAdminStatsQueryModule()) as string;
  if (boundGov.toLowerCase() !== newGovernanceAddr.toLowerCase()) throw new Error("setGovernanceModule 未生效");
  if (boundAdmin.toLowerCase() !== newAdminStatsAddr.toLowerCase()) {
    console.warn("⚠️ setAdminStatsQueryModule 读回不一致，链上可能已更新，继续写入 deployments");
  } else {
    console.log("验证通过");
  }

  // 更新 deployments
  factoryData.contracts.beamioUserCardFactoryPaymaster.governanceModule = newGovernanceAddr;
  factoryData.contracts.beamioUserCardFactoryPaymaster.adminStatsQueryModule = newAdminStatsAddr;
  fs.writeFileSync(factoryPath, JSON.stringify(factoryData, null, 2));
  console.log("\n已更新 deployments/base-UserCardFactory.json");

  const modulesData: Record<string, unknown> = fs.existsSync(modulesPath)
    ? JSON.parse(fs.readFileSync(modulesPath, "utf-8"))
    : { network: "base", chainId: "8453" };
  modulesData.governanceModule = newGovernanceAddr;
  modulesData.adminStatsQueryModule = newAdminStatsAddr;
  if (modulesData.modules) {
    (modulesData.modules as Record<string, string>).governanceModule = newGovernanceAddr;
    (modulesData.modules as Record<string, string>).adminStatsQueryModule = newAdminStatsAddr;
  }
  fs.writeFileSync(modulesPath, JSON.stringify(modulesData, null, 2));
  console.log("已更新 deployments/base-UserCardModules.json");

  console.log("\n完成。请执行: node scripts/syncBeamioUserCardToX402sdk.mjs");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
