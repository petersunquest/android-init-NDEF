/**
 * Upgrade the existing Treasury V3 UUPS proxy without changing its address.
 *
 * Usage:
 *   npx hardhat run scripts/upgradeTreasuryV3OnChains.ts --network base
 *   npx hardhat run scripts/upgradeTreasuryV3OnChains.ts --network conet
 */
import { network as networkModule } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { loadSignerPk } from "./utils/loadSignerPk.js";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const PROXY = "0xa208982212978550594A7FEEB70a61665d129003";
const IMPLEMENTATION_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

async function main() {
  const { ethers } = await networkModule.connect();
  const signers = await ethers.getSigners();
  const signer = signers[0] ?? new ethers.Wallet(loadSignerPk(), ethers.provider);
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);
  if (chainId !== 8453 && chainId !== 224422) {
    throw new Error(`Treasury V3 only supports Base or CoNET, received ${chainId}`);
  }

  const proxy = new ethers.Contract(
    PROXY,
    [
      "function owner() view returns (address)",
      "function upgradeToAndCall(address newImplementation, bytes data) payable",
    ],
    signer,
  );
  const owner = await proxy.owner();
  if (owner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(`Signer ${signer.address} is not Treasury owner ${owner}`);
  }

  const factory = await ethers.getContractFactory("TreasuryBridgeV3", signer);
  const implementation = await factory.deploy();
  await implementation.waitForDeployment();
  const implementationAddress = await implementation.getAddress();
  const deploymentTx = implementation.deploymentTransaction();
  if (!deploymentTx) throw new Error("Treasury V3 implementation deployment transaction unavailable");
  await deploymentTx.wait();

  const tx = await proxy.upgradeToAndCall(implementationAddress, "0x");
  const receipt = await tx.wait();
  if (!receipt) throw new Error("Treasury V3 upgrade receipt unavailable");

  const rawSlot = await ethers.provider.getStorage(PROXY, IMPLEMENTATION_SLOT);
  const actualImplementation = ethers.getAddress(`0x${rawSlot.slice(-40)}`);
  if (actualImplementation.toLowerCase() !== implementationAddress.toLowerCase()) {
    throw new Error(`Implementation slot mismatch: ${actualImplementation} != ${implementationAddress}`);
  }

  const key = chainId === 8453 ? "base" : "conet";
  const deploymentPath = path.join(ROOT, "deployments", `${key}-treasury-v3.json`);
  const deployment = fs.existsSync(deploymentPath)
    ? JSON.parse(fs.readFileSync(deploymentPath, "utf8"))
    : {};
  const upgrades = Array.isArray(deployment.upgrades) ? deployment.upgrades : [];
  upgrades.push({
    implementation: implementationAddress,
    implementationDeploymentTx: deploymentTx.hash,
    upgradeTx: tx.hash,
    upgradeBlock: receipt.blockNumber,
    upgradedAt: new Date().toISOString(),
  });
  deployment.network = key;
  deployment.chainId = chainId;
  deployment.contracts = {
    ...(deployment.contracts ?? {}),
    TreasuryBridgeV3Proxy: PROXY,
    TreasuryBridgeV3Implementation: implementationAddress,
    ERC1967Proxy: PROXY,
  };
  deployment.upgrades = upgrades;
  fs.writeFileSync(deploymentPath, `${JSON.stringify(deployment, null, 2)}\n`);

  console.log(JSON.stringify({
    network: key,
    chainId,
    proxy: PROXY,
    implementation: implementationAddress,
    implementationDeploymentTx: deploymentTx.hash,
    upgradeTx: tx.hash,
    upgradeBlock: receipt.blockNumber,
  }, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
