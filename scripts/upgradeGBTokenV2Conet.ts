/**
 * Deploy GBTokenV2 implementation and UUPS-upgrade the CoNET GBToken proxy (CREATE2 同址).
 *
 * Scope: **CoNET only** (chainId 224422). Base / 外链 GB 经入桥均为 mintPaid，无 free 池，可暂不升级。
 *
 * V2 rules:
 *   - transfer / transferFrom / EIP-3009: paidPool only
 *   - user burn: paidPool only
 *   - admin consumeFree / consumeGb: protocol use of free (and waterfall)
 *
 * Env:
 *   CONET_RPC_URL — default https://rpc1.conet.network
 *   GB_TOKEN_PROXY — override proxy (default CREATE2 0xC3EF…38D8)
 *   DRY_RUN=1 — deploy impl only, no upgrade tx
 *   SKIP_VERIFY=1 — skip Blockscout verify after upgrade
 *
 * Usage:
 *   npm run compile
 *   npx tsx scripts/upgradeGBTokenV2Conet.ts
 *   DRY_RUN=1 npx tsx scripts/upgradeGBTokenV2Conet.ts
 */
import { execSync } from "child_process";
import fs from "fs";
import path from "path";
import { homedir } from "os";
import { ethers } from "ethers";
import { GB_TOKEN_ERC20_CREATE2_PREDICTED } from "./conetTreasuryDeployConstants.js";

const CHAIN_ID = 224422;
const RPC = process.env.CONET_RPC_URL || "https://rpc1.conet.network";
const PROXY = process.env.GB_TOKEN_PROXY || GB_TOKEN_ERC20_CREATE2_PREDICTED;
const VALIDATOR_DEPOSIT_REDEEM =
  process.env.CONET_VALIDATOR_DEPOSIT_REDEEM ||
  "0xc71e246DD78B37C2fABc905D340932F28F503433";
const BLOCKSCOUT = process.env.CONET_BLOCKSCOUT_URL || "https://mainnet.conet.network";
const EIP1967_IMPL_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

function loadAdminKey(): string {
  const masterPath = path.join(homedir(), ".master.json");
  const master = JSON.parse(fs.readFileSync(masterPath, "utf-8")) as {
    settle_contractAdmin?: string[];
    beamio_Admins?: string[];
  };
  const keys = [...(master.settle_contractAdmin ?? []), ...(master.beamio_Admins ?? [])];
  const wanted = (
    process.env.GB_TOKEN_ADMIN ||
    getInitialAdminFromMeta() ||
    "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1"
  ).toLowerCase();
  for (const raw of keys) {
    const key = raw.startsWith("0x") ? raw : `0x${raw}`;
    try {
      if (new ethers.Wallet(key).address.toLowerCase() === wanted) return key;
    } catch {
      /* skip */
    }
  }
  throw new Error(`GBToken admin key for ${wanted} not found in ~/.master.json`);
}

function getInitialAdminFromMeta(): string | undefined {
  const p = path.join(process.cwd(), "deployments", "gbToken-create2-meta.json");
  if (!fs.existsSync(p)) return undefined;
  return JSON.parse(fs.readFileSync(p, "utf-8")).initialAdmin as string | undefined;
}

async function checkVerified(addr: string): Promise<boolean> {
  const r = await fetch(`${BLOCKSCOUT}/api/v2/smart-contracts/${addr}`);
  if (!r.ok) return false;
  const d = (await r.json()) as { is_verified?: boolean; is_partially_verified?: boolean };
  return Boolean(d.is_verified || d.is_partially_verified);
}

function verifyImplementationOnBlockscout(implAddress: string): void {
  console.log("\n[verify] GBTokenV2 implementation on Blockscout (Standard JSON)…");
  execSync(`npx tsx scripts/verifyGBTokenV2ImplConet.ts`, {
    stdio: "inherit",
    cwd: process.cwd(),
    env: { ...process.env, IMPL: implAddress },
  });
}

async function ensureValidatorDepositRedeem(
  gb: ethers.Contract,
  wallet: ethers.Wallet,
): Promise<string | null> {
  const vdr = ethers.getAddress(VALIDATOR_DEPOSIT_REDEEM);
  const gbFull = new ethers.Contract(
    PROXY,
    [
      "function validatorDepositRedeem() view returns (address)",
      "function setValidatorDepositRedeem(address)",
    ],
    wallet,
  );
  let current = ethers.ZeroAddress;
  try {
    current = await gbFull.validatorDepositRedeem!();
  } catch {
    console.log("validatorDepositRedeem() unavailable (pre-V2?)");
  }
  if (current.toLowerCase() === vdr.toLowerCase()) {
    console.log("validatorDepositRedeem already", vdr);
    return null;
  }
  if (process.env.DRY_RUN === "1") {
    console.log("DRY_RUN=1 — would setValidatorDepositRedeem", vdr);
    return null;
  }
  const tx = await gbFull.setValidatorDepositRedeem!(vdr);
  console.log("setValidatorDepositRedeem tx", tx.hash);
  const rc = await tx.wait();
  if (rc?.status !== 1) throw new Error("setValidatorDepositRedeem failed");
  const after = await gbFull.validatorDepositRedeem!();
  if (ethers.getAddress(after) !== vdr) {
    throw new Error(`validatorDepositRedeem mismatch after set: ${after}`);
  }
  console.log("setValidatorDepositRedeem OK →", vdr);
  return tx.hash;
}

