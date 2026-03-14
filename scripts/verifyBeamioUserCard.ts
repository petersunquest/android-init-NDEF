/**
 * 验证 BeamioUserCard 合约（通过 Hardhat verify）
 *
 * 用法:
 *   CARD=0x82ceE96dB45933fE4b71D36fa8904508f929027C \
 *   URI="https://beamio.app/api/metadata/0x" \
 *   CURRENCY=4 \
 *   PRICE=1000000 \
 *   OWNER=0x513087820Af94A7f4d21bC5B68090f3080022E0e \
 *   GATEWAY=0x2F45f38f2B6EF97b606ec2557E237529e8db9281 \
 *   npx hardhat run scripts/verifyBeamioUserCard.ts --network base
 *
 * URI 必须与 Factory metadataBaseURI 一致：https://beamio.app/api/metadata/0x（api.beamio.io 域名已废弃）
 */
import { run } from "hardhat";

const CARD = process.env.CARD || "";
const URI = process.env.URI || "https://beamio.app/api/metadata/0x";
const CURRENCY = parseInt(process.env.CURRENCY || "4", 10);
const PRICE = process.env.PRICE || "1000000";
const OWNER = process.env.OWNER || "";
const GATEWAY = process.env.GATEWAY || "0x2F45f38f2B6EF97b606ec2557E237529e8db9281";

async function main() {
  if (!CARD || CARD.length !== 42 || !CARD.startsWith("0x")) {
    console.error("请设置 CARD 环境变量（合约地址）");
    process.exit(1);
  }
  if (!OWNER || OWNER.length !== 42) {
    console.error("请设置 OWNER 环境变量（卡主地址）");
    process.exit(1);
  }

  const constructorArgs = [URI, CURRENCY, PRICE, OWNER, GATEWAY];
  console.log("验证 BeamioUserCard:", CARD);
  console.log("Constructor args:", constructorArgs);

  try {
    await run("verify:verify", {
      address: CARD,
      constructorArguments: constructorArgs,
    });
    console.log("✅ 验证成功");
  } catch (e: any) {
    if (e.message?.includes("Already Verified")) {
      console.log("✅ 合约已验证");
    } else {
      throw e;
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
