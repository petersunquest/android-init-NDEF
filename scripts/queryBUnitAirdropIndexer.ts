import { network as networkModule } from "hardhat";
const BUNIT_AIRDROP = "0x67d01e0E9c859A89def4098aC7803f04BF0d77af";
async function main() {
  const { ethers } = await networkModule.connect();
  const airdrop = await ethers.getContractAt("BUnitAirdrop", BUNIT_AIRDROP);
  const idx = await airdrop.beamioIndexerDiamond();
  console.log("beamioIndexerDiamond:", idx);
}
main().catch(console.error);
