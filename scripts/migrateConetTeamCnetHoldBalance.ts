/**
 * Drain legacy ConetTeamCnetHold (pre–Dec-31 start) into the current proxy:
 *   setStartTimestamp(now - DURATION) → full unlock → claimOwner + claimVested → send native to new Hold.
 *
 *   npx hardhat run scripts/migrateConetTeamCnetHoldBalance.ts --network conet
 *
 * Env (optional):
 *   CONET_TEAM_HOLD_FROM — legacy proxy (default prior known address)
 *   CONET_TEAM_HOLD_TO — destination (default deployments/conet-ConetTeamCnetHold.json)
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

/** First mainnet Hold (start = deploy-time); superseded by Dec-31 deploy. */
const DEFAULT_FROM = "0x6CA5d523eD93c3A5384d14f414858cf0AEEC0C81";

const HOLD_ABI = [
  "function DURATION() view returns (uint64)",
  "function owner() view returns (address)",
  "function startTimestamp() view returns (uint64)",
  "function ownerReleased() view returns (uint256)",
  "function totalAllocated() view returns (uint256)",
  "function totalReleased() view returns (uint256)",
  "function unallocated() view returns (uint256)",
  "function ownerReleasable() view returns (uint256)",
  "function allocationOf(address) view returns (uint256)",
  "function releasableOf(address) view returns (uint256)",
  "function releasedOf(address) view returns (uint256)",
  "function beneficiaryNonces(address) view returns (uint256)",
  "function setStartTimestamp(uint64)",
  "function claimOwnerUnallocated(uint256)",
  "function claimVested(address,uint256,uint64,uint256,bytes)",
];

const CLAIM_TYPES = {
  ClaimHoldVested: [
    { name: "beneficiary", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "deadline", type: "uint64" },
    { name: "nonce", type: "uint256" },
  ],
} as const;

function loadTo(): string {
  const env = process.env.CONET_TEAM_HOLD_TO?.trim();
  if (env && ethers.isAddress(env)) return ethers.getAddress(env);
  const p = path.join(root, "deployments/conet-ConetTeamCnetHold.json");
  const d = JSON.parse(fs.readFileSync(p, "utf-8")) as { proxy?: string; address?: string };
  const addr = d.proxy || d.address;
  if (!addr) throw new Error("missing to proxy");
  return ethers.getAddress(addr);
}

