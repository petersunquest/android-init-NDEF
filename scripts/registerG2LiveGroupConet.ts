/**
 * Register laboratory G2 on the existing GlobalArchiveRoutingRegistry
 * proxy. Does not redeploy the proxy. Does not restart EL/CL.
 *
 * Default is read-only precheck. Broadcast only when:
 *   CONFIRM_REGISTER_G2=1
 *
 *   npx hardhat run scripts/registerG2LiveGroupConet.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT = path.resolve(__dirname, "..");

const PROXY = "0x8B261eAECdFfeE9e7aC9fFe73386B0d6C9E76AfB";
const EXPECTED_OWNER = "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1";
const DEPLOYMENT_PATH = path.join(ROOT, "deployments", "conet-GlobalArchiveRoutingRegistry.json");
const INVENTORY_PATH = path.join(
  ROOT,
  "src/conet-layer2/pilot/inventories/conet-dle-m6-g2-2026-08.json",
);
const EVIDENCE_PATH = path.join(
  ROOT,
  "src/conet-layer2/pilot/evidence/conet-dle-g2-l1-register-2026-08/g2-l1-register.json",
);

type InventoryDomain = {
  domainId?: string;
  role?: string;
  participantWallet?: string;
};

function loadJson(file: string): Record<string, unknown> {
  return JSON.parse(fs.readFileSync(file, "utf8")) as Record<string, unknown>;
}

function writeJson(file: string, value: unknown): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function loadG2Roster(getAddress: (value: string) => string): {
  active: string[];
  standby: string[];
  roster: Array<{ index: number; domainId: string; role: string; participantWallet: string }>;
} {
  const inventory = loadJson(INVENTORY_PATH);
  const domains = Array.isArray(inventory.domains) ? (inventory.domains as InventoryDomain[]) : [];
  const active: string[] = [];
  const standby: string[] = [];
  const roster: Array<{ index: number; domainId: string; role: string; participantWallet: string }> = [];
  for (const domain of domains) {
    if (typeof domain.domainId !== "string" || typeof domain.participantWallet !== "string") {
      throw new Error(`${INVENTORY_PATH} is missing domainId/participantWallet`);
    }
    const wallet = getAddress(domain.participantWallet);
    const role = domain.role === "standby" ? "standby" : "active";
    roster.push({ index: roster.length, domainId: domain.domainId, role, participantWallet: wallet });
    if (role === "standby") standby.push(wallet);
    else active.push(wallet);
  }
  if (active.length !== 5 || standby.length !== 2) {
    throw new Error(`G2 inventory must be 5 active + 2 standby, got ${active.length}+${standby.length}`);
  }
  const unique = new Set([...active, ...standby].map((row) => row.toLowerCase()));
  if (unique.size !== 7) throw new Error("G2 inventory wallets are not unique");
  return { active, standby, roster };
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  if (net.chainId !== 224422n) {
    throw new Error(`Expected CoNET chainId 224422, got ${net.chainId}`);
  }

  const { active, standby, roster } = loadG2Roster(ethers.getAddress);
  const Impl = await ethers.getContractFactory("GlobalArchiveRoutingRegistryV1");
  const registry = Impl.attach(PROXY);
  const owner = ethers.getAddress(await registry.owner());
  const nextGroupId = await registry.nextGroupId();
  const signerAddress = ethers.getAddress(signer.address);
  const signerBalance = await ethers.provider.getBalance(signer.address);
  const assigned = [];
  for (const row of roster) {
    const group = await registry.groupOfWallet(row.participantWallet);
    assigned.push({ ...row, groupOfWallet: group.toString() });
  }

  const groupKeyHash = ethers.id("dle.lab.group-2.key");
  const membershipRoot = ethers.id("dle.lab.group-2.membership");
  const standbyRoot = ethers.id("dle.lab.group-2.standby");

  const precheck = {
    proxy: PROXY,
    owner,
    signer: signerAddress,
    signerCnet: ethers.formatEther(signerBalance),
    nextGroupId: nextGroupId.toString(),
    expectedOwner: EXPECTED_OWNER,
    expectedNextGroupId: "2",
    groupKeyHash,
    membershipRoot,
    standbyRoot,
    keyEpoch: 1,
    assigned,
  };

  console.log("=".repeat(60));
  console.log("G2 registerLiveGroup precheck (existing GARR proxy)");
  console.log("=".repeat(60));
  console.log(JSON.stringify(precheck, null, 2));

  const blockers: string[] = [];
  if (owner !== ethers.getAddress(EXPECTED_OWNER)) blockers.push(`owner ${owner} != ${EXPECTED_OWNER}`);
  if (signerAddress !== owner) blockers.push(`signer ${signerAddress} is not GARR owner`);
  if (nextGroupId !== 2n) blockers.push(`nextGroupId ${nextGroupId} != 2`);
  if (signerBalance === 0n) blockers.push("signer CNET balance is 0");
  for (const row of assigned) {
    if (row.groupOfWallet !== "0") {
      blockers.push(`${row.domainId} already assigned to group ${row.groupOfWallet}`);
    }
  }
  if (blockers.length > 0) {
    throw new Error(`precheck failed:\n- ${blockers.join("\n- ")}`);
  }
  console.log("precheck ok — wallets free, nextGroupId=2, signer is owner");

  if (process.env.CONFIRM_REGISTER_G2 !== "1") {
    console.log("CONFIRM_REGISTER_G2 is not 1 — no broadcast");
    return;
  }

  const tx = await registry.registerLiveGroup(
    active,
    standby,
    groupKeyHash,
    membershipRoot,
    standbyRoot,
    1,
  );
  const receipt = await tx.wait();
  if (receipt?.status !== 1) throw new Error(`registerLiveGroup failed: ${tx.hash}`);

  const liveIds: bigint[] = await registry.liveGroupIds();
  const archives: string[] = await registry.archivesOf(2);
  if (!liveIds.map(String).includes("2")) {
    throw new Error(`liveGroupIds() missing 2: ${liveIds.join(",")}`);
  }
  const expected = [...active, ...standby];
  for (let i = 0; i < 7; i += 1) {
    if (ethers.getAddress(archives[i]) !== expected[i]) {
      throw new Error(`archivesOf(2)[${i}] != ${roster[i].domainId}`);
    }
  }

  const existing = loadJson(DEPLOYMENT_PATH);
  existing.secondGroup = {
    groupId: 2,
    keyEpoch: 1,
    membershipEpoch: 1,
    groupKeyHash,
    membershipRoot,
    standbyRoot,
    registerTxHash: tx.hash,
    registerBlock: receipt.blockNumber ?? null,
    roster,
    note: "User-visible Group ID is registerTxHash, not uint 2 and not the lab keccak placeholder.",
  };
  existing.timestamp = new Date().toISOString();
  writeJson(DEPLOYMENT_PATH, existing);

  const evidence = {
    schema: "conet-dle-g2-l1-register-v1",
    acceptedAt: new Date().toISOString(),
    notThirtyDayQualification: true,
    notProductionDepin: true,
    proxy: PROXY,
    groupId: 2,
    registerTxHash: tx.hash,
    registerBlock: receipt.blockNumber ?? null,
    groupKeyHash,
    membershipRoot,
    standbyRoot,
    liveGroupIds: liveIds.map(String),
    archivesOf2: archives,
    roster,
    explorerTx: `https://mainnet.conet.network/tx/${tx.hash}`,
  };
  writeJson(EVIDENCE_PATH, evidence);

  console.log("[ok] registerLiveGroup groupId=2 tx:", tx.hash);
  console.log("[ok] archivesOf(2) matches G2 inventory");
  console.log("saved:", DEPLOYMENT_PATH);
  console.log("evidence:", EVIDENCE_PATH);
  console.log("Explorer:", `https://mainnet.conet.network/tx/${tx.hash}`);
  console.log("User-visible Group ID is this tx hash — not uint 2, not the lab keccak.");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
