/**
 * Deploy local mock-L1 auction stack and print env for Archive / E2E.
 * Usage:
 *   npx hardhat run scripts/dle/deployMockL1AuctionLocal.ts --network hardhat
 *   npx hardhat run scripts/dle/deployMockL1AuctionLocal.ts --network localhost
 * Never targets CoNET mainnet 224422.
 *
 * Hardhat mnemonic accounts (LOCAL ONLY — never production):
 *   #0 authority  0xac0974…ff80
 *   #1 seller     0x59c699…690d
 *   #2 buyer      0x5de411…365a
 */
// Hardhat 3: ethers comes from network.connect(), not `import { ethers } from 'hardhat'`.
import { deployAuctionFixture, ethers } from '../../test/dle/fixtures.js'

/** Well-known Hardhat/Anvil account keys — local lab only. */
export const MOCK_L1_LOCAL_KEYS = {
  authority: '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80',
  seller: '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d',
  buyer: '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a',
} as const

async function main() {
  const net = await ethers.provider.getNetwork()
  if (Number(net.chainId) === 224422) {
    throw new Error('refusing CoNET mainnet (224422) — mock-L1 auction deploy is local-only')
  }

  const fx = await deployAuctionFixture()
  const settlement = await fx.settlement.getAddress()
  const subjectNft = await fx.subjectNft.getAddress()
  const quote = await fx.quote.getAddress()
  const authority = await fx.authority.getAddress()
  const seller = await fx.seller.getAddress()
  const buyer = await fx.buyer.getAddress()
  const scanner = await fx.scanner.getAddress()
  const rpc =
    process.env.MOCK_L1_RPC_URL?.trim() ||
    (Number(net.chainId) === 31337 ? 'http://127.0.0.1:8545' : 'http://127.0.0.1:8545')

  // Mint subject NFT to seller and approve settlement for lab custody path.
  const subjectTokenId = await fx.subjectNft.mint.staticCall(seller)
  await (await fx.subjectNft.mint(seller)).wait()
  await (await fx.subjectNft.connect(fx.seller).approve(settlement, subjectTokenId)).wait()
  const mintAmount = 10_000_000n
  await (await fx.quote.mint(buyer, mintAmount)).wait()
  await (await fx.quote.connect(fx.buyer).approve(settlement, mintAmount)).wait()

  const bound = await fx.mintAndBindClass(3) // trade class

  console.log(
    JSON.stringify(
      {
        mockL1Only: true,
        notProductionDepin: true,
        chainId: Number(net.chainId),
        rpcUrlHint: rpc,
        env: {
          MOCK_L1_RPC_URL: rpc,
          MOCK_L1_SETTLEMENT: settlement,
          MOCK_L1_SUBJECT_NFT: subjectNft,
          MOCK_L1_QUOTE: quote,
          MOCK_L1_SUBJECT_ID: subjectTokenId.toString(),
          MOCK_L1_CHAIN_NFT_ID: bound.tokenId.toString(),
          MOCK_L1_AUTHORITY_PRIVATE_KEY: MOCK_L1_LOCAL_KEYS.authority,
          MOCK_L1_SELLER_PRIVATE_KEY: MOCK_L1_LOCAL_KEYS.seller,
          MOCK_L1_BUYER_PRIVATE_KEY: MOCK_L1_LOCAL_KEYS.buyer,
          MOCK_L1_SETTLE_ONCHAIN: '1',
          MOCK_L1_PRICE: '1000000',
        },
        addresses: {
          settlement,
          subjectNft,
          quote,
          certificateAuthority: authority,
          seller,
          buyer,
          scanner,
        },
        lab: {
          subjectTokenId: subjectTokenId.toString(),
          quoteAllowance: mintAmount.toString(),
          tradeChainNft: bound.tokenId.toString(),
          note: 'Private keys above are Hardhat mnemonic LOCAL ONLY',
        },
        next: [
          'export the env block (or: npm run dle:mock-auction-e2e)',
          'CoNET-DLE: npm run mock-auction-e2e — list → match → on-chain settle',
          'demo without chain: npm run mock-auction-demo (fake txHash unless MOCK_L1_SETTLE_ONCHAIN)',
          'Explorer /mock-auction — session-key signed submit (keys never persisted)',
        ],
      },
      null,
      2,
    ),
  )
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