async function main() {
  const { ethers: ethersHH } = await networkModule.connect();
  const signers = await ethersHH.getSigners();
  const ownerSigner = signers[0];
  if (!ownerSigner) throw new Error("no signer");
  const net = await ethersHH.provider.getNetwork();
  if (net.chainId !== 224422n) throw new Error(`chainId ${net.chainId}`);

  const from =
    process.env.CONET_TEAM_HOLD_FROM && ethers.isAddress(process.env.CONET_TEAM_HOLD_FROM)
      ? ethers.getAddress(process.env.CONET_TEAM_HOLD_FROM)
      : DEFAULT_FROM;
  const to = loadTo();
  if (from.toLowerCase() === to.toLowerCase()) throw new Error("from == to");

  const hold = new ethers.Contract(from, HOLD_ABI, ownerSigner);
  const owner = ethers.getAddress(await hold.owner());
  if (ethers.getAddress(ownerSigner.address) !== owner) {
    throw new Error(`signer ${ownerSigner.address} is not Hold owner ${owner}`);
  }

  const duration = BigInt(await hold.DURATION());
  const latest = await ethersHH.provider.getBlock("latest");
  const nowTs = BigInt(latest?.timestamp ?? Math.floor(Date.now() / 1000));
  // Fully unlock: endTimestamp = newStart + DURATION <= now
  const unlockStart = nowTs > duration ? nowTs - duration : 1n;

  const balBefore = await ethersHH.provider.getBalance(from);
  console.log("=".repeat(60));
  console.log("Migrate ConetTeamCnetHold balance → new proxy");
  console.log("=".repeat(60));
  console.log("from:", from);
  console.log("to:", to);
  console.log("balance:", ethers.formatEther(balBefore), "CNET");
  console.log("current start:", (await hold.startTimestamp()).toString());
  console.log("unlock startTimestamp:", unlockStart.toString(), `(end ≈ now)`);

  if (balBefore === 0n) {
    console.log("nothing to migrate");
    return;
  }

  console.log("\n[1/4] setStartTimestamp(fully unlocked)");
  const setTx = await hold.setStartTimestamp(unlockStart);
  console.log("  tx:", setTx.hash);
  await setTx.wait();
  console.log("  ownerReleasable:", (await hold.ownerReleasable()).toString());

  let recovered = 0n;

  console.log("\n[2/4] claimOwnerUnallocated");
  const ownerRel = (await hold.ownerReleasable()) as bigint;
  if (ownerRel > 0n) {
    const ownerBefore = await ethersHH.provider.getBalance(owner);
    const tx = await hold.claimOwnerUnallocated(ownerRel);
    console.log("  tx:", tx.hash);
    const rc = await tx.wait();
    if (rc?.status !== 1) throw new Error("claimOwnerUnallocated failed");
    const ownerAfter = await ethersHH.provider.getBalance(owner);
    // gas spent by owner; track claim amount not delta
    recovered += ownerRel;
    console.log("  claimed:", ethers.formatEther(ownerRel), "CNET");
    console.log("  owner bal delta (net of gas):", ethers.formatEther(ownerAfter - ownerBefore));
  } else {
    console.log("  skip (0)");
  }

  // Find beneficiary with leftover allocation among Hardhat signers (smoke used signers[1])
  console.log("\n[3/4] claimVested for allocated beneficiaries");
  let beneficiaryClaimed = 0n;
  for (const s of signers) {
    const alloc = (await hold.allocationOf(s.address)) as bigint;
    const rel = (await hold.releasableOf(s.address)) as bigint;
    if (alloc === 0n || rel === 0n) continue;
    console.log("  beneficiary:", s.address, "releasable:", ethers.formatEther(rel));
    const holdBen = hold.connect(s);
    const nonce = (await hold.beneficiaryNonces(s.address)) as bigint;
    const deadline = nowTs + 3600n;
    const domain = {
      name: "ConetTeamCnetHold",
      version: "1",
      chainId: Number(net.chainId),
      verifyingContract: from,
    };
    const message = {
      beneficiary: ethers.getAddress(s.address),
      amount: rel,
      deadline,
      nonce,
    };
    const sig = await s.signTypedData(domain, CLAIM_TYPES, message);
    const tx = await holdBen.claimVested(s.address, rel, deadline, nonce, sig);
    console.log("  claimVested tx:", tx.hash);
    await tx.wait();
    beneficiaryClaimed += rel;
    recovered += rel;

    // Forward beneficiary claim to new Hold (owner may not equal beneficiary)
    if (ethers.getAddress(s.address) !== owner) {
      console.log("  forward beneficiary → new Hold");
      const fwd = await s.sendTransaction({ to, value: rel });
      console.log("  forward tx:", fwd.hash);
      await fwd.wait();
    }
  }
  console.log("  beneficiary claimed:", ethers.formatEther(beneficiaryClaimed), "CNET");

  console.log("\n[4/4] forward owner-recovered CNET → new Hold");
  // Owner received ownerRel; if owner was also a beneficiary, that portion already in recovered.
  // Forward exactly ownerRel from owner (the unallocated residual claim).
  if (ownerRel > 0n) {
    const fwd = await ownerSigner.sendTransaction({ to, value: ownerRel });
    console.log("  forward tx:", fwd.hash);
    await fwd.wait();
  }

  const oldBal = await ethersHH.provider.getBalance(from);
  const newBal = await ethersHH.provider.getBalance(to);
  console.log("\nold balance left:", ethers.formatEther(oldBal), "CNET");
  console.log("new balance:", ethers.formatEther(newBal), "CNET");
  console.log("recovered (claimed):", ethers.formatEther(recovered), "CNET");

  if (oldBal > 0n) {
    console.warn("⚠️ old Hold still holds native CNET — check remaining slots / dust");
  } else {
    console.log("✅ old Hold drained");
  }

  const outPath = path.join(root, "deployments/conet-ConetTeamCnetHold.json");
  if (fs.existsSync(outPath)) {
    const prev = JSON.parse(fs.readFileSync(outPath, "utf-8")) as Record<string, unknown>;
    prev.migratedFrom = {
      at: new Date().toISOString(),
      from,
      claimedWei: recovered.toString(),
      ownerClaimedWei: ownerRel.toString(),
      beneficiaryClaimedWei: beneficiaryClaimed.toString(),
      oldBalanceLeftWei: oldBal.toString(),
      newBalanceWei: newBal.toString(),
      unlockStartTimestamp: unlockStart.toString(),
    };
    fs.writeFileSync(outPath, JSON.stringify(prev, null, 2) + "\n", "utf-8");
    console.log("saved migrate note →", outPath);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
