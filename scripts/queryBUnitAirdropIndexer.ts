import { network as networkModule } from "hardhat";
const BUNIT_AIRDROP = "0xa01DFfD68b355540B840310a9f0C1E7a779C3Ce8";
async function main() {
  const { ethers } = await networkModule.connect();
  const airdrop = await ethers.getContractAt("BUnitAirdrop", BUNIT_AIRDROP);
  const idx = await airdrop.beamioIndexerDiamond();
  console.log("beamioIndexerDiamond:", idx);
}
main().catch(console.error);
