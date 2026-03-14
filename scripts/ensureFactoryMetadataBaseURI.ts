/**
 * 检查并修正链上 Factory 的 metadataBaseURI。
 * 若当前值为 api.beamio.io 或错误，则调用 setMetadataBaseURI 更新为 https://beamio.app/api/metadata/0x
 *
 * 用法:
 *   npx hardhat run scripts/ensureFactoryMetadataBaseURI.ts --network base
 *
 * 需配置 PRIVATE_KEY 为 Factory owner 私钥（~/.master.json settle_contractAdmin[0] 或 .env）
 */
import { network as networkModule } from "hardhat";

const CARD_FACTORY = "0xE091a0A974a40bCee36288193376294a19a293aE";
const CORRECT_URI = "https://beamio.app/api/metadata/0x";

async function main() {
  const { ethers } = await networkModule.connect();
  const factory = await ethers.getContractAt(
    "BeamioUserCardFactoryPaymasterV07",
    CARD_FACTORY
  );

  const current = await factory.metadataBaseURI();
  console.log("Current metadataBaseURI:", current);

  if (current === CORRECT_URI) {
    console.log("✅ Already correct, no change needed.");
    return;
  }

  if (current.includes("api.beamio.io") || !current.includes("beamio.app")) {
    console.log("⚠️  Wrong URI detected. Updating to:", CORRECT_URI);
    const tx = await factory.setMetadataBaseURI(CORRECT_URI);
    await tx.wait();
    console.log("✅ Updated. Tx:", tx.hash);
  } else {
    console.log("Current URI differs from expected but may be intentional. No automatic update.");
    console.log("To force update manually: factory.setMetadataBaseURI('" + CORRECT_URI + "')");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
