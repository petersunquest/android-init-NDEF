/**
 * 将 BUnitAirdrop 指向新的 BeamioIndexerDiamond，并将 BUnitAirdrop 设为新 Indexer 的 admin
 *
 * 1. BeamioIndexerDiamond.setAdmin(BUnitAirdrop, true) - Indexer owner
 * 2. BUnitAirdrop.setBeamioIndexerDiamond(newIndexer) - BUnitAirdrop admin
 *
 * 运行: npx hardhat run scripts/updateIndexerDiamondInBUnitAirdrop.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const INDEXER_PATH = path.join(__dirname, "..", "deployments", "conet-IndexerDiamond.json");
const MASTER_PATH = path.join(homedir(), ".master.json");

async function main() {
  if (!fs.existsSync(ADDRESSES_PATH)) throw new Error("未找到 conet-addresses.json");
  const addrs = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
  const airdropAddr = addrs.BUnitAirdrop;
  const newIndexerAddr = addrs.BeamioIndexerDiamond;

  if (!airdropAddr) throw new Error("conet-addresses.json 缺少 BUnitAirdrop");
  if (!newIndexerAddr) throw new Error("conet-addresses.json 缺少 BeamioIndexerDiamond");

  const deploy = JSON.parse(fs.readFileSync(INDEXER_PATH, "utf-8"));
  const diamondAddr = deploy.diamond;
  if (diamondAddr !== newIndexerAddr) {
    throw new Error(`conet-IndexerDiamond.json diamond (${diamondAddr}) 与 conet-addresses.json BeamioIndexerDiamond (${newIndexerAddr}) 不一致`);
  }

  const master = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  const pk = master?.settle_contractAdmin?.[0];
  if (!pk) throw new Error("~/.master.json settle_contractAdmin[0] 为空");

  const { ethers } = await networkModule.connect();
  const signer = new ethers.Wallet(pk.startsWith("0x") ? pk : `0x${pk}`, ethers.provider);

  console.log("=".repeat(60));
  console.log("更新 BUnitAirdrop 指向新 BeamioIndexerDiamond");
  console.log("=".repeat(60));
  console.log("BUnitAirdrop:", airdropAddr);
  console.log("新 Indexer:", newIndexerAddr);

  // 1. BeamioIndexerDiamond.setAdmin(BUnitAirdrop, true)
  const diamond = await ethers.getContractAt(
    ["function setAdmin(address admin, bool enabled) external", "function isAdmin(address) view returns (bool)"],
    diamondAddr,
    signer
  );
  const alreadyAdmin = await diamond.isAdmin(airdropAddr);
  if (!alreadyAdmin) {
    const tx1 = await diamond.setAdmin(airdropAddr, true);
    await tx1.wait();
    console.log("[1] BeamioIndexerDiamond.setAdmin(BUnitAirdrop, true) ok");
  } else {
    console.log("[1] BUnitAirdrop 已是 Indexer admin，跳过");
  }

  // 2. BUnitAirdrop.setBeamioIndexerDiamond(newIndexer)
  const airdrop = await ethers.getContractAt("BUnitAirdrop", airdropAddr);
  const tx2 = await airdrop.setBeamioIndexerDiamond(newIndexerAddr);
  await tx2.wait();
  console.log("[2] BUnitAirdrop.setBeamioIndexerDiamond(newIndexer) ok");

  console.log("\n✅ 更新完成");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
