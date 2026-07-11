/**
 * Upgrade ValidatorDepositRedeem implementation behind the existing ERC1967 proxy.
 * Proxy address (withdrawal credentials) MUST NOT change.
 *
 * Runs upgradeToAndCall with fixNativeReentrancyLock() (reinitializer 2) so proxy
 * storage slot for _nativeLock is set to 1 (unlocked).
 *
 * Run:
 *   npx hardhat run scripts/upgradeValidatorDepositRedeemImplConet.ts --network conet
 *
 * Env:
 *   VALIDATOR_DEPOSIT_REDEEM=0x…  override proxy address (default: deployments/conet-addresses.json)
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";
import { deployValidatorDepositRedeemLibraries } from "./utils/validatorDepositRedeemLibraries.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

/** Storage slot of `_nativeLock` on the proxy (verified via state-override on CoNET mainnet). */
const NATIVE_LOCK_STORAGE_SLOT = 40n;

function loadProxyAddress(): string {
  const env = process.env.VALIDATOR_DEPOSIT_REDEEM?.trim();
  if (env && ethers.isAddress(env)) return ethers.getAddress(env);
  const addrPath = path.join(root, "deployments", "conet-addresses.json");
  if (!fs.existsSync(addrPath)) throw new Error("缺少 deployments/conet-addresses.json");
  const data = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as { ValidatorDepositRedeem?: string };
  const raw = data.ValidatorDepositRedeem?.trim();
  if (!raw || !ethers.isAddress(raw)) throw new Error("conet-addresses.json 缺少 ValidatorDepositRedeem");
  return ethers.getAddress(raw);
}

async function main() {
  const { ethers: ethersHH } = await networkModule.connect();
  const [signer] = await ethersHH.getSigners();
  const proxyAddr = loadProxyAddress();
  const libraryLinks = await deployValidatorDepositRedeemLibraries(ethersHH);

  console.log("=".repeat(60));
  console.log("Upgrade ValidatorDepositRedeem implementation (UUPS)");
  console.log("=".repeat(60));
  console.log("signer:", signer.address);
  console.log("proxy (unchanged):", proxyAddr);

  const proxy = await ethersHH.getContractAt(
    ["function admins(address) view returns (bool)", "function upgradeToAndCall(address,bytes) external payable"],
    proxyAddr,
    signer
  );
  const isAdmin = await proxy.admins(signer.address);
  if (!isAdmin) {
    throw new Error(`Signer ${signer.address} is not contract admin on proxy ${proxyAddr}`);
  }

  const lockBefore = await ethersHH.provider.getStorage(proxyAddr, NATIVE_LOCK_STORAGE_SLOT);
  console.log("_nativeLock slot", NATIVE_LOCK_STORAGE_SLOT.toString(), "before:", BigInt(lockBefore).toString());
  if (BigInt(lockBefore) === 1n) {
    console.log("NOTE: _nativeLock already 1 before upgrade (unlockNativeReentrancy is idempotent).");
  }

  const ImplFactory = await ethersHH.getContractFactory("ValidatorDepositRedeem", {
    libraries: libraryLinks,
  });
  const newImpl = await ImplFactory.deploy();
  await newImpl.waitForDeployment();
  const newImplAddr = await newImpl.getAddress();
  const implTx = newImpl.deploymentTransaction()?.hash ?? "";
  console.log("new implementation:", newImplAddr);
  if (implTx) console.log("  deploy tx:", implTx);

  const fixCalldata = new ethers.Interface(["function addAdmin(address account) external"]).encodeFunctionData(
    "addAdmin",
    [signer.address]
  );
  const upgradeTx = await proxy.upgradeToAndCall(newImplAddr, fixCalldata);
  console.log("upgradeToAndCall(addAdmin self, unlock _nativeLock) tx:", upgradeTx.hash);
  await upgradeTx.wait();
  console.log("upgradeToAndCall OK — proxy address unchanged:", proxyAddr);

  const lockAfter = await ethersHH.provider.getStorage(proxyAddr, NATIVE_LOCK_STORAGE_SLOT);
  const lockVal = BigInt(lockAfter);
  console.log("_nativeLock slot", NATIVE_LOCK_STORAGE_SLOT.toString(), "after:", lockVal.toString());
  if (lockVal !== 1n) {
    throw new Error(`_nativeLock not set to 1 after upgrade (got ${lockVal})`);
  }
  console.log("VERIFIED: _nativeLock == 1 (nonReentrantNative unlocked)");

  const deployPath = path.join(root, "deployments", "conet-ValidatorDepositRedeem.json");
  if (fs.existsSync(deployPath)) {
    const j = JSON.parse(fs.readFileSync(deployPath, "utf-8")) as Record<string, unknown>;
    j.implementation = newImplAddr;
    j.implementationUpgradedAt = new Date().toISOString();
    j.nativeLockFixViaAddAdminAt = new Date().toISOString();
    j.libraryLinks = libraryLinks;
    if (implTx) j.implementationTransactionHash = implTx;
    j.upgradeNativeLockViaAddAdminTx = upgradeTx.hash;
    const contracts = (j.contracts ?? {}) as Record<string, Record<string, unknown>>;
    if (contracts.ValidatorDepositRedeem) {
      contracts.ValidatorDepositRedeem.implementation = newImplAddr;
    }
    for (const [name, addr] of Object.entries(libraryLinks)) {
      contracts[name] = { address: addr };
    }
    j.contracts = contracts;
    fs.writeFileSync(deployPath, JSON.stringify(j, null, 2) + "\n", "utf-8");
    console.log("updated", deployPath);
  }

  const addrPath = path.join(root, "deployments", "conet-addresses.json");
  if (fs.existsSync(addrPath)) {
    const merged = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, unknown>;
    merged.ValidatorDepositRedeemImplementation = newImplAddr;
    for (const [name, addr] of Object.entries(libraryLinks)) {
      merged[name] = addr;
    }
    fs.writeFileSync(addrPath, JSON.stringify(merged, null, 2) + "\n", "utf-8");
  }

  console.log("\n--- Next: Blockscout verify (same task) ---");
  console.log("CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyValidatorDepositRedeemStackConet.ts");
  console.log("\n--- Next: ops runbook ---");
  console.log("See scripts/RUNBOOK-ValidatorDepositRedeem-guardian-recycle.md");
  console.log("  node scripts/releaseMiningPoolGuardianDePIN207.mjs");
  console.log("  node scripts/remediateGuardian477To341.mjs");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
