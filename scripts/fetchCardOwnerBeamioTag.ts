/**
 * 拉取 BeamioUserCard 的 owner 的 Beamio Tag
 * 用法: CARD=0xf99018DfFdb0c5657C93ca14DB2900CEbe1168A7 npx tsx scripts/fetchCardOwnerBeamioTag.ts
 */
import { ethers } from "ethers";

const BASE_RPC = process.env.BASE_RPC_URL || "https://base-rpc.conet.network";
const CONET_RPC = process.env.CONET_RPC || "https://rpc1.conet.network";
const ACCOUNT_REGISTRY = "0x2dF9c4c51564FfF861965572CE11ebe27d3C1B35";
const CARD_FACTORY = "0x2EB245646de404b2Dce87E01C6282C131778bb05";

const CARD_ADDRESS = process.env.CARD || "0xf99018DfFdb0c5657C93ca14DB2900CEbe1168A7";

async function main() {
  console.log("BeamioUserCard:", CARD_ADDRESS);
  console.log();

  const baseProvider = new ethers.JsonRpcProvider(BASE_RPC);
  const conetProvider = new ethers.JsonRpcProvider(CONET_RPC);

  // 1. Get owner: try Factory.beamioUserCardOwner first, fallback to card.owner()
  let owner = ethers.ZeroAddress;
  try {
    const factoryAbi = ["function beamioUserCardOwner(address card) view returns (address)"];
    const factory = new ethers.Contract(CARD_FACTORY, factoryAbi, baseProvider);
    owner = await factory.beamioUserCardOwner(CARD_ADDRESS);
  } catch (_) {}
  if (owner === ethers.ZeroAddress) {
    try {
      const cardAbi = ["function owner() view returns (address)"];
      const card = new ethers.Contract(CARD_ADDRESS, cardAbi, baseProvider);
      owner = await card.owner();
    } catch (_) {}
  }
  console.log("[1] Owner:", owner);

  if (owner === ethers.ZeroAddress) {
    console.log("    No owner found");
    return;
  }

  // 2. Get Beamio Tag from AccountRegistry (CoNET)
  const registryAbi = ["function getUsernameByAddress(address) view returns (string)"];
  const registry = new ethers.Contract(ACCOUNT_REGISTRY, registryAbi, conetProvider);
  try {
    const username = await registry.getUsernameByAddress(owner);
    console.log("[2] Beamio Tag:", username ? `@${username}` : "(not registered on CoNET)");
  } catch (e: any) {
    console.log("[2] Beamio Tag: ERROR -", e?.message?.slice(0, 120));
  }
}

main().catch(console.error);
