import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ENTRY_POINT_V07 = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";

/**
 * 校验 EOA 对应 BeamioAccount 是否已部署，以及 Factory 是否指向当前部署的 ContainerModule（新栈）。
 *
 * 用法:
 *   EOA_ADDRESS=0x... npm run verify:aa-stack:base
 */
async function main() {
  const eoa = process.env.EOA_ADDRESS || "";
  if (!eoa || !/^0x[a-fA-F0-9]{40}$/.test(eoa)) {
    console.error("用法: EOA_ADDRESS=0x... npm run verify:aa-stack:base");
    process.exit(1);
  }

  const { ethers } = await networkModule.connect();
  const net = await ethers.provider.getNetwork();
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const factoryFile = path.join(deploymentsDir, `${net.name}-FactoryAndModule.json`);
  if (!fs.existsSync(factoryFile)) {
    throw new Error(`缺少部署记录: ${factoryFile}`);
  }
  const j = JSON.parse(fs.readFileSync(factoryFile, "utf-8"));
  const factoryAddr = j.contracts?.beamioFactoryPaymaster?.address as string;
  const expectedModule = j.contracts?.beamioContainerModule?.address as string;
  if (!factoryAddr || !expectedModule) {
    throw new Error("FactoryAndModule.json 中缺少 beamioFactoryPaymaster / beamioContainerModule");
  }

  const factory = await ethers.getContractAt("BeamioFactoryPaymasterV07", factoryAddr);
  const onChainModule = await factory.containerModule();
  const moduleMatch = onChainModule.toLowerCase() === expectedModule.toLowerCase();

  console.log("网络:", net.name, "chainId", net.chainId.toString());
  console.log("EOA:", ethers.getAddress(eoa));
  console.log("Factory:", factoryAddr);
  console.log("部署记录 containerModule:", expectedModule);
  console.log("链上 factory.containerModule():", onChainModule);
  console.log("ContainerModule 与部署记录一致:", moduleMatch ? "是" : "否");

  const primary = await factory.beamioAccountOf(eoa);
  // 避免与 ethers Contract 内置 getAddress() 冲突，必须用 interface 编码
  const iface = factory.interface;
  const getAddrData = iface.encodeFunctionData("getAddress", [eoa, 0n]);
  const getAddrRaw = await ethers.provider.call({ to: factoryAddr, data: getAddrData });
  const [idx0] = iface.decodeFunctionResult("getAddress", getAddrRaw) as [string];

  const codePrimary = primary !== ethers.ZeroAddress ? await ethers.provider.getCode(primary) : "0x";
  const codeIdx0 = await ethers.provider.getCode(idx0);
  const deployedAt = codeIdx0 !== "0x" && codeIdx0.length > 2 ? idx0 : null;

  console.log("beamioAccountOf(EOA):", primary);
  console.log("getAddress(EOA,0):", idx0);
  console.log("index=0 地址已部署:", deployedAt ? "是" : "否");

  if (!deployedAt) {
    console.log("\n结论: 该 EOA 尚未创建 AA（预测地址无 bytecode）。");
    console.log("创建: 使用该 EOA 的私钥作为 PRIVATE_KEY，执行:");
    console.log(`  TARGET_EOA=${ethers.getAddress(eoa)} npm run create:account:base`);
    return;
  }

  const registered = await factory.isBeamioAccount(idx0);
  console.log("Factory.isBeamioAccount(预测地址):", registered);

  const acct = await ethers.getContractAt("BeamioAccount", idx0);
  const [owner, acctFactory, ep] = await Promise.all([
    acct.owner(),
    acct.factory(),
    acct.entryPoint(),
  ]);
  console.log("\nBeamioAccount @", idx0);
  console.log("  owner:", owner);
  console.log("  factory (绑定):", acctFactory);
  console.log("  entryPoint:", ep);

  const ownerOk = owner.toLowerCase() === ethers.getAddress(eoa).toLowerCase();
  const factoryOk = acctFactory.toLowerCase() === factoryAddr.toLowerCase();
  const epOk = ep.toLowerCase() === ENTRY_POINT_V07.toLowerCase();

  console.log("  owner == EOA:", ownerOk);
  console.log("  account.factory == 当前 Factory:", factoryOk);
  console.log("  entryPoint == v0.7 标准:", epOk);

  // 新栈：delegatecall 的 module 来自 Factory.containerModule；与部署 JSON 一致即使用新库链接的模块
  const stackOk = moduleMatch && factoryOk && epOk && registered;
  console.log("\n新 Container 栈（模块地址与仓库部署记录一致 + 账户绑定当前 Factory）:", stackOk ? "通过" : "未通过");
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
