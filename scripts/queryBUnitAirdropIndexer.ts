import { network as networkModule } from "hardhat";
const BUNIT_AIRDROP = "0xb9cf45AF87b16853c8F48a16b0495F030309e70f";
async function main() {
  const { ethers } = await networkModule.connect();
  const airdrop = await ethers.getContractAt("BUnitAirdrop", BUNIT_AIRDROP);
  const idx = await airdrop.beamioIndexerDiamond();
  console.log("beamioIndexerDiamond:", idx);
}
main().catch(console.error);
