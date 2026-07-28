/**
 * 单独调用 AA Factory 的 setUserCard
 */
import { network as networkModule } from "hardhat";

const AA_FACTORY = "0x4b31D6a05Cdc817CAc1B06369555b37a5b182122";
const USER_CARD = "0x39Abe0C118db532698561509e3F2579C4830af85";

async function main() {
  const { ethers } = await networkModule.connect();
  const aaFactory = await ethers.getContractAt("BeamioFactoryPaymasterV07", AA_FACTORY);
  const current = await aaFactory.beamioUserCard();
  if (current.toLowerCase() === USER_CARD.toLowerCase()) {
    console.log("✅ 已指向该 UserCard");
    return;
  }
  const tx = await aaFactory.setUserCard(USER_CARD);
  await tx.wait();
  console.log("✅ setUserCard 已调用, tx:", tx.hash);
}

main().catch(console.error);
