/**
 * Redeploy ConetTreasury (with mintForAdmin), create USDC via factory, update all references.
 *
 * 1. Deploy ConetTreasury (deployer = first miner)
 * 2. Create USDC via treasury.createERC20("USD Coin", "USDC", 6, BASE_USDC)
 * 3. BUnitAirdrop.addAdmin(ConetTreasury)
 * 4. BUnitAirdrop.setConetTreasuryAndUsdc(ConetTreasury, newUsdc) - owner only
 * 5. ConetTreasury.setBUnitAirdrop(BUnitAirdrop)
 * 6. Add miners (0x6bF3..., 0xcbBB...)
 * 7. Update conet-addresses.json, conet-ConetTreasury.json
 *
 * Run: npx hardhat run scripts/redeployConetTreasuryAndUsdc.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const MINERS_TO_ADD = [
  "0x6bF3Aa7261e21Be5Fc781Ac09F9475c8A34AfEea",
  "0xcbBB1371973D57e6bD45aC0dfeFD493b59F9D76B",
] as const;

function getPrivateKey(): string {
  if (process.env.PRIVATE_KEY) return process.env.PRIVATE_KEY;
  const setupPath = path.join(homedir(), ".master.json");
  if (fs.existsSync(setupPath)) {
    try {
      const master = JSON.parse(fs.readFileSync(setupPath, "utf-8"));
      const key = master?.settle_contractAdmin?.[0];
      if (key) return key.startsWith("0x") ? key : "0x" + key;
    } catch {}
  }
  throw new Error("Need PRIVATE_KEY or ~/.master.json settle_contractAdmin");
}

async function main() {
  const { ethers } = await networkModule.connect();
  let signer = (await ethers.getSigners())[0];
  if (!signer) {
    signer = new ethers.Wallet(getPrivateKey(), ethers.provider);
  }

  const addrPath = path.join(__dirname, "..", "deployments", "conet-addresses.json");
  const addrs = JSON.parse(fs.readFileSync(addrPath, "utf-8"));
  const bunitAirdropAddr = addrs.BUnitAirdrop;
  if (!bunitAirdropAddr) throw new Error("conet-addresses.json missing BUnitAirdrop");

  console.log("=".repeat(60));
  console.log("Redeploy ConetTreasury + Create USDC");
  console.log("=".repeat(60));
  console.log("Signer:", signer.address);
  console.log("BUnitAirdrop:", bunitAirdropAddr);

  // 1. Deploy ConetTreasury
  const ConetTreasuryFactory = await ethers.getContractFactory("ConetTreasury");
  const treasury = await ConetTreasuryFactory.deploy();
  await treasury.waitForDeployment();
  const treasuryAddress = await treasury.getAddress();
  console.log("\n[1] ConetTreasury deployed:", treasuryAddress);

  // 2. Create USDC
  const txCreate = await treasury.createERC20("USD Coin", "USDC", 6, BASE_USDC);
  await txCreate.wait();
  const tokens = await treasury.getCreatedTokens();
  const newUsdcAddr = tokens[tokens.length - 1];
  console.log("[2] USDC created:", newUsdcAddr);

  // 3. BUnitAirdrop.addAdmin(ConetTreasury)
  const airdrop = await ethers.getContractAt("BUnitAirdrop", bunitAirdropAddr, signer);
  const txAddAdmin = await airdrop.addAdmin(treasuryAddress);
  await txAddAdmin.wait();
  console.log("[3] BUnitAirdrop.addAdmin(ConetTreasury) ok");

  // 4. BUnitAirdrop.setConetTreasuryAndUsdc - owner only
  const txSetUsdc = await airdrop.setConetTreasuryAndUsdc(treasuryAddress, newUsdcAddr);
  await txSetUsdc.wait();
  console.log("[4] BUnitAirdrop.setConetTreasuryAndUsdc ok");

  // 5. ConetTreasury.setBUnitAirdrop
  const txSetAirdrop = await treasury.setBUnitAirdrop(bunitAirdropAddr);
  await txSetAirdrop.wait();
  console.log("[5] ConetTreasury.setBUnitAirdrop ok");

  // 6. Add miners
  for (const addr of MINERS_TO_ADD) {
    const tx = await treasury.addMiner(addr);
    await tx.wait();
    console.log("[6] addMiner(", addr, ") tx:", tx.hash);
  }

  // 7. Update deployment files
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const outPath = path.join(deploymentsDir, "conet-ConetTreasury.json");
  const out = {
    network: "conet",
    chainId: "224422",
    deployer: signer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      ConetTreasury: {
        address: treasuryAddress,
        minerCount: (await treasury.minerCount()).toString(),
        conetUsdc: newUsdcAddr,
        bUnitAirdrop: bunitAirdropAddr,
      },
    },
  };
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("\nsaved:", outPath);

  addrs.ConetTreasury = treasuryAddress;
  addrs.conetUsdc = newUsdcAddr;
  if (Array.isArray(addrs.DEPRECATED_BUINT) && addrs.DEPRECATED_BUINT.includes("0x2B7d42E560fC324f34ec57ce2FB8968F517EC7f9")) {
    // Keep old conetUsdc in DEPRECATED if needed
  }
  fs.writeFileSync(addrPath, JSON.stringify(addrs, null, 2) + "\n", "utf-8");
  console.log("updated conet-addresses.json");

  console.log("\nNew ConetTreasury:", treasuryAddress);
  console.log("New conetUsdc:", newUsdcAddr);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
