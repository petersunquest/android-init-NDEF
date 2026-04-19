/**
 * 将新部署的 BUnitAirdrop 与现有 ConetTreasury 关联
 *
 * ConetTreasury 作为 admin（非 owner）。部署者保持 owner。
 *
 * 1. BUnitAirdrop.addAdmin(ConetTreasury)
 * 2. BUnitAirdrop.setConetTreasuryAndUsdc(ConetTreasury, conet-USDC)
 * 3. ConetTreasury.setBUnitAirdrop(newAddress)
 * 4. BeamioIndexerDiamond.setAdmin(newAddress, true)
 *
 * 运行: npx hardhat run scripts/linkRedeployedBUnitAirdropToConet.ts --network conet
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
const CONET_USDC = fs.existsSync(ADDRESSES_PATH)
  ? JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8")).conetUsdc
  : "0x456Ecd35370bA9d4a9f615399a154548f07c2437";

async function main() {
  if (!fs.existsSync(ADDRESSES_PATH)) throw new Error("未找到 conet-addresses.json");
  const addrs = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
  const airdropAddr = addrs.BUnitAirdrop;
  const treasuryAddr = addrs.ConetTreasury;

  if (!airdropAddr) throw new Error("conet-addresses.json 缺少 BUnitAirdrop");
  if (!treasuryAddr) throw new Error("conet-addresses.json 缺少 ConetTreasury");

  const master = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  const pk = master?.settle_contractAdmin?.[0];
  if (!pk) throw new Error("~/.master.json settle_contractAdmin[0] 为空");

  const { ethers } = await networkModule.connect();
  const signer = new ethers.Wallet(pk.startsWith("0x") ? pk : `0x${pk}`, ethers.provider);

  const airdrop = await ethers.getContractAt("BUnitAirdrop", airdropAddr);
  const treasury = await ethers.getContractAt("ConetTreasury", treasuryAddr);

  console.log("=".repeat(60));
  console.log("关联新 BUnitAirdrop 与 ConetTreasury");
  console.log("=".repeat(60));
  console.log("BUnitAirdrop:", airdropAddr);
  console.log("ConetTreasury:", treasuryAddr);

  // 1. addAdmin(ConetTreasury)
  const tx1 = await airdrop.addAdmin(treasuryAddr);
  await tx1.wait();
  console.log("[1] BUnitAirdrop.addAdmin(ConetTreasury) ok");

  // 2. setConetTreasuryAndUsdc（需 owner 调用，部署者为 owner）
  const tx2 = await airdrop.setConetTreasuryAndUsdc(treasuryAddr, CONET_USDC);
  await tx2.wait();
  console.log("[2] BUnitAirdrop.setConetTreasuryAndUsdc ok");

  // 3. ConetTreasury.setBUnitAirdrop
  const tx3 = await treasury.setBUnitAirdrop(airdropAddr);
  await tx3.wait();
  console.log("[3] ConetTreasury.setBUnitAirdrop ok");

  // 4. BeamioIndexerDiamond.setAdmin
  const diamondAddr = fs.existsSync(INDEXER_PATH)
    ? JSON.parse(fs.readFileSync(INDEXER_PATH, "utf-8")).diamond
    : "0xd990719B2f05ccab4Acdd5D7A3f7aDfd2Fc584Fe";
  const diamond = await ethers.getContractAt(
    ["function setAdmin(address admin, bool enabled) external"],
    diamondAddr,
    signer
  );
  const tx4 = await diamond.setAdmin(airdropAddr, true);
  await tx4.wait();
  console.log("[4] BeamioIndexerDiamond.setAdmin(BUnitAirdrop, true) ok");

  console.log("\n✅ 关联完成");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
