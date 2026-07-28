/**
 * Upgrade CoNET V3 USDC (TreasuryCanonicalERC20V3) with TREASURY_ROLE mint path.
 *
 * Usage:
 *   npx hardhat run scripts/upgradeTreasuryCanonicalErc20V3UsdcConet.ts --network conet
 */
import { network as networkModule } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { loadSignerPk } from "./utils/loadSignerPk.js";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const IMPLEMENTATION_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const USDC_PROXY = "0x5209865D404aA5646eDe5B91CD4218909eA72eDA";

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
    USDC_PROXY,
    [
      "function hasRole(bytes32,address) view returns (bool)",
      "function DEFAULT_ADMIN_ROLE() view returns (bytes32)",
      "function TREASURY_ROLE() view returns (bytes32)",
      "function upgradeToAndCall(address newImplementation, bytes data) payable",
      "function symbol() view returns (string)",
    ],
    signer,
  );

  const adminRole = await proxy.DEFAULT_ADMIN_ROLE();
  const isAdmin = await proxy.hasRole(adminRole, signer.address);
  if (!isAdmin) {
    throw new Error(`Signer ${signer.address} lacks DEFAULT_ADMIN_ROLE on V3 USDC`);
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

  const rawSlot = await ethers.provider.getStorage(USDC_PROXY, IMPLEMENTATION_SLOT);
  const actualImplementation = ethers.getAddress(`0x${rawSlot.slice(-40)}`);
  if (actualImplementation.toLowerCase() !== implementationAddress.toLowerCase()) {
    throw new Error(`Implementation slot mismatch: ${actualImplementation} != ${implementationAddress}`);
  }

  // Probe TREASURY_ROLE exists on new impl
  const treasuryRole = await proxy.TREASURY_ROLE();

  const assetsPath = path.join(ROOT, "deployments", "conet-treasury-v3-assets.json");
  const assets = JSON.parse(fs.readFileSync(assetsPath, "utf8"));
  const usdc = assets.assets.conetUSDC ?? assets.assets.USDC ?? assets.assets["conet-USDC"];
  if (!usdc) {
    throw new Error("conet-treasury-v3-assets.json missing conetUSDC asset entry");
  }
  const upgrades = Array.isArray(usdc.upgrades) ? usdc.upgrades : [];
  upgrades.push({
    implementation: implementationAddress,
    implementationDeploymentTx: deploymentTx.hash,
    upgradeTx: upgradeTx.hash,
    upgradeBlock: upgradeReceipt.blockNumber,
    note: "TREASURY_ROLE mint for B-Unit fee settlement via BridgeV3",
    upgradedAt: new Date().toISOString(),
  });
  usdc.implementation = implementationAddress;
  usdc.implementationTx = deploymentTx.hash;
  usdc.upgrades = upgrades;
  fs.writeFileSync(assetsPath, `${JSON.stringify(assets, null, 2)}\n`);

  console.log(JSON.stringify({
    chainId,
    symbol: await proxy.symbol(),
    proxy: USDC_PROXY,
    implementation: implementationAddress,
    implementationDeploymentTx: deploymentTx.hash,
    upgradeTx: upgradeTx.hash,
    upgradeBlock: upgradeReceipt.blockNumber,
    treasuryRole,
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
