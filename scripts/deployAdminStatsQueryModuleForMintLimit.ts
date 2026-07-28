/**
 * 部署新的 AdminStatsQueryModule 并更新 Factory。
 * 解决 BM_CallFailed：链上旧 AdminStatsQueryModule 的 selectorModuleKind 不识别新加入的 selector，
 * 例如：
 * - createRedeemAdmin(bytes32,string,uint64,uint64,uint256)
 * - getGlobalAdminToAdminHourlyData(uint256)
 * - getGlobalAdminToAdminCounters()
 * 导致 BeamioUserCard fallback 返回 ROUTE_INVALID 并 revert BM_CallFailed。
 *
 * 运行：
 *   FACTORY=0x52cc9E977Ca3EA33c69383a41F87f32a71140A52 \
 *   npx hardhat run scripts/deployAdminStatsQueryModuleForMintLimit.ts --network base
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

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
  const factoryAddress = process.env.FACTORY || "0x52cc9E977Ca3EA33c69383a41F87f32a71140A52";

  const master = loadMasterSetup();
  const deployerPk = master.settle_contractAdmin[0];
  if (!deployerPk) throw new Error("settle_contractAdmin[0] 为空");

  const { ethers: hhEthers } = await networkModule.connect();
  const signer = new hhEthers.NonceManager(new hhEthers.Wallet(deployerPk, hhEthers.provider));

  console.log("=".repeat(60));
  console.log("部署 AdminStatsQueryModule（含 admin-to-admin stats 路由校验）");
  console.log("=".repeat(60));
  console.log("Factory:", factoryAddress);

  const AdminStatsQueryFactory = await hhEthers.getContractFactory("BeamioUserCardAdminStatsQueryModuleV1");
  const adminStatsQuery = await AdminStatsQueryFactory.connect(signer).deploy();
  await adminStatsQuery.waitForDeployment();
  const newModuleAddress = await adminStatsQuery.getAddress();
  console.log("\n新 AdminStatsQueryModule 已部署:", newModuleAddress);

  const routeAbi = ["function selectorModuleKind(bytes4) view returns (uint8)"];
  const routeReader = new hhEthers.Contract(newModuleAddress, routeAbi, hhEthers.provider);
  const ROUTE_REDEEM = 0;
  const ROUTE_STATS_QUERY = 254;
  const routeChecks: Array<{ label: string; signature: string; expected: number }> = [
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
  ];
  for (const check of routeChecks) {
    const selector = hhEthers.id(check.signature).slice(0, 10) as `0x${string}`;
    const route = Number(await routeReader.selectorModuleKind(selector));
    console.log(`selectorModuleKind ${check.label}:`, route);
    if (route !== check.expected) {
      throw new Error(
        `新模块 selector 路由校验失败: ${check.signature} => ${route}, expected=${check.expected}`
      );
    }
  }
  console.log("新模块 selector 路由校验通过");

  const factoryAbi = [
    "function setAdminStatsQueryModule(address m) external",
    "function defaultAdminStatsQueryModule() view returns (address)",
  ];
  const factory = new hhEthers.Contract(factoryAddress, factoryAbi, signer);

  const oldModule = (await factory.defaultAdminStatsQueryModule()) as string;
  console.log("旧 AdminStatsQueryModule:", oldModule);

  await (await factory.setAdminStatsQueryModule(newModuleAddress)).wait();
  console.log("Factory.setAdminStatsQueryModule 已更新");

  const bound = (await factory.defaultAdminStatsQueryModule()) as string;
  if (bound.toLowerCase() !== newModuleAddress.toLowerCase()) throw new Error("setAdminStatsQueryModule 未生效");
  console.log("验证通过: defaultAdminStatsQueryModule =", bound);

  // 更新 deployments
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const factoryPath = path.join(deploymentsDir, "base-UserCardFactory.json");
  const modulesPath = path.join(deploymentsDir, "base-UserCardModules.json");
  if (fs.existsSync(factoryPath)) {
    const data = JSON.parse(fs.readFileSync(factoryPath, "utf-8"));
    if (data.contracts?.beamioUserCardFactoryPaymaster) {
      data.contracts.beamioUserCardFactoryPaymaster.adminStatsQueryModule = newModuleAddress;
      fs.writeFileSync(factoryPath, JSON.stringify(data, null, 2));
      console.log("\n已更新 deployments/base-UserCardFactory.json");
    }
  }
  if (fs.existsSync(modulesPath)) {
    const data = JSON.parse(fs.readFileSync(modulesPath, "utf-8"));
    data.adminStatsQueryModule = newModuleAddress;
    fs.writeFileSync(modulesPath, JSON.stringify(data, null, 2));
    console.log("已更新 deployments/base-UserCardModules.json");
  }

  console.log("\n完成。Registration Merchant（带 Top-up Limit）现在应可正常工作。");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