async function main() {
  const artifactPath = path.join(
    process.cwd(),
    "artifacts/src/b-unit/GBTokenV2.sol/GBTokenV2.json",
  );
  if (!fs.existsSync(artifactPath)) {
    throw new Error("Missing GBTokenV2 artifact — run: npm run compile");
  }
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8")) as {
    abi: ethers.InterfaceAbi;
    bytecode: string;
  };

  const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID);
  const wallet = new ethers.Wallet(loadAdminKey(), provider);
  console.log("signer", wallet.address);
  console.log("proxy", PROXY);
  console.log("rpc", RPC);

  const net = await provider.getNetwork();
  if (Number(net.chainId) !== CHAIN_ID) {
    throw new Error(`Unexpected chainId ${net.chainId}`);
  }

  const proxyCode = await provider.getCode(PROXY);
  if (proxyCode === "0x" || proxyCode.length <= 2) {
    throw new Error(`No contract code at proxy ${PROXY}`);
  }

  const gb = new ethers.Contract(
    PROXY,
    [
      "function admins(address) view returns (bool)",
      "function version() view returns (uint256)",
      "function upgradeToAndCall(address,bytes)",
    ],
    wallet,
  );

  const isAdmin = await gb.admins!(wallet.address);
  if (!isAdmin) {
    throw new Error(`Signer ${wallet.address} is not GBToken admin`);
  }

  let beforeVersion: bigint | null = null;
  try {
    beforeVersion = await gb.version!();
  } catch {
    console.log("current implementation: V1 (no version())");
  }

  const beforeSlot = await provider.getStorage(PROXY, EIP1967_IMPL_SLOT);
  const beforeImpl = ethers.getAddress("0x" + beforeSlot.slice(-40));
  console.log("currentImpl", beforeImpl);

  let implAddress = beforeImpl;
  let deployTxHash: string | null = null;
  let upgradeTxHash: string | null = null;
  let upgradeBlock: number | null = null;

  const alreadyV2 = beforeVersion !== null && beforeVersion >= 2n;
  if (alreadyV2) {
    console.log("proxy already V2+, version =", beforeVersion!.toString(), "— skip upgradeToAndCall");
  } else {
    const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);
    console.log("deploying GBTokenV2 implementation…");
    const impl = await factory.deploy();
    await impl.waitForDeployment();
    implAddress = await impl.getAddress();
    const deployTx = impl.deploymentTransaction();
    deployTxHash = deployTx?.hash ?? null;
    console.log("newImpl", implAddress, "deployTx", deployTxHash);

    if (process.env.DRY_RUN === "1") {
      console.log("DRY_RUN=1 — skip upgradeToAndCall");
      return;
    }

    const upgradeTx = await gb.upgradeToAndCall!(implAddress, "0x");
    console.log("upgradeTx", upgradeTx.hash);
    const receipt = await upgradeTx.wait();
    if (receipt?.status !== 1) throw new Error("upgradeToAndCall failed");
    upgradeTxHash = upgradeTx.hash;
    upgradeBlock = receipt?.blockNumber ?? null;

    const afterSlot = await provider.getStorage(PROXY, EIP1967_IMPL_SLOT);
    const afterImpl = ethers.getAddress("0x" + afterSlot.slice(-40));
    if (afterImpl !== ethers.getAddress(implAddress)) {
      throw new Error(`impl slot mismatch: ${afterImpl} !== ${implAddress}`);
    }

    const version = await gb.version!();
    if (version !== 2n) {
      throw new Error(`expected version()=2, got ${version}`);
    }
    console.log("upgrade OK, version() =", version.toString());
  }

  const vdrTxHash = await ensureValidatorDepositRedeem(gb, wallet);

  const finalVersion = await gb.version!();
  const finalVdr = await new ethers.Contract(
    PROXY,
    ["function validatorDepositRedeem() view returns (address)"],
    provider,
  ).validatorDepositRedeem!();

  const out = {
    network: "conet",
    chainId: CHAIN_ID,
    proxy: PROXY,
    implementation: implAddress,
    previousImplementation: beforeImpl,
    version: Number(finalVersion),
    validatorDepositRedeem: ethers.getAddress(finalVdr),
    deployTx: deployTxHash,
    upgradeTx: upgradeTxHash,
    setValidatorDepositRedeemTx: vdrTxHash,
    upgradeBlock,
    updatedAt: new Date().toISOString(),
  };
  const outPath = path.join(process.cwd(), "deployments/conet-GBToken-v2-upgrade.json");
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n");
  console.log("wrote", outPath);

  if (process.env.SKIP_VERIFY !== "1" && process.env.DRY_RUN !== "1") {
    const verified = await checkVerified(implAddress);
    if (verified) {
      console.log("[verify] implementation already verified on Blockscout");
    } else {
      verifyImplementationOnBlockscout(implAddress);
    }
  }

  console.log("\nDone.");
  console.log("  proxy:", `${BLOCKSCOUT}/address/${PROXY}`);
  console.log("  impl:", `${BLOCKSCOUT}/address/${implAddress}`);
  console.log("  version():", finalVersion.toString());
  console.log("  validatorDepositRedeem:", ethers.getAddress(finalVdr));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
