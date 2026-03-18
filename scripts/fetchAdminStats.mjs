#!/usr/bin/env node
/**
 * Fetch admin stats for a BeamioUserCard via getAdminStatsFull.
 * Usage: node scripts/fetchAdminStats.mjs <cardAddress> <adminAddress>
 */
import { ethers } from 'ethers';

const CARD_ADDRESS = process.argv[2] || '0x74f35741ad8bc75d873a8d7d140ae5ffb529ac0f';
const ADMIN_ADDRESS = process.argv[3] || '0xEb5f3F4E60D80227e1dB91D269b4F1dA35892e7b';
const RPC = process.env.BASE_RPC_URL || 'https://1rpc.io/base';

const ABI = [
  'function getAdminStatsFull(address admin, uint8 periodType, uint256 anchorTs, uint256 cumulativeStartTs) view returns (tuple(uint256 cumulativeMint, uint256 cumulativeBurn, uint256 cumulativeTransfer, uint256 cumulativeTransferAmount, uint256 cumulativeRedeemMint, uint256 cumulativeUSDCMint, uint256 cumulativeIssued, uint256 cumulativeUpgraded, uint256 periodMint, uint256 periodBurn, uint256 periodTransfer, uint256 periodTransferAmount, uint256 periodRedeemMint, uint256 periodUSDCMint, uint256 periodIssued, uint256 periodUpgraded, uint256 mintCounterFromClear, uint256 burnCounterFromClear, uint256 transferCounterFromClear, uint256 transferAmountFromClear, uint256 redeemMintCounterFromClear, uint256 usdcMintCounterFromClear, address[] subordinates))',
];

function e6(n) {
  return Number(n) / 1_000_000;
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const card = new ethers.Contract(CARD_ADDRESS, ABI, provider);

  const stats = await card.getAdminStatsFull(ADMIN_ADDRESS, 0, 0, 0);

  console.log('\n=== Admin Stats (BeamioUserCard) ===');
  console.log('Card:', CARD_ADDRESS);
  console.log('Admin:', ADMIN_ADDRESS);
  console.log('(periodType=0, anchorTs=0, cumulativeStartTs=0)\n');

  console.log('--- Cumulative (since cumulativeStartTs) ---');
  console.log('  cumulativeMint:           ', e6(stats.cumulativeMint), 'USDC');
  console.log('  cumulativeBurn:           ', e6(stats.cumulativeBurn), 'USDC');
  console.log('  cumulativeTransfer:       ', stats.cumulativeTransfer.toString(), 'count');
  console.log('  cumulativeTransferAmount:  ', e6(stats.cumulativeTransferAmount), 'USDC');
  console.log('  cumulativeRedeemMint:     ', e6(stats.cumulativeRedeemMint), 'USDC');
  console.log('  cumulativeUSDCMint:       ', e6(stats.cumulativeUSDCMint), 'USDC');
  console.log('  cumulativeIssued:         ', stats.cumulativeIssued.toString());
  console.log('  cumulativeUpgraded:       ', stats.cumulativeUpgraded.toString());

  console.log('\n--- Period ---');
  console.log('  periodMint:                ', e6(stats.periodMint), 'USDC');
  console.log('  periodBurn:                ', e6(stats.periodBurn), 'USDC');
  console.log('  periodTransfer:            ', stats.periodTransfer.toString(), 'count');
  console.log('  periodTransferAmount:      ', e6(stats.periodTransferAmount), 'USDC');
  console.log('  periodRedeemMint:          ', e6(stats.periodRedeemMint), 'USDC');
  console.log('  periodUSDCMint:            ', e6(stats.periodUSDCMint), 'USDC');
  console.log('  periodIssued:              ', stats.periodIssued.toString());
  console.log('  periodUpgraded:            ', stats.periodUpgraded.toString());

  console.log('\n--- From Clear (self + subordinates) ---');
  console.log('  mintCounterFromClear:     ', e6(stats.mintCounterFromClear), 'USDC');
  console.log('  burnCounterFromClear:     ', e6(stats.burnCounterFromClear), 'USDC');
  console.log('  transferCounterFromClear: ', stats.transferCounterFromClear.toString());
  console.log('  transferAmountFromClear:  ', e6(stats.transferAmountFromClear), 'USDC');
  console.log('  redeemMintCounterFromClear:', e6(stats.redeemMintCounterFromClear), 'USDC');
  console.log('  usdcMintCounterFromClear: ', e6(stats.usdcMintCounterFromClear), 'USDC');

  console.log('\n--- Subordinates ---');
  console.log('  count:', stats.subordinates.length);
  stats.subordinates.forEach((a, i) => console.log(`    [${i}] ${a}`));
  console.log('');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
