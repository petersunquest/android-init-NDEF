/**
 * 使用新部署的 BUnitAirdrop 地址，对 ConetTreasury 和 BeamioIndexerDiamond 进行登记
 *
 * 1. ConetTreasury.setBUnitAirdrop(newBUnitAirdrop) — 需 ConetTreasury owner 执行
 * 2. BeamioIndexerDiamond AdminFacet.setAdmin(newBUnitAirdrop, true) — 需 Indexer owner 执行，用于 claim/焚烧/USDC 购买记账
 *
 * 用法:
 *   npx hardhat run scripts/registerBUnitAirdropToConet.ts --network conet
 *
 * 配置:
 *   - BUnitAirdrop 地址从 deployments/conet-addresses.json 读取
 *   - ConetTreasury 从 deployments/conet-ConetTreasury.json 读取
 *   - BeamioIndexerDiamond 从 deployments/conet-IndexerDiamond.json 读取
 *   - Signer 使用 ~/.master.json settle_contractAdmin[0]（与 hardhat conet 网络一致）
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const TREASURY_PATH = path.join(__dirname, "..", "deployments", "conet-ConetTreasury.json");
const INDEXER_PATH = path.join(__dirname, "..", "deployments", "conet-IndexerDiamond.json");
const MASTER_PATH = path.join(homedir(), ".master.json");

const ConetTreasuryABI = [
  "function setBUnitAirdrop(address _bunitAirdrop) external",
  "function bunitAirdrop() view returns (address)",
  "function owner() view returns (address)",
];

const AdminFacetABI = [
  "function setAdmin(address admin, bool enabled) external",
  "function isAdmin(address admin) view returns (bool)",
  "function owner() view returns (address)",
];

function loadBUnitAirdropAddress(): string {
  if (!fs.existsSync(ADDRESSES_PATH)) {
    throw new Error("未找到 deployments/conet-addresses.json");
  }
  const data = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
  const addr = data.BUnitAirdrop || data.contracts?.BUnitAirdrop?.address;
  if (!addr) throw new Error("conet-addresses.json 中缺少 BUnitAirdrop 地址");
  return addr;
}

function loadConetTreasuryAddress(): string {
  if (!fs.existsSync(TREASURY_PATH)) {
    throw new Error("未找到 deployments/conet-ConetTreasury.json");
  }
  const data = JSON.parse(fs.readFileSync(TREASURY_PATH, "utf-8"));
  const addr = data.contracts?.ConetTreasury?.address;
  if (!addr) throw new Error("conet-ConetTreasury.json 中缺少 ConetTreasury 地址");
  return addr;
}

function loadDiamondAddress(): string {
  if (!fs.existsSync(INDEXER_PATH)) {
    throw new Error("未找到 deployments/conet-IndexerDiamond.json");
  }
  const data = JSON.parse(fs.readFileSync(INDEXER_PATH, "utf-8"));
  if (!data.diamond) throw new Error("conet-IndexerDiamond.json 中缺少 diamond 字段");
  return data.diamond;
}

function loadSignerPrivateKey(): string {
  if (!fs.existsSync(MASTER_PATH)) {
    throw new Error("未找到 ~/.master.json，请配置 settle_contractAdmin");
  }
  const data = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  const pk = data?.settle_contractAdmin?.[0];
  if (!pk) throw new Error("~/.master.json 中 settle_contractAdmin[0] 为空");
  return pk.startsWith("0x") ? pk : `0x${pk}`;
}

async function main() {
  const bunitAirdropAddr = loadBUnitAirdropAddress();
  const treasuryAddr = loadConetTreasuryAddress();
  const diamondAddr = loadDiamondAddress();

  const { ethers } = await networkModule.connect();
  const pk = loadSignerPrivateKey();
  const signer = new ethers.Wallet(pk, ethers.provider);
  const net = await ethers.provider.getNetwork();

  console.log("=".repeat(60));
  console.log("登记新 BUnitAirdrop 到 ConetTreasury 与 BeamioIndexerDiamond");
  console.log("=".repeat(60));
  console.log("BUnitAirdrop:", bunitAirdropAddr);
  console.log("ConetTreasury:", treasuryAddr);
  console.log("BeamioIndexerDiamond:", diamondAddr);
  console.log("Signer:", signer.address);
  console.log("chainId:", net.chainId.toString());
  console.log();

  // 1. ConetTreasury.setBUnitAirdrop
  const treasury = new ethers.Contract(treasuryAddr, ConetTreasuryABI, signer);
  const treasuryOwner = await treasury.owner();
  const currentAirdrop = await treasury.bunitAirdrop();

  if (currentAirdrop.toLowerCase() === bunitAirdropAddr.toLowerCase()) {
    console.log("[1] ConetTreasury.bunitAirdrop 已是新地址，跳过 setBUnitAirdrop");
  } else {
    if (treasuryOwner.toLowerCase() !== signer.address.toLowerCase()) {
      throw new Error(
        `当前 signer (${signer.address}) 不是 ConetTreasury owner (${treasuryOwner})，无法执行 setBUnitAirdrop`
      );
    }
    const tx1 = await treasury.setBUnitAirdrop(bunitAirdropAddr);
    console.log("[1] ConetTreasury.setBUnitAirdrop tx:", tx1.hash);
    await tx1.wait();
    console.log("    ✅ 完成");
  }

  // 2. BeamioIndexerDiamond AdminFacet.setAdmin
  const diamond = new ethers.Contract(diamondAddr, AdminFacetABI, signer);
  const diamondOwner = await diamond.owner();
  const alreadyAdmin = await diamond.isAdmin(bunitAirdropAddr);

  if (alreadyAdmin) {
    console.log("[2] BUnitAirdrop 已是 BeamioIndexerDiamond admin，跳过 setAdmin");
  } else {
    if (diamondOwner.toLowerCase() !== signer.address.toLowerCase()) {
      throw new Error(
        `当前 signer (${signer.address}) 不是 BeamioIndexerDiamond owner (${diamondOwner})，无法执行 setAdmin`
      );
    }
    const tx2 = await diamond.setAdmin(bunitAirdropAddr, true);
    console.log("[2] BeamioIndexerDiamond.setAdmin(BUnitAirdrop, true) tx:", tx2.hash);
    await tx2.wait();
    console.log("    ✅ 完成");
  }

  console.log("\n✅ 登记完成");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
