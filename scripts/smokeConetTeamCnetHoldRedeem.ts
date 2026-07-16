/**
 * Smoke ConetTeamCnetHold redeem line on CoNET:
 *   createRedeem (EIP-712) → consumeRedeem → claimVested
 *
 *   npx hardhat run scripts/smokeConetTeamCnetHoldRedeem.ts --network conet
 *
 * Env (optional):
 *   CONET_TEAM_HOLD_PROXY — default from deployments/conet-ConetTeamCnetHold.json
 *   CONET_TEAM_HOLD_REDEEM_AMOUNT_WEI — default 0.001 ether
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const HOLD_ABI = [
  "function redeemAdmins(address) view returns (bool)",
  "function redeemAdminNonces(address) view returns (uint256)",
  "function beneficiaryNonces(address) view returns (uint256)",
  "function unallocated() view returns (uint256)",
  "function getRedeem(bytes32) view returns (uint256 amount, uint64 validAfter, uint64 validBefore, bool active)",
  "function allocationOf(address) view returns (uint256)",
  "function releasableOf(address) view returns (uint256)",
  "function releasedOf(address) view returns (uint256)",
  "function hashCreateHoldRedeem(bytes32,uint256,uint64,uint64,uint256) view returns (bytes32)",
  "function createRedeem(bytes32,uint256,uint64,uint64,address,uint256,bytes)",
  "function consumeRedeem(string,address)",
  "function claimVested(address,uint256,uint64,uint256,bytes)",
];

const CREATE_TYPES = {
  CreateHoldRedeem: [
    { name: "codeHash", type: "bytes32" },
    { name: "amount", type: "uint256" },
    { name: "validAfter", type: "uint64" },
    { name: "validBefore", type: "uint64" },
    { name: "nonce", type: "uint256" },
  ],
} as const;

const CLAIM_TYPES = {
  ClaimHoldVested: [
    { name: "beneficiary", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "deadline", type: "uint64" },
    { name: "nonce", type: "uint256" },
  ],
} as const;

function loadProxy(): string {
  const env = process.env.CONET_TEAM_HOLD_PROXY?.trim();
  if (env && ethers.isAddress(env)) return ethers.getAddress(env);
  const p = path.join(root, "deployments/conet-ConetTeamCnetHold.json");
  if (!fs.existsSync(p)) throw new Error("missing deployments/conet-ConetTeamCnetHold.json");
  const d = JSON.parse(fs.readFileSync(p, "utf-8")) as { proxy?: string; address?: string };
  const addr = d.proxy || d.address;
  if (!addr || !ethers.isAddress(addr)) throw new Error("deployments JSON missing proxy");
  return ethers.getAddress(addr);
}

async function sleep(ms: number): Promise<void> {
  await new Promise((r) => setTimeout(r, ms));
}

async function main() {
  const { ethers: ethersHH } = await networkModule.connect();
  const signers = await ethersHH.getSigners();
  const admin = signers[0];
  if (!admin) throw new Error("no signer");
  const net = await ethersHH.provider.getNetwork();
  if (net.chainId !== 224422n) throw new Error(`期望 chainId 224422，当前 ${net.chainId}`);

  const proxy = loadProxy();
  const amount =
    process.env.CONET_TEAM_HOLD_REDEEM_AMOUNT_WEI != null
      ? BigInt(process.env.CONET_TEAM_HOLD_REDEEM_AMOUNT_WEI)
      : ethers.parseEther("0.001");

  // Prefer a second Hardhat account as beneficiary so claimVested EIP-712 is distinct from admin.
  const beneficiarySigner = signers[1] ?? admin;
  const beneficiary = ethers.getAddress(beneficiarySigner.address);

  const hold = new ethers.Contract(proxy, HOLD_ABI, admin);
  const isRedeemAdmin = await hold.redeemAdmins(admin.address);
  if (!isRedeemAdmin) throw new Error(`signer ${admin.address} is not redeemAdmin`);

  const free = (await hold.unallocated()) as bigint;
  console.log("=".repeat(60));
  console.log("Smoke ConetTeamCnetHold redeem line");
  console.log("=".repeat(60));
  console.log("proxy:", proxy);
  console.log("redeemAdmin:", admin.address);
  console.log("beneficiary:", beneficiary);
  console.log("amount:", ethers.formatEther(amount), "CNET");
  console.log("unallocated:", ethers.formatEther(free), "CNET");
  if (amount > free) throw new Error("redeem amount > unallocated");

  const secret = `hold-smoke-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  const codeHash = ethers.keccak256(ethers.toUtf8Bytes(secret));
  const nonce = (await hold.redeemAdminNonces(admin.address)) as bigint;
  const validAfter = 0n;
  const validBefore = 0n; // open-ended

  const domain = {
    name: "ConetTeamCnetHold",
    version: "1",
    chainId: Number(net.chainId),
    verifyingContract: proxy,
  };
  const message = {
    codeHash,
    amount,
    validAfter,
    validBefore,
    nonce,
  };

  // Cross-check digest with on-chain hasher
  const onchainDigest = (await hold.hashCreateHoldRedeem(
    codeHash,
    amount,
    validAfter,
    validBefore,
    nonce
  )) as string;
  const offlineDigest = ethers.TypedDataEncoder.hash(domain, CREATE_TYPES, message);
  if (onchainDigest.toLowerCase() !== offlineDigest.toLowerCase()) {
    throw new Error(`EIP-712 digest mismatch\nonchain=${onchainDigest}\noffline=${offlineDigest}`);
  }

  const signature = await admin.signTypedData(domain, CREATE_TYPES, message);
  console.log("\n[1/3] createRedeem");
  console.log("  codeHash:", codeHash);
  console.log("  nonce:", nonce.toString());
  const createTx = await hold.createRedeem(
    codeHash,
    amount,
    validAfter,
    validBefore,
    admin.address,
    nonce,
    signature
  );
  console.log("  tx:", createTx.hash);
  await createTx.wait();
  const offer = await hold.getRedeem(codeHash);
  if (!offer.active || offer.amount !== amount) {
    throw new Error("createRedeem did not store active offer");
  }
  console.log("  ✅ redeem offer active");

  console.log("\n[2/3] consumeRedeem(code → beneficiary)");
  // Do not log full secret in production logs; for smoke it is OK once.
  console.log("  secret length:", secret.length, "(code not logged)");
  const allocBefore = (await hold.allocationOf(beneficiary)) as bigint;
  const consumeTx = await hold.consumeRedeem(secret, beneficiary);
  console.log("  tx:", consumeTx.hash);
  await consumeTx.wait();
  const allocAfter = (await hold.allocationOf(beneficiary)) as bigint;
  const offerAfter = await hold.getRedeem(codeHash);
  if (offerAfter.active) throw new Error("redeem still active after consume");
  if (allocAfter - allocBefore !== amount) {
    throw new Error(
      `allocation delta mismatch: expected ${amount}, got ${allocAfter - allocBefore}`
    );
  }
  console.log("  allocation:", ethers.formatEther(allocAfter), "CNET");
  console.log("  ✅ consumeRedeem OK");

  console.log("\n[3/3] claimVested (wait for unlock > 0)");
  const holdAsBen = hold.connect(beneficiarySigner);
  let releasable = 0n;
  for (let i = 0; i < 8; i++) {
    await sleep(5_000);
    releasable = (await holdAsBen.releasableOf(beneficiary)) as bigint;
    console.log(`  tick ${i + 1}: releasable=${releasable.toString()} wei`);
    if (releasable > 0n) break;
  }
  if (releasable === 0n) {
    throw new Error("releasableOf still 0 after wait — vesting clock check failed");
  }

  const claimNonce = (await hold.beneficiaryNonces(beneficiary)) as bigint;
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const claimMessage = {
    beneficiary,
    amount: releasable,
    deadline,
    nonce: claimNonce,
  };
  const claimSig = await beneficiarySigner.signTypedData(domain, CLAIM_TYPES, claimMessage);
  const releasedBefore = (await hold.releasedOf(beneficiary)) as bigint;
  const claimTx = await hold.claimVested(beneficiary, releasable, deadline, claimNonce, claimSig);
  console.log("  claimVested tx:", claimTx.hash);
  const rc = await claimTx.wait();
  if (rc?.status !== 1) throw new Error("claimVested failed");
  const releasedAfter = (await hold.releasedOf(beneficiary)) as bigint;
  if (releasedAfter - releasedBefore !== releasable) {
    throw new Error("releasedOf did not increase by claimed amount");
  }
  console.log("  released:", releasedAfter.toString(), "wei");
  console.log("  ✅ claimVested OK");

  // Persist smoke result into deployment JSON (append, keep existing fields)
  const outPath = path.join(root, "deployments/conet-ConetTeamCnetHold.json");
  if (fs.existsSync(outPath)) {
    const prev = JSON.parse(fs.readFileSync(outPath, "utf-8")) as Record<string, unknown>;
    prev.redeemSmoke = {
      at: new Date().toISOString(),
      amountWei: amount.toString(),
      codeHash,
      beneficiary,
      createTx: createTx.hash,
      consumeTx: consumeTx.hash,
      claimTx: claimTx.hash,
      claimedWei: releasable.toString(),
      allocationWei: allocAfter.toString(),
    };
    fs.writeFileSync(outPath, JSON.stringify(prev, null, 2) + "\n", "utf-8");
    console.log("\nsaved redeemSmoke →", outPath);
  }

  console.log("\n✅ redeem line smoke OK");
  console.log("Explorer proxy:", `https://mainnet.conet.network/address/${proxy}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
