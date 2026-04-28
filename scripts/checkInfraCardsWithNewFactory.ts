/**
 * 使用新 Factory 地址在 Base 上查询：CCSA 卡、基础设施卡是否能在该 Factory 上找到（已登记）。
 * 若 beamioUserCardOwner(card) 返回非零，表示该卡由本 Factory 创建或已 registerExistingCard。
 *
 * 运行：npx hardhat run scripts/checkInfraCardsWithNewFactory.ts --network base
 */
import { network as networkModule } from "hardhat";

const BASE_CARD_FACTORY = "0x2EB245646de404b2Dce87E01C6282C131778bb05";
const BASE_CCSA_CARD_ADDRESS = "0xA1A9f6f942dc0ED9Aa7eF5df7337bd878c2e157b";
const BEAMIO_USER_CARD_ASSET_ADDRESS = "0xEcC5bDFF6716847e45363befD3506B1D539c02D5";

async function main() {
  const { ethers } = await networkModule.connect();
  const provider = ethers.provider;

  const factoryAbi = [
    "function beamioUserCardOwner(address card) view returns (address)",
    "function isBeamioUserCard(address card) view returns (bool)",
    "function cardsOfOwner(address owner) view returns (address[])",
  ];
  const factory = new ethers.Contract(BASE_CARD_FACTORY, factoryAbi, provider);

  const factoryCode = await provider.getCode(BASE_CARD_FACTORY);
  if (!factoryCode || factoryCode === "0x") {
    console.error("Factory 无 code:", BASE_CARD_FACTORY);
    process.exit(1);
  }

  console.log("========== 新 Factory 下基础设施 / CCSA 卡查询（Base）==========\n");
  console.log("Factory:", BASE_CARD_FACTORY);
  console.log();

  const cards = [
    { name: "CCSA 卡 (BASE_CCSA_CARD_ADDRESS)", address: BASE_CCSA_CARD_ADDRESS },
    { name: "基础设施卡 (BEAMIO_USER_CARD_ASSET_ADDRESS)", address: BEAMIO_USER_CARD_ASSET_ADDRESS },
  ] as const;

  for (const { name, address } of cards) {
    const code = await provider.getCode(address);
    const hasCode = code && code !== "0x" && code.length > 2;
    const owner = await factory.beamioUserCardOwner(address);
    const isRegistered = await factory.isBeamioUserCard(address);
    const ownerIsZero = !owner || owner === ethers.ZeroAddress;

    console.log(name);
    console.log("  地址:", address);
    console.log("  链上有 code:", hasCode ? "✅" : "❌");
    console.log("  Factory.beamioUserCardOwner(card):", ownerIsZero ? "0x0 (未在本 Factory 登记)" : owner);
    console.log("  Factory.isBeamioUserCard(card):", isRegistered ? "✅ true" : "❌ false");
    if (!ownerIsZero) {
      const list = await factory.cardsOfOwner(owner);
      console.log("  该 owner 在本 Factory 下的卡数:", list?.length ?? 0);
    }
    console.log();
  }

  console.log("========== 说明 ==========");
  console.log("若 beamioUserCardOwner 为 0x0 或 isBeamioUserCard 为 false，表示该卡不是由本 Factory 创建且未 registerExistingCard。");
  console.log("若需在本 Factory 下使用这些卡，需由 Factory owner 调用 registerExistingCard(cardOwner, card) 登记。");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
