import { network as networkModule } from "hardhat";
const BUNIT_AIRDROP = "0xbE1CF54f76BcAb40DC49cDcD7FBA525b9ABDa264";
async function main() {
  const { ethers } = await networkModule.connect();
  const airdrop = await ethers.getContractAt("BUnitAirdrop", BUNIT_AIRDROP);
  const idx = await airdrop.beamioIndexerDiamond();
  console.log("beamioIndexerDiamond:", idx);
}
main().catch(console.error);
