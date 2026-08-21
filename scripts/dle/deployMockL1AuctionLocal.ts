/**
 * Deploy local mock-L1 auction stack and print env for Archive RPC custody.
 * Usage: npx hardhat run scripts/dle/deployMockL1AuctionLocal.ts --network hardhat
 * Or against Anvil: HARDHAT_NETWORK=localhost …
 * Never targets CoNET mainnet 224422.
 */
import { ethers } from 'hardhat'
import { deployAuctionFixture } from '../../test/dle/fixtures.js'

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
  const rpc = (ethers.provider as { connection?: { url?: string } }).connection?.url
    ?? process.env.MOCK_L1_RPC_URL
    ?? 'http://127.0.0.1:8545'

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
        },
        next: [
          'export MOCK_L1_RPC_URL and MOCK_L1_SETTLEMENT before starting Archive lab-cli',
          'In CoNET-DLE: npm run mock-auction-demo (hook or eth_call custody)',
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
