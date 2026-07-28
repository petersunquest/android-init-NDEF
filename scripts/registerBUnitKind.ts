/**
 * Register BUnitAirdrop kind (e.g. kind=1 as "sendUSDC", kind=5 as "x402Send").
 *
 * Run: npx hardhat run scripts/registerBUnitKind.ts --network conet
 * Or: KIND_ID=1 KIND_NAME=sendUSDC npx hardhat run scripts/registerBUnitKind.ts --network conet
 * Or: KIND_ID=5 KIND_NAME=x402Send npx hardhat run scripts/registerBUnitKind.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ADDR_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");

function loadBUnitAirdrop(): string {
  if (fs.existsSync(ADDR_PATH)) {
    const d = JSON.parse(fs.readFileSync(ADDR_PATH, "utf-8"));
    return d.BUnitAirdrop || "0xbE1CF54f76BcAb40DC49cDcD7FBA525b9ABDa264";
  }
  return "0xbE1CF54f76BcAb40DC49cDcD7FBA525b9ABDa264";
}

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
  throw new Error("Need PRIVATE_KEY in .env or ~/.master.json settle_contractAdmin");
}

async function main() {
  const kindId = process.env.KIND_ID ? BigInt(process.env.KIND_ID) : 1n;
  const kindName = process.env.KIND_NAME || "sendUSDC";

  const { ethers } = await networkModule.connect();
  let signer = (await ethers.getSigners())[0];
  if (!signer) {
    signer = new ethers.Wallet(getPrivateKey(), ethers.provider);
  }

  const airdropAddr = loadBUnitAirdrop();
  const airdrop = await ethers.getContractAt("BUnitAirdrop", airdropAddr, signer);

  const existingName = await airdrop.getKindName(kindId);
  if (existingName === kindName) {
    console.log(`Kind ${kindId} already registered as "${kindName}". No action needed.`);
    return;
  }

  console.log(`Registering kind ${kindId} as "${kindName}"...`);
  const tx = await airdrop.registerKind(kindId, kindName);
  const receipt = await tx.wait();
  console.log("registerKind tx:", tx.hash);
  console.log("Block:", receipt?.blockNumber);
  console.log(`Done. kind=${kindId} -> txCategory=keccak256("${kindName}")`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
