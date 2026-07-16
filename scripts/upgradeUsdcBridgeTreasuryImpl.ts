import { network as networkModule } from "hardhat";
import { getAddress } from "ethers";

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("No upgrade signer");
  const proxyAddress = getAddress(process.env.USDC_BRIDGE_TREASURY || "");
  if (!proxyAddress) throw new Error("USDC_BRIDGE_TREASURY is required");

  const proxyCode = await ethers.provider.getCode(proxyAddress);
  if (proxyCode === "0x" || proxyCode.length <= 2) {
    throw new Error(`USDC Bridge proxy has no code: ${proxyAddress}`);
  }

  const proxy = await ethers.getContractAt(
    ["function owner() view returns (address)", "function upgradeToAndCall(address,bytes) external payable"],
    proxyAddress,
    signer
  );
  const owner = await proxy.owner();
  if (getAddress(owner) !== getAddress(signer.address)) {
    throw new Error(`Signer is not bridge owner: ${signer.address} != ${owner}`);
  }

  const implementation = await ethers.deployContract("UsdcBridgeTreasury");
  await implementation.waitForDeployment();
  const implementationAddress = await implementation.getAddress();
  console.log("new implementation:", implementationAddress);
  const tx = await proxy.upgradeToAndCall(implementationAddress, "0x");
  console.log("upgrade tx:", tx.hash);
  await tx.wait();
  console.log("canonical proxy remains:", proxyAddress);
  console.log("Verify the new implementation with the Explorer Standard JSON workflow.");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

