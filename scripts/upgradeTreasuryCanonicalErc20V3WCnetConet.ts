/**
 * Upgrade CoNET wCNET (TreasuryCanonicalERC20V3 proxy) and enable native wrap.
 *
 * Usage:
 *   npx hardhat run scripts/upgradeTreasuryCanonicalErc20V3WCnetConet.ts --network conet
 */
import { network as networkModule } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { loadSignerPk } from "./utils/loadSignerPk.js";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const IMPLEMENTATION_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const WCNET_PROXY = "0x2DC57d67C9764DeE5788421029Abaf81B992FAaF";

async function main() {
  const { ethers } = await networkModule.connect();
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);
  if (chainId !== 224422) {
    throw new Error(`Expected CoNET 224422, got ${chainId}`);
  }

  const signers = await ethers.getSigners();
  const signer = signers[0] ?? new ethers.Wallet(loadSignerPk(), ethers.provider);

  const proxy = new ethers.Contract(
    WCNET_PROXY,
    [
      "function hasRole(bytes32,address) view returns (bool)",
      "function DEFAULT_ADMIN_ROLE() view returns (bytes32)",
      "function upgradeToAndCall(address newImplementation, bytes data) payable",
      "function setNativeWrapEnabled(bool enabled)",
      "function nativeWrapEnabled() view returns (bool)",
      "function symbol() view returns (string)",
    ],
    signer,
  );

  const adminRole = await proxy.DEFAULT_ADMIN_ROLE();
  const isAdmin = await proxy.hasRole(adminRole, signer.address);
  if (!isAdmin) {
    throw new Error(`Signer ${signer.address} lacks DEFAULT_ADMIN_ROLE on wCNET`);
  }

  const factory = await ethers.getContractFactory("TreasuryCanonicalERC20V3", signer);
  const implementation = await factory.deploy();
  await implementation.waitForDeployment();
  const implementationAddress = await implementation.getAddress();
  const deploymentTx = implementation.deploymentTransaction();
  if (!deploymentTx) throw new Error("implementation deployment tx missing");
  await deploymentTx.wait();

  const upgradeTx = await proxy.upgradeToAndCall(implementationAddress, "0x");
  const upgradeReceipt = await upgradeTx.wait();
  if (!upgradeReceipt) throw new Error("upgrade receipt missing");

  const rawSlot = await ethers.provider.getStorage(WCNET_PROXY, IMPLEMENTATION_SLOT);
  const actualImplementation = ethers.getAddress(`0x${rawSlot.slice(-40)}`);
  if (actualImplementation.toLowerCase() !== implementationAddress.toLowerCase()) {
    throw new Error(`Implementation slot mismatch: ${actualImplementation} != ${implementationAddress}`);
  }

  let enableTxHash: string | null = null;
  if (!(await proxy.nativeWrapEnabled())) {
    const enableTx = await proxy.setNativeWrapEnabled(true);
    await enableTx.wait();
    enableTxHash = enableTx.hash;
  }

  const assetsPath = path.join(ROOT, "deployments", "conet-treasury-v3-assets.json");
  const assets = JSON.parse(fs.readFileSync(assetsPath, "utf8"));
  const wcnet = assets.assets.wCNET;
  const upgrades = Array.isArray(wcnet.upgrades) ? wcnet.upgrades : [];
  upgrades.push({
    implementation: implementationAddress,
    implementationDeploymentTx: deploymentTx.hash,
    upgradeTx: upgradeTx.hash,
    upgradeBlock: upgradeReceipt.blockNumber,
    nativeWrapEnabledTx: enableTxHash,
    nativeWrapEnabled: true,
    note: "CNET↔wCNET deposit/withdraw + EIP-712 withdrawWithSignature",
    upgradedAt: new Date().toISOString(),
  });
  wcnet.implementation = implementationAddress;
  wcnet.implementationTx = deploymentTx.hash;
  wcnet.upgrades = upgrades;
  wcnet.nativeWrapEnabled = true;
  fs.writeFileSync(assetsPath, `${JSON.stringify(assets, null, 2)}\n`);

  console.log(JSON.stringify({
    chainId,
    symbol: await proxy.symbol(),
    proxy: WCNET_PROXY,
    implementation: implementationAddress,
    implementationDeploymentTx: deploymentTx.hash,
    upgradeTx: upgradeTx.hash,
    upgradeBlock: upgradeReceipt.blockNumber,
    nativeWrapEnabled: await proxy.nativeWrapEnabled(),
    enableTxHash,
    nextVerify: [
      "npm run clean && npm run compile",
      "node scripts/exportStandardJsonFromBuildInfo.mjs TreasuryCanonicalERC20V3 --full",
      "node scripts/exportTreasuryV3VerifyFormJson.mjs",
      "verify new impl on https://mainnet.conet.network (v2 standard-input)",
    ],
  }, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
