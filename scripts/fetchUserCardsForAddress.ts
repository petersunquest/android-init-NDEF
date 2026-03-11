/**
 * 拉取指定地址的 BeamioUserCard：
 * 1. 所拥有的卡（持有 points/NFT 的卡）
 * 2. 作为发行方 owner 的卡（cardsOfOwner）
 *
 * 运行：npx hardhat run scripts/fetchUserCardsForAddress.ts --network base
 * 或：TARGET_ADDRESS=0x... npx hardhat run scripts/fetchUserCardsForAddress.ts --network base
 */
import { network as networkModule } from "hardhat";
import { BASE_MAINNET_FACTORIES } from "../config/base-addresses.js";

const BASE_CARD_FACTORY = BASE_MAINNET_FACTORIES.CARD_FACTORY;
const BEAMIO_API = "https://beamio.app";

const TARGET_ADDRESS = process.env.TARGET_ADDRESS ?? "0x513087820Af94A7f4d21bC5B68090f3080022E0e";

async function main() {
  const { ethers } = await networkModule.connect();
  const provider = ethers.provider;

  const addr = ethers.getAddress(TARGET_ADDRESS);

  const factoryAbi = [
    "function cardsOfOwner(address owner) view returns (address[])",
  ];
  const factory = new ethers.Contract(BASE_CARD_FACTORY, factoryAbi, provider);

  const ownershipAbi = [
    "function getOwnershipByEOA(address userEOA) view returns (uint256 pt, (uint256 tokenId, uint256 attribute, uint256 tierIndexOrMax, uint256 expiry, bool isExpired)[] nfts)",
  ];

  console.log("========== BeamioUserCard 查询 ==========\n");
  console.log("目标地址:", addr);
  console.log("Factory:", BASE_CARD_FACTORY);
  console.log();

  // 1. 发行方 owner 的卡（cardsOfOwner）
  const issuerCards = await factory.cardsOfOwner(addr);
  console.log("【1】作为发行方 owner 的 BeamioUserCard 数量:", issuerCards.length);
  if (issuerCards.length > 0) {
    issuerCards.forEach((c: string, i: number) => {
      console.log(`  ${i + 1}. ${c}`);
    });
  }
  console.log();

  // 2. 所拥有的卡（持有 points/NFT）
  const res = await fetch(`${BEAMIO_API}/api/latestCards?limit=100`);
  if (!res.ok) {
    console.log("【2】所拥有的卡: API latestCards 请求失败", res.status);
  } else {
    const data = await res.json().catch(() => ({}));
    const items = (Array.isArray(data?.items) ? data.items : []) as Array<{ cardAddress?: string }>;
    const held: string[] = [];

    for (const it of items) {
      const rawAddr = String(it?.cardAddress ?? "").trim();
      if (!rawAddr || !ethers.isAddress(rawAddr)) continue;
      const cardAddr = ethers.getAddress(rawAddr);
      try {
        const card = new ethers.Contract(cardAddr, ownershipAbi, provider);
        const [pt, nftsRaw] = (await card.getOwnershipByEOA(addr)) as [bigint, Array<{ tokenId: bigint }>];
        const hasPoints = (pt ?? 0n) > 0n;
        const hasNft = Array.isArray(nftsRaw) && nftsRaw.some((n) => Number(n?.tokenId ?? 0n) > 0);
        if (hasPoints || hasNft) {
          held.push(cardAddr);
        }
      } catch (_) {
        // skip
      }
    }

    console.log("【2】所拥有的 BeamioUserCard（持有 points/NFT）数量:", held.length);
    if (held.length > 0) {
      held.forEach((c, i) => {
        console.log(`  ${i + 1}. ${c}`);
      });
    }
  }

  console.log("\n========== 完成 ==========");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
