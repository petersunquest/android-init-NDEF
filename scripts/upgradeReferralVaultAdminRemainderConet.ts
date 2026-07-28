/**
 * Upgrade ReferralRegistryVaultV1 so mint remainder (after L0/L1 rebate) pays L0.parentAdmin EOA.
 *
 * Usage:
 *   npx hardhat run scripts/upgradeReferralVaultAdminRemainderConet.ts --network conet
 */
import { network as networkModule } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { loadSignerPk } from "./utils/loadSignerPk.js";

const VAULT = "0xD6252Cbf266B80231397Ac2a4f25ed2d9b01DEE6";
const IMPLEMENTATION_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");

async function main() {
  const { ethers } = await networkModule.connect();
  const network = await ethers.provider.getNetwork();
  if (Number(network.chainId) !== 224422) {
    throw new Error(`Expected CoNET 224422, got ${network.chainId}`);
  }

  const signers = await ethers.getSigners();
  const signer = signers[0] ?? new ethers.Wallet(loadSignerPk(), ethers.provider);
  console.log("signer", signer.address);

  const vault = new ethers.Contract(
    VAULT,
    [
      "function owner() view returns (address)",
      "function upgradeToAndCall(address newImplementation, bytes data) payable",
    ],
    signer,
  );

  const owner = await vault.owner();
  if (owner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(`Signer ${signer.address} is not vault owner ${owner}`);
  }

  const beforeImpl = ethers.getAddress(
    "0x" + (await ethers.provider.getStorage(VAULT, IMPLEMENTATION_SLOT)).slice(-40),
  );
  console.log("beforeImpl", beforeImpl);

  const PackageLib = await ethers.getContractFactory("ReferralRegistryPackageClaimLib", signer);
  const packageLib = await PackageLib.deploy();
  await packageLib.waitForDeployment();
  const packageLibAddr = await packageLib.getAddress();
  await packageLib.deploymentTransaction()!.wait();

  const SettlementLib = await ethers.getContractFactory("ReferralRegistrySettlementLib", signer);
  const settlementLib = await SettlementLib.deploy();
  await settlementLib.waitForDeployment();
  const settlementLibAddr = await settlementLib.getAddress();
  await settlementLib.deploymentTransaction()!.wait();

  const VaultFactory = await ethers.getContractFactory("ReferralRegistryVaultV1", {
    signer,
    libraries: {
      ReferralRegistryPackageClaimLib: packageLibAddr,
      ReferralRegistrySettlementLib: settlementLibAddr,
    },
  });
  const newImpl = await VaultFactory.deploy();
  await newImpl.waitForDeployment();
  const newImplAddr = await newImpl.getAddress();
  const implDeployTx = newImpl.deploymentTransaction();
  const implReceipt = await implDeployTx!.wait();
  console.log({
    packageLibAddr,
    settlementLibAddr,
    newImplAddr,
    implDeployTx: implDeployTx!.hash,
    deployBlock: implReceipt?.blockNumber,
  });

  const upgradeTx = await vault.upgradeToAndCall(newImplAddr, "0x");
  const upgradeReceipt = await upgradeTx.wait();
  const afterImpl = ethers.getAddress(
    "0x" + (await ethers.provider.getStorage(VAULT, IMPLEMENTATION_SLOT)).slice(-40),
  );
  if (afterImpl.toLowerCase() !== newImplAddr.toLowerCase()) {
    throw new Error(`Upgrade failed: impl=${afterImpl}`);
  }
  console.log("upgraded", upgradeTx.hash, "block", upgradeReceipt?.blockNumber);

  const out = {
    network: "conet",
    chainId: 224422,
    vaultProxy: VAULT,
    previousImpl: beforeImpl,
    implementation: newImplAddr,
    libraryLinks: {
      ReferralRegistryPackageClaimLib: packageLibAddr,
      ReferralRegistrySettlementLib: settlementLibAddr,
    },
    upgradeTx: upgradeTx.hash,
    upgradeBlock: upgradeReceipt?.blockNumber ?? null,
    semantics:
      "onPaidBUnitConsumed: mint USDC → pay L0/L1 rebate (rebateBps, e.g. 30%) → remainder to members[l0].parentAdmin EOA",
    timestamp: new Date().toISOString(),
  };
  const outPath = path.join(ROOT, "deployments/conet-referral-vault-admin-remainder.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n");
  console.log("wrote", outPath);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
