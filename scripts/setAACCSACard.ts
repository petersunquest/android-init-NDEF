/**
 * 将 AA Factory 的 beamioUserCard 指向新的 CCSA 卡
 */
import { network as networkModule } from "hardhat";

const AA_FACTORY = "0x4b31D6a05Cdc817CAc1B06369555b37a5b182122";
const NEW_CCSA = "0x57052780925448Ce1dB7aC409cCcCf13Bcc4eb71"; // BASE_CCSA_CARD_ADDRESS

async function main() {
  const { ethers } = await networkModule.connect();
  const aaFactory = await ethers.getContractAt("BeamioFactoryPaymasterV07", AA_FACTORY);
  const current = await aaFactory.beamioUserCard();
  if (current.toLowerCase() === NEW_CCSA.toLowerCase()) {
    console.log("✅ 已指向该 CCSA 卡");
    return;
  }
  const tx = await aaFactory.setUserCard(NEW_CCSA);
  await tx.wait();
  console.log("✅ setUserCard 已调用, tx:", tx.hash);
}

main().catch(console.error);
