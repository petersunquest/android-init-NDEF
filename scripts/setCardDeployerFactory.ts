/**
 * 为 BeamioUserCardDeployerV07 设置 factory 地址（Card Factory）。
 * 使用 Factory.deployer() 作为要设置的 Deployer（与 createCard 实际调用的合约一致）。
 * Card Factory 地址来源与 checkCreateCardDeployerConfig 一致（勿用 historical FullAccount snapshot）。
 *
 * Signer（须为 Deployer.owner，通常即部署工厂的 admin / settle_contractAdmin[0]）：
 * - Hardhat `PRIVATE_KEY`（.env）；或
 * - `~/.master.json` → `settle_contractAdmin[0]`
 *
 * 用法：npm run set:card-deployer-factory:base
 * 或：npx hardhat run scripts/setCardDeployerFactory.ts --network base
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";
import type { Signer } from "ethers";
import { resolveBaseCardFactoryAddress } from "./readCanonicalBaseCardFactory.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function getMasterJsonPath(): string {
  const candidates = [
    path.join(homedir(), ".master.json"),
    process.env.HOME ? path.join(process.env.HOME, ".master.json") : "",
    process.env.USERPROFILE ? path.join(process.env.USERPROFILE, ".master.json") : "",
  ].filter(Boolean) as string[];
  return candidates.find((p) => fs.existsSync(p)) ?? candidates[0] ?? path.join(homedir(), ".master.json");
}

function loadAdminPkFromMaster(): string | null {
  const f = getMasterJsonPath();
  if (!fs.existsSync(f)) return null;
  try {
    const data = JSON.parse(fs.readFileSync(f, "utf-8"));
    const pks = data?.settle_contractAdmin;
    if (!Array.isArray(pks) || pks.length === 0) return null;
    const pk = String(pks[0]).trim();
    const key = pk.startsWith("0x") ? pk : `0x${pk}`;
    if (key.length < 64) return null;
    return key;
  } catch {
    return null;
  }
}

async function main() {
  const { ethers } = await networkModule.connect();
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const cardFactoryAddress = resolveBaseCardFactoryAddress(deploymentsDir);

  const hardhatSigners = await ethers.getSigners();
  let signer: Signer;
  if (hardhatSigners.length > 0) {
    signer = hardhatSigners[0];
  } else {
    const pk = loadAdminPkFromMaster();
    if (!pk) {
      throw new Error("无 signer：请在 .env 设置 PRIVATE_KEY，或配置 ~/.master.json 的 settle_contractAdmin[0]（Deployer.owner）");
    }
    signer = new ethers.Wallet(pk, ethers.provider);
    console.log("使用 ~/.master.json settle_contractAdmin[0] 作为 signer:", await signer.getAddress());
  }

  const factoryAbi = ["function deployer() view returns (address)"];
  const factory = new ethers.Contract(cardFactoryAddress, factoryAbi, ethers.provider);
  const userCardDeployerAddress = await factory.deployer();
  if (!userCardDeployerAddress || userCardDeployerAddress === ethers.ZeroAddress) {
    console.error("Card Factory.deployer() 未设置");
    process.exit(1);
  }

  const deployer = await ethers.getContractAt("BeamioUserCardDeployerV07", userCardDeployerAddress, signer);
  const owner = await deployer.owner();
  const walletAddr = await signer.getAddress();
  if (owner.toLowerCase() !== walletAddr.toLowerCase()) {
    throw new Error(
      `当前 signer ${walletAddr} 不是 Deployer.owner（${owner}）。请换用部署工厂 / 持有 Deployer 的 admin 私钥。`,
    );
  }

  const current = await deployer.factory();
  console.log("UserCard Deployer (Factory.deployer()):", userCardDeployerAddress);
  console.log("当前 Deployer.factory:", current);
  console.log("目标 Card Factory:", cardFactoryAddress);

  if (current.toLowerCase() === cardFactoryAddress.toLowerCase()) {
    console.log("已指向当前 Card Factory，无需操作");
    return;
  }

  console.log("调用 setFactory(Card Factory)...");
  const tx = await deployer.setFactory(cardFactoryAddress);
  await tx.wait();
  console.log("✅ 已设置，tx:", tx.hash);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
