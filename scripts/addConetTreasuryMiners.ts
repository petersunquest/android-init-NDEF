/**
 * Add DePIN node wallets as Treasury V3 miners on the same proxy address
 * (Base 8453 + CoNET 224422): 0xa208982212978550594A7FEEB70a61665d129003
 *
 * Default targets = GuardianNodesInfoV6 owners for SI Cluster #100–#102:
 *   #100 217.160.189.159 → 0xcbBB1371973D57e6bD45aC0dfeFD493b59F9D76B
 *   #101 93.93.112.187   → 0x6bF3Aa7261e21Be5Fc781Ac09F9475c8A34AfEea
 *   #102 82.165.208.58   → 0xe2E7A68E3D1e50F0Af15d713F90f4992CD19Dfc8
 *
 * Override: ADD_MINERS=0x1,0x2
 * Treasury: TREASURY_V3_ADDRESS / CONET_TREASURY / BASE_TREASURY
 *
 * Run (signer must already be miner, e.g. 0x87cA…):
 *   npx hardhat run scripts/addConetTreasuryMiners.ts --network conet
 *   PRIVATE_KEY=... npx hardhat run scripts/addConetTreasuryMiners.ts --network base
 */

import { network as networkModule } from "hardhat";
import { fileURLToPath } from "url";
import * as path from "path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/** CREATE2 same-address Treasury V3 proxy (Base + CoNET) */
const TREASURY_V3_PROXY = "0xa208982212978550594A7FEEB70a61665d129003";

/** SI Cluster NEW.sh #100–#102 → Guardian ipaddress2owner */
const DEFAULT_MINERS_TO_ADD = [
  "0xcbBB1371973D57e6bD45aC0dfeFD493b59F9D76B", // #100 217.160.189.159
  "0x6bF3Aa7261e21Be5Fc781Ac09F9475c8A34AfEea", // #101 93.93.112.187
  "0xe2E7A68E3D1e50F0Af15d713F90f4992CD19Dfc8", // #102 82.165.208.58
] as const;

const TREASURY_ABI = [
  "function addMiner(address miner) external",
  "function isMiner(address account) view returns (bool)",
  "function miners() view returns (address[])",
  "function minerCount() view returns (uint256)",
  "function requiredVotes() view returns (uint256)",
] as const;

function getTreasuryAddress(): string {
  return (
    process.env.CONET_TREASURY ||
    process.env.BASE_TREASURY ||
    TREASURY_V3_PROXY
  );
}

function minersToAdd(): string[] {
  const env = process.env.ADD_MINERS;
  if (env?.trim()) {
    return env.split(",").map((a) => a.trim()).filter(Boolean);
  }
  return [...DEFAULT_MINERS_TO_ADD];
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) {
    throw new Error("No signer. Set PRIVATE_KEY (base) or ~/.master.json settle_contractAdmin (conet).");
  }

  const treasuryAddress = getTreasuryAddress();
  const network = await ethers.provider.getNetwork();
  const treasury = new ethers.Contract(treasuryAddress, TREASURY_ABI, signer);

  const minerCount = await treasury.minerCount();
  const requiredVotes = await treasury.requiredVotes();
  const miners: string[] = await treasury.miners();
  const minersLower = new Set(miners.map((a) => a.toLowerCase()));

  console.log("=".repeat(60));
  console.log("addMiner → ConetTreasury CREATE2");
  console.log("=".repeat(60));
  console.log("network:", network.name, "chainId=", network.chainId.toString());
  console.log("treasury:", treasuryAddress);
  console.log("signer:", signer.address);
  console.log("minerCount:", minerCount.toString(), "requiredVotes:", requiredVotes.toString());
  console.log("current miners:", miners);

  const isMiner = await treasury.isMiner(signer.address);
  if (!isMiner) {
    throw new Error(`Signer ${signer.address} is not a miner. Cannot call addMiner.`);
  }

  const toAdd = minersToAdd().map((a) => ethers.getAddress(a));
  for (const addr of toAdd) {
    if (minersLower.has(addr.toLowerCase())) {
      console.log(`Skip ${addr} (already miner)`);
      continue;
    }
    const tx = await treasury.addMiner(addr);
    console.log(`addMiner(${addr}) tx: ${tx.hash}`);
    await tx.wait();
    console.log(`  confirmed`);
    minersLower.add(addr.toLowerCase());
  }

  const updatedMiners: string[] = await treasury.miners();
  const updatedCount = await treasury.minerCount();
  const updatedRequired = await treasury.requiredVotes();
  console.log("Updated minerCount:", updatedCount.toString(), "requiredVotes:", updatedRequired.toString());
  console.log("Updated miners:", updatedMiners);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
