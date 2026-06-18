/**
 * Deposit native gas token into EntryPoint for BeamioFactoryPaymasterV07.
 *
 * Usage:
 *   DEPOSIT_ETH=0.1 npx hardhat run scripts/depositBeamioAAFactoryEntryPoint.ts --network conet
 */
import { network as networkModule } from "hardhat";
import { getAddress } from "ethers";
import { BEAMIO_AA_FACTORY_PREDICTED } from "./aaDeployConstants.js";

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("No configured signer");

  const factoryAddress = getAddress(process.env.BEAMIO_AA_FACTORY || BEAMIO_AA_FACTORY_PREDICTED);
  const amount = ethers.parseEther(process.env.DEPOSIT_ETH || "0.1");
  const abi = [
    "function deposit() external payable",
    "function ENTRY_POINT() external view returns (address)",
    "function isPayMaster(address) external view returns (bool)",
  ];
  const factory = new ethers.Contract(factoryAddress, abi, signer);
  const signerAddress = getAddress(await signer.getAddress());
  const isPayMaster = await factory.isPayMaster(signerAddress);
  if (!isPayMaster) throw new Error(`${signerAddress} is not factory paymaster`);
  console.log("factory:", factoryAddress);
  console.log("entryPoint:", await factory.ENTRY_POINT());
  console.log("signer:", signerAddress);
  console.log("deposit:", ethers.formatEther(amount));
  const tx = await factory.deposit({ value: amount });
  console.log("tx:", tx.hash);
  await tx.wait();
  console.log("done");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
