#!/usr/bin/env node
/**
 * 排查「链上周期 transfer 金额」与「Indexer / Transactions Charge 合计」不一致：
 * - getGlobalStatsFull(PERIOD_WEEK) 聚合 Governance `adminList` 中 **每一位** admin 的 POINTS 转账额；
 * - getAdminStatsFull(admin, PERIOD_WEEK) 仅聚合该 admin **子树**（自己 + 下属）；
 * - Indexer Charge 行金额来自 finalRequestAmountUSDC6 / Fiat6，与链上 points 记账可能因 **口径 / 四舍五入 / 其它 admin** 产生差。
 *
 * Usage:
 *   node scripts/compareCardWeekPointTransfers.mjs <cardAddress> [merchantTopAdminEoa]
 *   省略第二参数时只打 global + 每位 admin 分项，不调用 getAdminStatsFull(subtree)。
 *
 * Env: BASE_RPC_URL (default https://base-rpc.conet.network)
 */
import { ethers } from 'ethers';

const PERIOD_WEEK = 2;
const RPC = process.env.BASE_RPC_URL || 'https://base-rpc.conet.network';

const CARD = process.argv[2];
const MERCHANT = process.argv[3]; // optional

const ABI = [
  'function getGlobalStatsFull(uint8 periodType, uint256 anchorTs, uint256 cumulativeStartTs) view returns (uint256 cumulativeMint, uint256 cumulativeBurn, uint256 cumulativeTransfer, uint256 cumulativeTransferAmount, uint256 cumulativeRedeemMint, uint256 cumulativeUSDCMint, uint256 cumulativeIssued, uint256 cumulativeUpgraded, uint256 periodMint, uint256 periodBurn, uint256 periodTransfer, uint256 periodTransferAmount, uint256 periodRedeemMint, uint256 periodUSDCMint, uint256 periodIssued, uint256 periodUpgraded, uint256 adminCount, uint256 cumulativeAdminToAdminTransfer, uint256 cumulativeAdminToAdminTransferAmount, uint256 periodAdminToAdminTransfer, uint256 periodAdminToAdminTransferAmount, uint256 lifetimeAdminToAdminTransferCount, uint256 lifetimeAdminToAdminTransferAmount)',
  'function getAdminStatsFull(address admin, uint8 periodType, uint256 anchorTs, uint256 cumulativeStartTs) view returns (uint256 cumulativeMint, uint256 cumulativeBurn, uint256 cumulativeTransfer, uint256 cumulativeTransferAmount, uint256 cumulativeRedeemMint, uint256 cumulativeUSDCMint, uint256 cumulativeIssued, uint256 cumulativeUpgraded, uint256 periodMint, uint256 periodBurn, uint256 periodTransfer, uint256 periodTransferAmount, uint256 periodRedeemMint, uint256 periodUSDCMint, uint256 periodIssued, uint256 periodUpgraded, uint256 mintCounterFromClear, uint256 burnCounterFromClear, uint256 transferCounterFromClear, uint256 transferAmountFromClear, uint256 redeemMintCounterFromClear, uint256 usdcMintCounterFromClear, address[] subordinates)',
  'function getAdminListWithMetadata() view returns (address[] admins, string[] metadatas, address[] parents)',
  'function owner() view returns (address)',
];

const e6 = (v) => Number(v) / 1_000_000;

async function main() {
  if (!CARD || !ethers.isAddress(CARD)) {
    console.error('Usage: node scripts/compareCardWeekPointTransfers.mjs <cardAddress> [merchantTopAdminEoa]');
    process.exit(1);
  }
  const merchantNorm =
    MERCHANT && ethers.isAddress(MERCHANT) ? ethers.getAddress(MERCHANT) : null;
  const provider = new ethers.JsonRpcProvider(RPC);
  const card = new ethers.Contract(CARD, ABI, provider);

  const owner = await card.owner();
  const g = await card.getGlobalStatsFull(PERIOD_WEEK, 0, 0);
  const [admins, , parents] = await card.getAdminListWithMetadata();

  console.log('RPC:', RPC);
  console.log('Card:', ethers.getAddress(CARD));
  console.log('Card owner:', owner);
  if (merchantNorm) console.log('Query admin subtree root:', merchantNorm);
  console.log('');
  console.log('=== PERIOD_WEEK (on-chain: UTC week, Mon 00:00 — see AdminStatsPeriodLib._periodStart) ===');
  console.log('getGlobalStatsFull (ALL adminList):');
  console.log('  periodTransfer (count):', g.periodTransfer.toString());
  console.log('  periodTransferAmount (e6):', g.periodTransferAmount.toString(), '→ display', e6(g.periodTransferAmount));
  console.log('  adminCount (returned):', g.adminCount.toString());
  console.log('');
  if (merchantNorm) {
    const a = await card.getAdminStatsFull(merchantNorm, PERIOD_WEEK, 0, 0);
    console.log('getAdminStatsFull (subtree of merchant):');
    console.log('  periodTransfer:', a.periodTransfer.toString());
    console.log('  periodTransferAmount (e6):', a.periodTransferAmount.toString(), '→ display', e6(a.periodTransferAmount));
    console.log('  subordinates[] len:', a.subordinates.length);
    console.log('');
    const gAmt = g.periodTransferAmount;
    const aAmt = a.periodTransferAmount;
    if (gAmt !== aAmt) {
      console.log(
        'Δ global − subtree (e6):',
        (gAmt - aAmt).toString(),
        '→',
        e6(gAmt - aAmt),
        '(positive means other admins / owner row not in your subtree)'
      );
    } else {
      console.log('Global week amount equals subtree amount for this admin.');
    }
    console.log('');
  }
  console.log('=== Per-admin PERIOD_WEEK periodTransferAmount (same card) ===');
  for (let i = 0; i < admins.length; i++) {
    const addr = admins[i];
    const par = parents[i] ?? ethers.ZeroAddress;
    try {
      const s = await card.getAdminStatsFull(addr, PERIOD_WEEK, 0, 0);
      const amt = s.periodTransferAmount;
      if (amt === 0n && s.periodTransfer === 0n) continue;
      console.log(
        `  [${i}]`,
        addr,
        'parent:',
        par === ethers.ZeroAddress ? '0' : par,
        'weekTransferAmt:',
        e6(amt),
        'count:',
        s.periodTransfer.toString()
      );
    } catch (e) {
      console.log('  [', i, ']', addr, 'Error:', e.shortMessage || e.message);
    }
  }
  console.log('');
  console.log('Note: Indexer Charge `total` prefers USDC6 then Fiat6 (biz mapIndexerFetchedRowsToDisplay); UI C$ may be USDC-stablecoin face value, not FX CAD.');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
