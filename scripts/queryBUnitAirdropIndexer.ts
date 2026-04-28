import { network as networkModule } from "hardhat";
const BUNIT_AIRDROP = "0xFd60936707cb4583c08D8AacBA19E4bfaEE446B8";
async function main() {
  const { ethers } = await networkModule.connect();
  const airdrop = await ethers.getContractAt("BUnitAirdrop", BUNIT_AIRDROP);
  const idx = await airdrop.beamioIndexerDiamond();
  console.log("beamioIndexerDiamond:", idx);
}
main().catch(console.error);
