#!/usr/bin/env node
import { ethers } from 'ethers';

const CARD = '0x82b333da5c723DA6e98FEfEcd96cB1cA304C6125';
const USER = '0xEaBF0A98aC208647247eAA25fDD4eB0e67793d61';
const RPC = process.env.BASE_RPC || 'https://base-rpc.conet.network';

const abi = [
  'function balanceOf(address account, uint256 id) view returns (uint256)',
  'function getOwnership(address user) view returns (uint256 pt, (uint256 tokenId, uint256 attribute, uint256 tierIndexOrMax, uint256 expiry, bool isExpired)[] nfts)',
  'function getOwnershipByEOA(address userEOA) view returns (uint256 pt, (uint256 tokenId, uint256 attribute, uint256 tierIndexOrMax, uint256 expiry, bool isExpired)[] nfts)',
];

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const card = new ethers.Contract(CARD, abi, provider);

  console.log('User:', USER);
  console.log('Card:', CARD);
  console.log('');

  const code = await provider.getCode(CARD);
  console.log('Contract deployed:', (code?.length ?? 0) > 2);

  const pointsBal = await card.balanceOf(USER, 0);
  console.log('Points (id=0) balance:', pointsBal.toString(), '=', ethers.formatUnits(pointsBal, 6));

  let hasNft = false;
  for (const id of [100, 101, 102, 103, 104, 105]) {
    try {
      const b = await card.balanceOf(USER, id);
      if (b > 0n) {
        console.log('NFT id', id, 'balance:', b.toString());
        hasNft = true;
      }
    } catch (_) {}
  }

  console.log('');
  console.log('getOwnership(user) - direct address (EOA or AA):');
  try {
    const [pt, nfts] = await card.getOwnership(USER);
    const nftList = Array.isArray(nfts) ? nfts.filter((n) => Number(n?.tokenId ?? 0n) > 0) : [];
    console.log('  Points:', pt?.toString(), '=', ethers.formatUnits(pt ?? 0n, 6));
    console.log('  NFTs:', nftList.length, nftList.map((n) => ({ tokenId: n.tokenId?.toString(), tier: n.tierIndexOrMax?.toString() })));
    hasNft = hasNft || nftList.length > 0;
  } catch (e) {
    console.log('  Error:', e.message?.slice(0, 100));
  }

  console.log('');
  console.log('getOwnershipByEOA(user) - resolves EOA->AA:');
  try {
    const [pt, nfts] = await card.getOwnershipByEOA(USER);
    const nftList = Array.isArray(nfts) ? nfts.filter((n) => Number(n?.tokenId ?? 0n) > 0) : [];
    console.log('  Points:', pt?.toString(), '=', ethers.formatUnits(pt ?? 0n, 6));
    console.log('  NFTs:', nftList.length, nftList.map((n) => ({ tokenId: n.tokenId?.toString(), tier: n.tierIndexOrMax?.toString() })));
    hasNft = hasNft || nftList.length > 0;
  } catch (e) {
    console.log('  Error (user may have no Beamio AA):', e.message?.slice(0, 100));
  }

  const hasPoints = pointsBal > 0n;
  console.log('');
  console.log('=== RESULT ===');
  console.log('User 0xEaBF0A98aC208647247eAA25fDD4eB0e67793d61');
  console.log('owns assets on card 0x82b333da5c723DA6e98FEfEcd96cB1cA304C6125:', hasPoints || hasNft);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
