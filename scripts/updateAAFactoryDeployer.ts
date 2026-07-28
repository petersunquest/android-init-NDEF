/**
 * 当 AA Factory 构造时传入的 BeamioAccountDeployer 已绑定旧 Factory（deployer.factory != 0），
 * constructor 里 try deployer.setFactory(address(this)) 会失败。无法对旧 Deployer 再次 setFactory。
 *
 * 本脚本：部署新的 BeamioAccountDeployer，并由目标 Factory 的 admin 调用 updateDeployer(newDeployer)，
 * 使新 Factory 与仅服务于它的 Deployer 正确绑定。
 *
 * 用法（Base）：
 *   npx hardhat run scripts/updateAAFactoryDeployer.ts --network base
 *
 * 环境变量（可选）：
 *   AA_FACTORY_ADDRESS — 默认从 deployments/{network}-FactoryAndModule.json 读取 beamioFactoryPaymaster.address
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";
import { ethers as ethersLib, type Signer } from "ethers";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function loadSignerPk(): string {
  if (process.env.PRIVATE_KEY?.trim()) {
    const pk = process.env.PRIVATE_KEY.trim();
    return pk.startsWith("0x") ? pk : `0x${pk}`;
  }
  const setupPath = path.join(homedir(), ".master.json");
  if (!fs.existsSync(setupPath)) throw new Error("需要 PRIVATE_KEY 或 ~/.master.json settle_contractAdmin[0]");
  const data = JSON.parse(fs.readFileSync(setupPath, "utf-8"));
  const pk = data?.settle_contractAdmin?.[0];
  if (!pk || typeof pk !== "string") throw new Error("~/.master.json 缺少 settle_contractAdmin[0]");
  return pk.startsWith("0x") ? pk : `0x${pk}`;
}

async function main() {
  const { ethers } = await networkModule.connect();
  let deployerSigner: Signer;
  const signers = await ethers.getSigners();
  if (signers.length > 0) deployerSigner = signers[0];
  else deployerSigner = new ethersLib.NonceManager(new ethersLib.Wallet(loadSignerPk(), ethers.provider));

  const from = await deployerSigner.getAddress();
  const networkInfo = await ethers.provider.getNetwork();
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const depFile = path.join(deploymentsDir, `${networkInfo.name}-FactoryAndModule.json`);

  let factoryAddr = process.env.AA_FACTORY_ADDRESS || "";
  if (!factoryAddr && fs.existsSync(depFile)) {
    const j = JSON.parse(fs.readFileSync(depFile, "utf-8"));
    factoryAddr = j.contracts?.beamioFactoryPaymaster?.address || "";
  }
  if (!factoryAddr) {
    console.error("缺少 AA_FACTORY_ADDRESS，且未找到", depFile);
    process.exit(1);
  }

  const acctDeployer = await ethers.getContractFactory("BeamioAccountDeployer");
  console.log("1. 部署新 BeamioAccountDeployer（由", from, "发送）...");
  const newDep = await acctDeployer.connect(deployerSigner).deploy();
  await newDep.waitForDeployment();
  const newDepAddr = await newDep.getAddress();
  console.log("   新 Deployer:", newDepAddr);

  const bound = await newDep.factory();
  if (bound !== ethers.ZeroAddress) {
    throw new Error("新 Deployer 异常：factory 非零");
  }

  const factory = await ethers.getContractAt("BeamioFactoryPaymasterV07", factoryAddr, deployerSigner);
  const admin = await factory.admin();
  if (admin.toLowerCase() !== from.toLowerCase()) {
    console.error("当前 signer 不是 Factory admin。admin=", admin, "signer=", from);
    console.error("请使用部署该 Factory 的账户运行本脚本，或先 transferAdmin。");
    process.exit(1);
  }

  const oldD = await factory.deployer();
  console.log("2. Factory 当前 deployer:", oldD);
  console.log("3. admin 调用 updateDeployer(", newDepAddr, ")...");
  const tx = await factory.updateDeployer(newDepAddr);
  await tx.wait();
  console.log("   tx:", tx.hash);

  const dAfter = await factory.deployer();
  const fOnNew = await ethers.getContractAt("BeamioAccountDeployer", newDepAddr);
  const factoryOnDep = await fOnNew.factory();
  console.log("4. 链上校验:");
  console.log("   factory.deployer() =", dAfter);
  console.log("   newDeployer.factory() =", factoryOnDep);
  if (factoryOnDep.toLowerCase() !== factoryAddr.toLowerCase()) {
    throw new Error("绑定失败：newDeployer.factory 不等于目标 Factory");
  }
  console.log("✅ 绑定成功。请更新 deployments JSON 中 beamioFactoryPaymaster.deployer 为", newDepAddr);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
