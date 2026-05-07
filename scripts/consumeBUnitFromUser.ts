/**
 * Call BUnitAirdrop.consumeFromUser to burn user's B-Units.
 * Paid pool portion triggers USDC mint to BUnitAirdrop (1 B-Unit paid = 0.01 USDC).
 *
 * Run: npx hardhat run scripts/consumeBUnitFromUser.ts --network conet
 * Or: CONSUME_USER=0x... AMOUNT=21 npx hardhat run scripts/consumeBUnitFromUser.ts --network conet
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
    return d.BUnitAirdrop || "0xFd60936707cb4583c08D8AacBA19E4bfaEE446B8";
  }
  return "0xdD0163FE76FC8fbc4a05b21bCe7CE2642968E176";
}
const CONET_USDC = (() => {
  if (fs.existsSync(ADDR_PATH)) {
    const d = JSON.parse(fs.readFileSync(ADDR_PATH, "utf-8"));
    return d.conetUsdc || "0xdD0163FE76FC8fbc4a05b21bCe7CE2642968E176";
  }
  return "0x28fBBb6C5C06A4736B00A540b66378091c224456";
})();

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
  const user = process.env.CONSUME_USER || "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1";
  const amountHuman = process.env.AMOUNT ? parseFloat(process.env.AMOUNT) : 21;
  const amount = BigInt(Math.round(amountHuman * 1e6)); // 6 decimals
  const kindName = process.env.KIND || ""; // e.g. KIND=send
  const kind = process.env.KIND_ID ? BigInt(process.env.KIND_ID) : 0n;

  const { ethers } = await networkModule.connect();
  let signer = (await ethers.getSigners())[0];
  if (!signer) {
    signer = new ethers.Wallet(getPrivateKey(), ethers.provider);
  }

  const airdropAddr = loadBUnitAirdrop();
  const airdrop = await ethers.getContractAt("BUnitAirdrop", airdropAddr, signer);
  const usdc = new ethers.Contract(
    CONET_USDC,
    ["function balanceOf(address) view returns (uint256)"],
    ethers.provider
  );

  const balBefore = await usdc.balanceOf(airdropAddr);
  console.log("=".repeat(60));
  console.log("BUnitAirdrop.consumeFromUser");
  console.log("=".repeat(60));
  console.log("User:", user);
  console.log("Amount:", amountHuman, "B-Units (raw:", amount.toString() + ")");
  console.log("Kind:", kindName || kind.toString(), kindName ? `(txCategory=keccak256("${kindName}"))` : "(txCategory=buintBurn)");
  console.log("BUnitAirdrop USDC balance before:", ethers.formatUnits(balBefore, 6));

  let kindToUse = kind;
  if (kindName) {
    const kindId = kind > 0n ? kind : 1n;
    const existingName = await airdrop.getKindName(kindId);
    if (existingName !== kindName) {
      console.log("\nRegistering kind", kindId.toString(), "as", kindName);
      const regTx = await airdrop.registerKind(kindId, kindName);
      await regTx.wait();
      console.log("registerKind tx:", regTx.hash);
    }
    kindToUse = kindId;
  }

  const baseHash = (process.env.BASE_HASH as `0x${string}`) || ethers.keccak256(ethers.toUtf8Bytes(`consume:${user}:${Date.now()}`));
  const baseGas = 0n;

  console.log("\nCalling consumeFromUser...");
  // Gas: ~1.5M used in prior run; Indexer sync needs extra. Use 2.5M to avoid OOG on syncTokenAction.
  const tx = await airdrop.consumeFromUser(user, amount, baseHash, baseGas, kindToUse, { gasLimit: 2_500_000 });
  const receipt = await tx.wait();
  console.log("consumeFromUser tx:", tx.hash);
  console.log("Block:", receipt?.blockNumber);

  const balAfter = await usdc.balanceOf(airdropAddr);
  const delta = balAfter - balBefore;
  console.log("\nBUnitAirdrop USDC balance after:", ethers.formatUnits(balAfter, 6));
  console.log("USDC delta:", ethers.formatUnits(delta, 6), "USDC");
  console.log("\nExpected: 1 B-Unit from paid pool = 0.01 USDC (user had 20 free + 1 paid)");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
