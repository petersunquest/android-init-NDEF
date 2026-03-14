/**
 * 检查 ConetTreasury 使用的 BUnitAirdrop 是否为 BeamioIndexerDiamond admin
 *
 * 运行: npx hardhat run scripts/checkConetTreasuryBUnitAirdropAdmin.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");

async function main() {
  const addrs = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
  const diamondAddr = addrs.BeamioIndexerDiamond || "0x9d481CC9Da04456e98aE2FD6eB6F18e37bf72eb5";

  const { ethers } = await networkModule.connect();

  const treasury = await ethers.getContractAt("ConetTreasury", addrs.ConetTreasury);
  const bunitAirdropUsed = await treasury.bunitAirdrop();

  const adminAbi = ["function isAdmin(address) view returns (bool)", "function owner() view returns (address)"];
  const diamond = new ethers.Contract(diamondAddr, adminAbi, ethers.provider);
  const isAdmin = await diamond.isAdmin(bunitAirdropUsed);
  const owner = await diamond.owner();

  console.log("=".repeat(60));
  console.log("ConetTreasury -> BUnitAirdrop -> Indexer Admin 检查");
  console.log("=".repeat(60));
  console.log("ConetTreasury.bunitAirdrop():", bunitAirdropUsed);
  console.log("conet-addresses.json BUnitAirdrop:", addrs.BUnitAirdrop);
  console.log("BeamioIndexerDiamond.isAdmin(BUnitAirdrop):", isAdmin);
  console.log("Indexer owner:", owner);

  if (!isAdmin) {
    console.log("\n❌ BUnitAirdrop 不是 Indexer admin！mintForUsdcPurchase 时 syncTokenAction 会 revert。");
    console.log("   请运行: npx hardhat run scripts/registerBUnitAirdropToConet.ts --network conet");
  } else {
    console.log("\n✅ BUnitAirdrop 已是 admin，syncTokenAction 应能成功。");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
