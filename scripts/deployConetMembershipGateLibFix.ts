/**
 * Redeploy BeamioUserCardMembershipGateLib on CoNET (224422) after tiers() ABI fix (3 returns, not 4).
 *
 * Old broken lib @ deployments/conet-addresses.json is reused by ensureConetUserCardLibraries;
 * this script always deploys a fresh library and updates conet-addresses.json + prints verify steps.
 *
 * Usage:
 *   npm run clean && npm run compile
 *   npx hardhat run scripts/deployConetMembershipGateLibFix.ts --network conet
 *
 * Then:
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardMembershipGateLib --full
 *   node scripts/exportConetMembershipGateLibVerifyBuildinfo.mjs
 *   CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyConetMembershipGateLibOnScan.ts
 *   node scripts/syncBeamioUserCardToX402sdk.mjs
 *
 * New createCard initCode must link the new library address (x402sdk chainAddresses / beamioUserCardChain).
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

async function main() {
  const { ethers: hhEthers } = await networkModule.connect();
  const [deployer] = await hhEthers.getSigners();
  const net = await hhEthers.provider.getNetwork();
  if (Number(net.chainId) !== 224422) {
    throw new Error(`Expected conet chainId 224422, got ${net.chainId}`);
  }

  const addrPath = path.join(__dirname, "..", "deployments", "conet-addresses.json");
  const addrData = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, string>;
  const prev = addrData.beamioUserCardMembershipGateLib;
  console.log("Deployer:", deployer.address);
  console.log("Previous MembershipGateLib:", prev ?? "(none)");

  const Factory = await hhEthers.getContractFactory("BeamioUserCardMembershipGateLib");
  const lib = await Factory.connect(deployer).deploy();
  await lib.waitForDeployment();
  const newAddr = await lib.getAddress();
  const txHash = lib.deploymentTransaction()?.hash;
  console.log("Deployed BeamioUserCardMembershipGateLib:", newAddr, "tx:", txHash);

  const onchainCode = await hhEthers.provider.getCode(newAddr);
  const artifactPath = path.join(
    __dirname,
    "..",
    "artifacts/src/BeamioUserCard/BeamioUserCardMembershipGateLib.sol/BeamioUserCardMembershipGateLib.json"
  );
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8")) as {
    deployedBytecode: string;
  };
  const localDeployed = artifact.deployedBytecode.toLowerCase();
  const onchainDeployed = onchainCode.toLowerCase();
  if (localDeployed !== onchainDeployed) {
    throw new Error(
      "On-chain library bytecode != local artifact deployedBytecode — run npm run compile before deploy"
    );
  }
  console.log("Bytecode precheck OK (local artifact == eth_getCode)");

  addrData.beamioUserCardMembershipGateLib = newAddr;
  fs.writeFileSync(addrPath, JSON.stringify(addrData, null, 2) + "\n");
  console.log("Updated", addrPath);

  if (prev && ethers.getAddress(prev) !== ethers.getAddress(newAddr)) {
    console.log("\nNOTE: Existing merchant cards still link the OLD library address in initCode.");
    console.log("      Cards like 0x703Ca8… cannot be repaired — merchants must createCard with new initCode.");
  }

  console.log("\nNext steps:");
  console.log("  node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardMembershipGateLib --full");
  console.log("  node scripts/exportConetMembershipGateLibVerifyBuildinfo.mjs");
  console.log("  CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyConetMembershipGateLibOnScan.ts");
  console.log("  node scripts/syncBeamioUserCardToX402sdk.mjs");
  console.log("  Update src/x402sdk/src/chainAddresses.ts CONET_BEAMIO_USER_CARD_MEMBERSHIP_GATE_LIB →", newAddr);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
