/**
 * Upgrade the existing ReferralRegistryVaultV1 proxy in place.
 *
 * The implementation deployment and proxy upgrade share the deployer's
 * serialized signer lane so no nonce can be reused by another write.
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";
import * as txQueue from "../src/x402sdk/dist/onchainTxSerialQueue.js";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const deploymentPath = path.join(root, "deployments/conet-ReferralRegistryVaultV1-stack.json");
const ERC1967_IMPLEMENTATION_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

async function main() {
  const { ethers: hh } = await networkModule.connect();
  const [signer] = await hh.getSigners();
  if (!signer) throw new Error("No CoNET deployer signer");
  const network = await hh.provider.getNetwork();
  if (network.chainId !== 224422n) {
    throw new Error(`Expected CoNET 224422, got ${network.chainId}`);
  }

  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8")) as {
    contracts: {
      ReferralRegistryVaultV1: {
        proxy: string;
        implementation: string;
      };
    };
  };
  const proxyAddress = ethers.getAddress(deployment.contracts.ReferralRegistryVaultV1.proxy);
  const lane = txQueue.onchainTxLaneForSigner(signer.address);

  const result = await txQueue.enqueueOnchainTxWork(
    lane,
    "referral-registry:upgrade-implementation",
    async () => {
      const libFactory = await hh.getContractFactory("ReferralRegistryPackageClaimLib");
      const lib = await libFactory.deploy();
      await lib.waitForDeployment();
      const libraryAddress = await lib.getAddress();

      const factory = await hh.getContractFactory("ReferralRegistryVaultV1", {
        libraries: {
          "project/src/mainnet/ReferralRegistryPackageClaimLib.sol:ReferralRegistryPackageClaimLib":
            libraryAddress,
        },
      });
      const implementation = await factory.deploy();
      await implementation.waitForDeployment();
      const implementationAddress = await implementation.getAddress();

      const proxy = new ethers.Contract(
        proxyAddress,
        [
          "function owner() view returns (address)",
          "function upgradeToAndCall(address newImplementation, bytes data)",
        ],
        signer,
      );
      const owner = ethers.getAddress(await proxy.owner());
      if (owner !== ethers.getAddress(signer.address)) {
        throw new Error(`Signer is not ReferralRegistry owner: ${signer.address} != ${owner}`);
      }

      const tx = await proxy.upgradeToAndCall(implementationAddress, "0x");
      const receipt = await tx.wait();
      const slotValue = await hh.provider.getStorage(proxyAddress, ERC1967_IMPLEMENTATION_SLOT);
      const activeImplementation = ethers.getAddress(`0x${slotValue.slice(-40)}`);
      if (activeImplementation !== ethers.getAddress(implementationAddress)) {
        throw new Error(`Proxy implementation mismatch: ${activeImplementation}`);
      }
      return {
        libraryAddress,
        implementationAddress,
        upgradeTxHash: tx.hash,
        blockNumber: receipt?.blockNumber ?? 0,
      };
    },
    "[upgradeReferralRegistryVaultV1]",
  );

  deployment.contracts.ReferralRegistryVaultV1.upgradedImplementation = result.implementationAddress;
  deployment.contracts.ReferralRegistryVaultV1.upgradeTransactionHash = result.upgradeTxHash;
  deployment.contracts.ReferralRegistryVaultV1.upgradeBlock = result.blockNumber;
  deployment.contracts.ReferralRegistryVaultV1.upgradeTimestamp = new Date().toISOString();
  (deployment.contracts.ReferralRegistryVaultV1 as any).packageClaimLib = result.libraryAddress;
  fs.writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2) + "\n");

  console.log(JSON.stringify({
    proxy: proxyAddress,
    library: result.libraryAddress,
    implementation: result.implementationAddress,
    upgradeTxHash: result.upgradeTxHash,
    blockNumber: result.blockNumber,
  }, null, 2));
  console.log(
    "Next: npm run clean && npm run compile && npx tsx scripts/verifyReferralRegistryVaultV1StackConet.ts",
  );
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
