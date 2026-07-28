/**
 * Same signer resolution as deployBeamioAccount.ts:
 * `ethers.getSigners()[0]` ← Hardhat `networks.*.accounts` from `PRIVATE_KEY` in `.env`.
 *
 * For Base mainnet, that private key MUST be the EOA in `deployments/base-BeamioAccount.json`
 * field `deployer` (the account that ran `npm run deploy:base`). Debug/repro scripts call
 * `ensureSignerMatchesBeamioAccountDeployerUnlessSkipped` so a wrong key fails fast.
 *
 * If `PRIVATE_KEY` is unset and signers[] is empty: `ALLOW_MASTER_JSON_SIGNER=1` loads
 * `~/.master.json` → `settle_contractAdmin[0]`. Use only when that key is the same EOA as
 * `deployer` in *-BeamioAccount.json (e.g. CoNET Master paymaster key).
 */
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";
import { ethers as ethersLib, type ContractRunner, type Signer } from "ethers";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function deploymentsRoot(): string {
  return path.join(__dirname, "..", "..", "deployments");
}

function loadMasterPkIfAllowed(): string | null {
  if (process.env.ALLOW_MASTER_JSON_SIGNER !== "1") return null;
  const setupPath = path.join(homedir(), ".master.json");
  if (!fs.existsSync(setupPath)) return null;
  try {
    const data = JSON.parse(fs.readFileSync(setupPath, "utf-8"));
    const pk = data?.settle_contractAdmin?.[0];
    if (!pk || typeof pk !== "string") return null;
    return pk.startsWith("0x") ? pk : `0x${pk}`;
  } catch {
    return null;
  }
}

export async function getHardhatDeploySigner(ethers: {
  getSigners: () => Promise<Signer[]>;
  provider: ContractRunner;
}): Promise<Signer> {
  const signers = await ethers.getSigners();
  if (signers[0]) return signers[0];
  const pk = loadMasterPkIfAllowed();
  if (pk) {
    return new ethersLib.Wallet(pk, ethers.provider) as unknown as Signer;
  }
  throw new Error(
    "No Hardhat signer. Set PRIVATE_KEY in .env for this network (same as npm run deploy:base). " +
      "Or set ALLOW_MASTER_JSON_SIGNER=1 to use ~/.master.json settle_contractAdmin[0].",
  );
}

function beamioAccountDeploymentPath(chainId: bigint, networkName: string): string {
  const root = deploymentsRoot();
  if (chainId === 8453n) return path.join(root, "base-BeamioAccount.json");
  if (chainId === 84532n) return path.join(root, "baseSepolia-BeamioAccount.json");
  return path.join(root, `${networkName}-BeamioAccount.json`);
}

/** Throws if signer address ≠ deployer in *-BeamioAccount.json for this chain. */
export async function assertSignerIsBeamioAccountDeployer(
  ethers: { provider: { getNetwork: () => Promise<{ chainId: bigint; name: string }> } },
  signer: { getAddress: () => Promise<string> },
): Promise<{ deployer: string; deploymentFile: string }> {
  const net = await ethers.provider.getNetwork();
  const deploymentFile = beamioAccountDeploymentPath(net.chainId, net.name);
  if (!fs.existsSync(deploymentFile)) {
    throw new Error(
      `Missing ${deploymentFile}; deploy BeamioAccount first (npm run deploy:base) or copy deployment json.`,
    );
  }
  const meta = JSON.parse(fs.readFileSync(deploymentFile, "utf8")) as { deployer?: string };
  if (!meta.deployer) throw new Error(`${deploymentFile} missing deployer field`);
  const expected = String(meta.deployer).toLowerCase();
  const from = (await signer.getAddress()).toLowerCase();
  if (from !== expected) {
    throw new Error(
      `Signer must match BeamioAccount deployer (${path.basename(deploymentFile)}).\n` +
        `  expected: ${expected}\n` +
        `  signer:   ${from}`,
    );
  }
  return { deployer: meta.deployer, deploymentFile };
}

/**
 * Default for debug/deploy tooling: signer must match *-BeamioAccount.json `deployer` (same as npm run deploy:base).
 * Opt out: SKIP_BEAMIO_ACCOUNT_DEPLOYER_CHECK=1
 */
export async function ensureSignerMatchesBeamioAccountDeployerUnlessSkipped(
  ethers: { provider: { getNetwork: () => Promise<{ chainId: bigint; name: string }> } },
  signer: { getAddress: () => Promise<string> },
): Promise<void> {
  if (process.env.SKIP_BEAMIO_ACCOUNT_DEPLOYER_CHECK === "1") {
    console.warn(
      "[hardhatDeploySigner] SKIP_BEAMIO_ACCOUNT_DEPLOYER_CHECK=1 — not verifying signer against *-BeamioAccount.json",
    );
    return;
  }
  const { deployer, deploymentFile } = await assertSignerIsBeamioAccountDeployer(ethers, signer);
  console.log(
    "[hardhatDeploySigner] Signer matches BeamioAccount deployer:",
    deployer,
    `(${path.basename(deploymentFile)})`,
  );
}
