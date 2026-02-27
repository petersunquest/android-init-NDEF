/**
 * 检查 Card Factory 的 aaFactory 是否指向新 AA Factory
 */
import { network as networkModule } from "hardhat";

const CARD_FACTORY = "0x19C000c00e6A2b254b39d16797930431E310BEdd";
const AA_FACTORY = "0xD86403DD1755F7add19540489Ea10cdE876Cc1CE";

async function main() {
  const { ethers } = await networkModule.connect();
  const cardFactory = await ethers.getContractAt("BeamioUserCardFactoryPaymasterV07", CARD_FACTORY);
  const aa = await cardFactory.aaFactory();
  console.log("Card Factory aaFactory():", aa);
  console.log("预期 AA Factory:", AA_FACTORY);
  console.log("匹配:", aa.toLowerCase() === AA_FACTORY.toLowerCase() ? "✅" : "❌");
}

main().catch(console.error);
