/**
 * Diagnose createCard failure using the SAME EOA as BeamioAccount deployer.
 * Connection matches deployBeamioAccount.ts: `network.connect()` + Hardhat `PRIVATE_KEY`.
 *
 * Prerequisites:
 * - .env PRIVATE_KEY = key recorded in deployments/*-BeamioAccount.json as `deployer`
 * - Optional: FAILED_TX (default: known failing createCard tx on Base)
 * - Optional: USER_CARD_FACTORY_ADDRESS — override factory
 * - Optional: ALLOW_MASTER_JSON_SIGNER=1 — legacy ~/.master.json signer
 * - Optional: SKIP_BEAMIO_ACCOUNT_DEPLOYER_CHECK=1 — skip deployer vs *-BeamioAccount.json check
 *
 * Usage:
 *   npx hardhat run scripts/diagReplayCreateCardWithBeamioAccountDeployer.ts --network base
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import {
  ensureSignerMatchesBeamioAccountDeployerUnlessSkipped,
  getHardhatDeploySigner,
} from "./utils/hardhatDeploySigner.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DEPLOYMENTS_DIR = path.join(__dirname, "..", "deployments");

const DEFAULT_FAILED_TX =
  process.env.FAILED_TX ||
  "0x14f52498469d5f62b68835dcd441763c59e45ae20c7fccf56a232e15d0cd2925";

const FACTORY_ABI = [
  "function isPaymaster(address) view returns (bool)",
  "function owner() view returns (address)",
  "function deployer() view returns (address)",
  "function aaFactory() view returns (address)",
  "function defaultGovernanceModule() view returns (address)",
  "function defaultAdminStatsQueryModule() view returns (address)",
  "function defaultRedeemModule() view returns (address)",
];

function loadJson(rel: string): any {
  const p = path.join(DEPLOYMENTS_DIR, rel);
  if (!fs.existsSync(p)) return null;
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

function decodeRevertData(ethersLike: { id: (s: string) => string }, data: string): string {
  if (!data || data === "0x") return "(empty)";
  const sel = data.slice(0, 10);
  const bmStep = ethersLike.id("BM_DeployFailedAtStep(uint8)").slice(0, 10);
  if (sel === bmStep && data.length >= 74) {
    const step = BigInt(data.slice(10, 74));
    return `BM_DeployFailedAtStep(step=${step})`;
  }
  return `raw ${sel}… (${(data.length - 2) / 2} bytes)`;
}

export async function runBeamioAccountDeployerDiagnostics(ethers: any): Promise<void> {
  const signer = await getHardhatDeploySigner(ethers);
  await ensureSignerMatchesBeamioAccountDeployerUnlessSkipped(ethers, signer);
  const from = (await signer.getAddress()).toLowerCase();
  console.log(
    "Diagnostics signer:",
    from,
    process.env.SKIP_BEAMIO_ACCOUNT_DEPLOYER_CHECK === "1"
      ? "(SKIP_BEAMIO_ACCOUNT_DEPLOYER_CHECK — not verified vs *-BeamioAccount.json)"
      : "(matches *-BeamioAccount.json deployer)",
  );

  const provider = ethers.provider;
  const net = await provider.getNetwork();
  const factoryJsonRel =
    net.chainId === 84532n
      ? "baseSepolia-UserCardFactory.json"
      : net.chainId === 8453n
        ? "base-UserCardFactory.json"
        : `${net.name}-UserCardFactory.json`;

  const factoryAddr = (
    process.env.USER_CARD_FACTORY_ADDRESS ||
    loadJson(factoryJsonRel)?.contracts?.beamioUserCardFactoryPaymaster?.address ||
    loadJson(factoryJsonRel)?.address ||
    ""
  ).toString();
  if (!factoryAddr || !ethers.isAddress(factoryAddr)) {
    console.warn("No USER_CARD_FACTORY_ADDRESS / base-UserCardFactory.json — skip factory snapshot.");
  } else {
    const factory = new ethers.Contract(factoryAddr, FACTORY_ABI, provider);
    console.log("\n--- Card factory snapshot ---");
    console.log("factory:", factoryAddr);
    try {
      const [isPm, fo, fd, aa, gov, asq, redeem] = await Promise.all([
        factory.isPaymaster(from),
        factory.owner(),
        factory.deployer(),
        factory.aaFactory(),
        factory.defaultGovernanceModule(),
        factory.defaultAdminStatsQueryModule(),
        factory.defaultRedeemModule(),
      ]);
      console.log("isPaymaster(deployer):", isPm);
      console.log("owner:", fo);
      console.log("factory.deployer():", fd);
      console.log("aaFactory:", aa);
      console.log("defaultGovernanceModule:", gov);
      console.log("defaultAdminStatsQueryModule:", asq);
      console.log("defaultRedeemModule:", redeem);
    } catch (e: any) {
      console.warn("Factory snapshot failed:", e?.message || e);
    }
  }

  const txHash = DEFAULT_FAILED_TX;
  console.log("\n--- Replay failed tx ---");
  console.log("tx:", txHash);

  const tx = await provider.getTransaction(txHash);
  if (!tx) {
    console.warn(
      `Transaction not found on this RPC: ${txHash}. Set env FAILED_TX to a Base tx hash to replay, or skip replay.`,
    );
    console.log(
      "\nTip: deploy debug factory (same key): npm run deploy:debug-usercard-factory:base; " +
        "then npm run create:debug-card:base",
    );
    return;
  }

  const callTo = tx.to;
  const data = tx.data;
  if (!callTo || !data) {
    throw new Error("TX missing to/data");
  }

  console.log("call.to:", callTo);
  console.log("call.data.length:", (data.length - 2) / 2, "bytes");

  try {
    await provider.call({ from, to: callTo, data });
    console.log("eth_call: succeeded (unexpected if tx reverted on-chain)");
  } catch (e: any) {
    const rd =
      e?.data ??
      e?.error?.data ??
      e?.info?.error?.data ??
      e?.info?.error?.error?.data;
    console.log("eth_call: reverted");
    if (typeof rd === "string" && rd.startsWith("0x")) {
      console.log("revert data:", rd);
      console.log("decoded:", decodeRevertData(ethers, rd));
    } else {
      console.log("revert (no data):", e?.shortMessage || e?.message || e);
    }
  }

  try {
    const gas = await provider.estimateGas({ from, to: callTo, data });
    console.log("estimateGas:", gas.toString());
  } catch (e: any) {
    const rd =
      e?.data ??
      e?.error?.data ??
      e?.info?.error?.data ??
      e?.info?.error?.error?.data;
    console.log("estimateGas: failed");
    if (typeof rd === "string" && rd.startsWith("0x")) {
      console.log("revert data:", rd);
      console.log("decoded:", decodeRevertData(ethers, rd));
    } else {
      console.log("revert (no data):", e?.shortMessage || e?.message || e);
    }
  }

  console.log(
    "\nTip: deploy debug factory (same key): npm run deploy:debug-usercard-factory:base; " +
      "then CARD_FACTORY=... npm run create:debug-card:base",
  );
}

async function main() {
  const { ethers } = await networkModule.connect();
  await runBeamioAccountDeployerDiagnostics(ethers);
}

// Hardhat `run` does not set argv[1] to this file; match script basename in argv (import-safe).
const selfBase = path.basename(fileURLToPath(import.meta.url));
const isHardhatRunThisScript = process.argv.some((a) => path.basename(a) === selfBase);

if (isHardhatRunThisScript) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
