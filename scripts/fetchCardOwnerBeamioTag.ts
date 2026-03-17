/**
 * 拉取 BeamioUserCard 的 owner 的 Beamio Tag
 * 用法: CARD=0xf99018DfFdb0c5657C93ca14DB2900CEbe1168A7 npx tsx scripts/fetchCardOwnerBeamioTag.ts
 */
import { ethers } from "ethers";

const BASE_RPC = process.env.BASE_RPC_URL || "https://1rpc.io/base";
const CONET_RPC = process.env.CONET_RPC || "https://mainnet-rpc.conet.network";
const ACCOUNT_REGISTRY = "0x3E15607BCf98B01e6C7dF834a2CEc7B8B6aFb1BC";
const CARD_FACTORY = "0xDdD5c17E549a4e66ca636a3c528ae8FAebb8692b";

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
