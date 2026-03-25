#!/usr/bin/env node
/**
 * Fetch admin stats for an account on a BeamioUserCard, or global stats for the card
 * Usage:
 *   node scripts/fetchAdminStats.mjs <cardAddress> <accountAddress>
 *   node scripts/fetchAdminStats.mjs <cardAddress> --global
 */
import { ethers } from 'ethers';

const CARD = process.argv[2] || '0x9cda8477c9f03b8759ac64e21941e578908fd750';
const ACCOUNT = process.argv[3] || '0x8Eb31413EC7Ce13367a39eae203e6659e8F6f32D';
const GLOBAL = process.argv[3] === '--global';
const RPC = process.env.BASE_RPC_URL || 'https://base-rpc.conet.network';

const ABI = [
  'function owner() view returns (address)',
  'function isAdmin(address) view returns (bool)',
  'function getAdminListWithMetadata() view returns (address[] admins, string[] metadatas, address[] parents)',
  'function getAdminAirdropLimit(address admin) view returns (address admin, address parent, uint256 limit, uint256 usedFromClear, uint256 remainingAvailable, bool unlimited)',
  'function getAdminStatsFull(address admin, uint8 periodType, uint256 anchorTs, uint256 cumulativeStartTs) view returns (uint256 cumulativeMint, uint256 cumulativeBurn, uint256 cumulativeTransfer, uint256 cumulativeTransferAmount, uint256 cumulativeRedeemMint, uint256 cumulativeUSDCMint, uint256 cumulativeIssued, uint256 cumulativeUpgraded, uint256 periodMint, uint256 periodBurn, uint256 periodTransfer, uint256 periodTransferAmount, uint256 periodRedeemMint, uint256 periodUSDCMint, uint256 periodIssued, uint256 periodUpgraded, uint256 mintCounterFromClear, uint256 burnCounterFromClear, uint256 transferCounterFromClear, uint256 transferAmountFromClear, uint256 redeemMintCounterFromClear, uint256 usdcMintCounterFromClear, address[] subordinates)',
  'function getGlobalStatsFull(uint8 periodType, uint256 anchorTs, uint256 cumulativeStartTs) view returns (uint256 cumulativeMint, uint256 cumulativeBurn, uint256 cumulativeTransfer, uint256 cumulativeTransferAmount, uint256 cumulativeRedeemMint, uint256 cumulativeUSDCMint, uint256 cumulativeIssued, uint256 cumulativeUpgraded, uint256 periodMint, uint256 periodBurn, uint256 periodTransfer, uint256 periodTransferAmount, uint256 periodRedeemMint, uint256 periodUSDCMint, uint256 periodIssued, uint256 periodUpgraded, uint256 adminCount, uint256 cumulativeAdminToAdminTransfer, uint256 cumulativeAdminToAdminTransferAmount, uint256 periodAdminToAdminTransfer, uint256 periodAdminToAdminTransferAmount, uint256 lifetimeAdminToAdminTransferCount, uint256 lifetimeAdminToAdminTransferAmount)',
];

const e6 = (v) => Number(v) / 1_000_000;

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const card = new ethers.Contract(CARD, ABI, provider);

  const parseStatsFull = (rawHex) => {
    if (!rawHex || typeof rawHex !== 'string') return null;
    const hex = rawHex.replace(/^0x/, '');
    if (hex.length < 32 * 24) return null;
    const u256 = (i) => BigInt('0x' + hex.slice(i * 64, (i + 1) * 64));
    const structOffset = Number(u256(0));
    const base = structOffset / 32;
    return {
      cumulativeMint: u256(base + 0),
      cumulativeBurn: u256(base + 1),
      cumulativeTransfer: u256(base + 2),
      cumulativeTransferAmount: u256(base + 3),
      cumulativeRedeemMint: u256(base + 4),
      cumulativeUSDCMint: u256(base + 5),
      cumulativeIssued: u256(base + 6),
      cumulativeUpgraded: u256(base + 7),
      periodMint: u256(base + 8),
      periodBurn: u256(base + 9),
      periodTransfer: u256(base + 10),
      periodTransferAmount: u256(base + 11),
      periodRedeemMint: u256(base + 12),
      periodUSDCMint: u256(base + 13),
      periodIssued: u256(base + 14),
      periodUpgraded: u256(base + 15),
      mintCounterFromClear: u256(base + 16),
      burnCounterFromClear: u256(base + 17),
      transferCounterFromClear: u256(base + 18),
      transferAmountFromClear: u256(base + 19),
      redeemMintCounterFromClear: u256(base + 20),
      usdcMintCounterFromClear: u256(base + 21),
      subordinatesOffset: u256(base + 22),
    };
  };
  const parseSubordinates = (rawHex, subOffset) => {
    if (!rawHex || subOffset === undefined) return [];
    const hex = rawHex.replace(/^0x/, '');
    const structStart = 32 / 32;
    const arrStart = structStart + Number(subOffset) / 32;
    const len = Number(BigInt('0x' + hex.slice(arrStart * 64, (arrStart + 1) * 64)));
    const out = [];
    for (let i = 0; i < len; i++) {
      const addr = '0x' + hex.slice((arrStart + 1 + i) * 64 + 24, (arrStart + 1 + i) * 64 + 64);
      out.push(ethers.getAddress(addr));
    }
    return out;
  };

  const fetchAdminStatsFull = async (admin, periodType) => {
    const iface = new ethers.Interface(ABI);
    const calldata = iface.encodeFunctionData('getAdminStatsFull', [admin, periodType, 0, 0]);
    const raw = await provider.call({ to: CARD, data: calldata });
    return parseStatsFull(raw);
  };

  if (GLOBAL) {
    console.log('=== BeamioUserCard Global Stats (getGlobalStatsFull) ===');
    console.log('Card:', CARD);
    console.log('');
    const parseGlobalStatsFull = (rawHex) => {
      if (!rawHex || typeof rawHex !== 'string') return null;
      const hex = rawHex.replace(/^0x/, '');
      if (hex.length < 32 * 24) return null;
      const u256 = (i) => BigInt('0x' + hex.slice(i * 64, (i + 1) * 64));
      const offset = Number(u256(0));
      const base = offset / 32;
      return {
        cumulativeMint: u256(base + 0),
        cumulativeBurn: u256(base + 1),
        cumulativeTransfer: u256(base + 2),
        cumulativeTransferAmount: u256(base + 3),
        cumulativeRedeemMint: u256(base + 4),
        cumulativeUSDCMint: u256(base + 5),
        cumulativeIssued: u256(base + 6),
        cumulativeUpgraded: u256(base + 7),
        periodMint: u256(base + 8),
        periodBurn: u256(base + 9),
        periodTransfer: u256(base + 10),
        periodTransferAmount: u256(base + 11),
        periodRedeemMint: u256(base + 12),
        periodUSDCMint: u256(base + 13),
        periodIssued: u256(base + 14),
        periodUpgraded: u256(base + 15),
        adminCount: u256(base + 16),
        cumulativeAdminToAdminTransfer: u256(base + 17),
        cumulativeAdminToAdminTransferAmount: u256(base + 18),
        periodAdminToAdminTransfer: u256(base + 19),
        periodAdminToAdminTransferAmount: u256(base + 20),
        lifetimeAdminToAdminTransferCount: u256(base + 21),
        lifetimeAdminToAdminTransferAmount: u256(base + 22),
      };
    };
    let g0 = null;
    let g1 = null;
    const iface = new ethers.Interface(ABI);
    const thirtyDaysAgo = Math.floor(Date.now() / 1000) - 30 * 86400;
    for (const [cumStart, label] of [
      [0, 'all-time (0,0,0)'],
      [thirtyDaysAgo, 'last 30 days'],
    ]) {
      if (g0) break;
      try {
        const calldata0 = iface.encodeFunctionData('getGlobalStatsFull', [0, 0, cumStart]);
        const calldata1 = iface.encodeFunctionData('getGlobalStatsFull', [1, 0, cumStart]);
        const [raw0, raw1] = await Promise.all([
          provider.call({ to: CARD, data: calldata0 }),
          provider.call({ to: CARD, data: calldata1 }),
        ]);
        g0 = parseGlobalStatsFull(raw0);
        g1 = parseGlobalStatsFull(raw1);
        if (g0 && cumStart > 0) console.log('getGlobalStatsFull (0,0,0) gas-limited; used', label, 'instead.\n');
      } catch (err) {
        if (cumStart === 0) console.log('getGlobalStatsFull (native) failed:', err.message);
        else if (!g0) console.log('getGlobalStatsFull (30d fallback) failed:', err.message);
      }
    }
    if (!g0) {
      console.log('Falling back to aggregation of root admins...\n');
    }
    const usedNative = !!g0;
    if (!g0) {
      const [admins, , parents] = await card.getAdminListWithMetadata();
      const owner = await card.owner();
      const zero = ethers.ZeroAddress;
      const rootAdmins = admins.filter((_, i) => {
        const p = (parents && parents[i]) || zero;
        return !p || p === zero || p.toLowerCase() === owner.toLowerCase();
      });
      console.log('Root admins (for aggregation):', rootAdmins.length, rootAdmins.map((a) => a.slice(0, 10) + '...'));
      console.log('');
      const sum = (a, b) => (a || 0n) + (b || 0n);
      g0 = {
        cumulativeMint: 0n,
        cumulativeBurn: 0n,
        cumulativeTransfer: 0n,
        cumulativeTransferAmount: 0n,
        cumulativeRedeemMint: 0n,
        cumulativeUSDCMint: 0n,
        cumulativeIssued: 0n,
        cumulativeUpgraded: 0n,
        periodMint: 0n,
        periodBurn: 0n,
        periodTransfer: 0n,
        periodTransferAmount: 0n,
        periodRedeemMint: 0n,
        periodUSDCMint: 0n,
        periodIssued: 0n,
        periodUpgraded: 0n,
        adminCount: BigInt(admins.length),
        cumulativeAdminToAdminTransfer: 0n,
        cumulativeAdminToAdminTransferAmount: 0n,
        periodAdminToAdminTransfer: 0n,
        periodAdminToAdminTransferAmount: 0n,
        lifetimeAdminToAdminTransferCount: 0n,
        lifetimeAdminToAdminTransferAmount: 0n,
      };
      g1 = { periodMint: 0n, periodTransferAmount: 0n, periodUSDCMint: 0n };
      for (const admin of rootAdmins) {
        const s0 = await fetchAdminStatsFull(admin, 0);
        const s1 = await fetchAdminStatsFull(admin, 1);
        if (s0) {
          g0.cumulativeMint = sum(g0.cumulativeMint, s0.cumulativeMint);
          g0.cumulativeBurn = sum(g0.cumulativeBurn, s0.cumulativeBurn);
          g0.cumulativeTransfer = sum(g0.cumulativeTransfer, s0.cumulativeTransfer);
          g0.cumulativeTransferAmount = sum(g0.cumulativeTransferAmount, s0.cumulativeTransferAmount);
          g0.cumulativeRedeemMint = sum(g0.cumulativeRedeemMint, s0.cumulativeRedeemMint);
          g0.cumulativeUSDCMint = sum(g0.cumulativeUSDCMint, s0.cumulativeUSDCMint);
          g0.cumulativeIssued = sum(g0.cumulativeIssued, s0.cumulativeIssued);
          g0.cumulativeUpgraded = sum(g0.cumulativeUpgraded, s0.cumulativeUpgraded);
          g0.periodMint = sum(g0.periodMint, s0.periodMint);
          g0.periodBurn = sum(g0.periodBurn, s0.periodBurn);
          g0.periodTransfer = sum(g0.periodTransfer, s0.periodTransfer);
          g0.periodTransferAmount = sum(g0.periodTransferAmount, s0.periodTransferAmount);
          g0.periodRedeemMint = sum(g0.periodRedeemMint, s0.periodRedeemMint);
          g0.periodUSDCMint = sum(g0.periodUSDCMint, s0.periodUSDCMint);
          g0.periodIssued = sum(g0.periodIssued, s0.periodIssued);
          g0.periodUpgraded = sum(g0.periodUpgraded, s0.periodUpgraded);
        }
        if (s1) {
          g1.periodMint = sum(g1.periodMint, s1.periodMint);
          g1.periodTransferAmount = sum(g1.periodTransferAmount, s1.periodTransferAmount);
          g1.periodUSDCMint = sum(g1.periodUSDCMint, s1.periodUSDCMint);
        }
      }
    }
    console.log('--- Global Stats (periodType=0 all-time) [' + (usedNative ? 'getGlobalStatsFull (chain)' : 'aggregated') + '] ---');
    console.log('  cumulativeMint (E6):', g0.cumulativeMint.toString(), '→', e6(g0.cumulativeMint));
    console.log('  cumulativeBurn (E6):', g0.cumulativeBurn.toString(), '→', e6(g0.cumulativeBurn));
    console.log('  cumulativeTransfer:', g0.cumulativeTransfer.toString());
    console.log('  cumulativeTransferAmount (E6):', g0.cumulativeTransferAmount.toString(), '→', e6(g0.cumulativeTransferAmount), 'CAD');
    console.log('  cumulativeRedeemMint (E6):', g0.cumulativeRedeemMint.toString(), '→', e6(g0.cumulativeRedeemMint));
    console.log('  cumulativeUSDCMint (E6):', g0.cumulativeUSDCMint.toString(), '→', e6(g0.cumulativeUSDCMint));
    console.log('  cumulativeIssued:', g0.cumulativeIssued.toString());
    console.log('  cumulativeUpgraded:', g0.cumulativeUpgraded.toString());
    console.log('  cumulativeAdminToAdminTransfer:', g0.cumulativeAdminToAdminTransfer?.toString?.() ?? '—');
    console.log(
      '  cumulativeAdminToAdminTransferAmount (E6):',
      g0.cumulativeAdminToAdminTransferAmount?.toString?.() ?? '—',
      '→',
      g0.cumulativeAdminToAdminTransferAmount != null ? e6(g0.cumulativeAdminToAdminTransferAmount) : '—',
      'CAD'
    );
    console.log('  lifetimeAdminToAdminTransferCount:', g0.lifetimeAdminToAdminTransferCount?.toString?.() ?? '—');
    console.log(
      '  lifetimeAdminToAdminTransferAmount (E6):',
      g0.lifetimeAdminToAdminTransferAmount?.toString?.() ?? '—',
      '→',
      g0.lifetimeAdminToAdminTransferAmount != null ? e6(g0.lifetimeAdminToAdminTransferAmount) : '—',
      'CAD'
    );
    console.log('  periodMint (E6):', g0.periodMint.toString(), '→', e6(g0.periodMint));
    console.log('  periodTransferAmount (E6):', g0.periodTransferAmount.toString(), '→', e6(g0.periodTransferAmount), 'CAD');
    console.log('  adminCount:', g0.adminCount != null ? g0.adminCount.toString() : '—');
    console.log('');
    console.log('--- Global Stats (periodType=1 day) ---');
    console.log('  periodTransferAmount (E6):', g1.periodTransferAmount.toString(), '→', e6(g1.periodTransferAmount), 'CAD');
    console.log('  periodAdminToAdminTransfer:', g1.periodAdminToAdminTransfer?.toString?.() ?? '—');
    console.log(
      '  periodAdminToAdminTransferAmount (E6):',
      g1.periodAdminToAdminTransferAmount?.toString?.() ?? '—',
      '→',
      g1.periodAdminToAdminTransferAmount != null ? e6(g1.periodAdminToAdminTransferAmount) : '—',
      'CAD'
    );
    console.log('  periodUSDCMint (E6):', g1.periodUSDCMint.toString(), '→', e6(g1.periodUSDCMint));
    console.log('  periodMint (E6):', g1.periodMint.toString(), '→', e6(g1.periodMint));
    return;
  }

  console.log('=== BeamioUserCard Admin Stats ===');
  console.log('Card:', CARD);
  console.log('Account:', ACCOUNT);
  console.log('');
  const owner = await card.owner();
  console.log('Card Owner:', owner);
  const isAdmin = await card.isAdmin(ACCOUNT);
  console.log('Is Admin:', isAdmin);
  console.log('');
  const [admins] = await card.getAdminListWithMetadata();
  console.log('Admin list:', admins.length, 'admins');
  admins.forEach((a, i) => console.log(`  [${i}]`, a));
  console.log('');
  const limitRes = await card.getAdminAirdropLimit(ACCOUNT);
  console.log('--- getAdminAirdropLimit ---');
  console.log('  admin:', limitRes[0]);
  console.log('  parent:', limitRes[1]);
  console.log('  limit (E6):', limitRes[2].toString(), '→', e6(limitRes[2]), 'display');
  console.log('  usedFromClear (E6):', limitRes[3].toString(), '→', e6(limitRes[3]), 'display');
  console.log('  remainingAvailable (E6):', limitRes[4].toString(), '→', e6(limitRes[4]), 'display');
  console.log('  unlimited:', limitRes[5]);
  console.log('');

  try {
    const iface = new ethers.Interface(ABI);
    const calldata = iface.encodeFunctionData('getAdminStatsFull', [ACCOUNT, 0, 0, 0]);
    const raw0 = await provider.call({ to: CARD, data: calldata });
    const stats0 = parseStatsFull(raw0);
    if (stats0) {
      const subs = parseSubordinates(raw0, stats0.subordinatesOffset);
      console.log('--- getAdminStatsFull (periodType=0 all-time) ---');
      console.log('  cumulativeMint (E6):', stats0.cumulativeMint.toString(), '→', e6(stats0.cumulativeMint));
      console.log('  cumulativeBurn (E6):', stats0.cumulativeBurn.toString(), '→', e6(stats0.cumulativeBurn));
      console.log('  cumulativeTransfer:', stats0.cumulativeTransfer.toString());
      console.log('  cumulativeTransferAmount (E6):', stats0.cumulativeTransferAmount.toString(), '→', e6(stats0.cumulativeTransferAmount), 'CAD');
      console.log('  cumulativeRedeemMint (E6):', stats0.cumulativeRedeemMint.toString(), '→', e6(stats0.cumulativeRedeemMint));
      console.log('  cumulativeUSDCMint (E6):', stats0.cumulativeUSDCMint.toString(), '→', e6(stats0.cumulativeUSDCMint));
      console.log('  cumulativeIssued:', stats0.cumulativeIssued.toString());
      console.log('  cumulativeUpgraded:', stats0.cumulativeUpgraded.toString());
      console.log('  periodMint (E6):', stats0.periodMint.toString(), '→', e6(stats0.periodMint));
      console.log('  periodTransferAmount (E6):', stats0.periodTransferAmount.toString(), '→', e6(stats0.periodTransferAmount), 'CAD');
      console.log('  mintCounterFromClear (E6):', stats0.mintCounterFromClear.toString(), '→', e6(stats0.mintCounterFromClear));
      console.log('  transferAmountFromClear (E6):', stats0.transferAmountFromClear.toString(), '→', e6(stats0.transferAmountFromClear), 'CAD');
      console.log('  subordinates:', subs.length, subs);
    } else {
      console.log('--- getAdminStatsFull (periodType=0) ---');
      console.log('  Parse failed');
    }
  } catch (err) {
    console.log('--- getAdminStatsFull (periodType=0) ---');
    console.log('  Error:', err.message);
  }
  console.log('');

  try {
    const iface = new ethers.Interface(ABI);
    const calldata = iface.encodeFunctionData('getAdminStatsFull', [ACCOUNT, 1, 0, 0]);
    const raw1 = await provider.call({ to: CARD, data: calldata });
    const stats1 = parseStatsFull(raw1);
    if (stats1) {
      console.log('--- getAdminStatsFull (periodType=1 day) ---');
      console.log('  periodTransferAmount (E6):', stats1.periodTransferAmount.toString(), '→', e6(stats1.periodTransferAmount), 'CAD');
      console.log('  periodUSDCMint (E6):', stats1.periodUSDCMint.toString(), '→', e6(stats1.periodUSDCMint));
      console.log('  periodMint (E6):', stats1.periodMint.toString(), '→', e6(stats1.periodMint));
    } else {
      console.log('--- getAdminStatsFull (periodType=1) ---');
      console.log('  Parse failed');
    }
  } catch (err) {
    console.log('--- getAdminStatsFull (periodType=1) ---');
    console.log('  Error:', err.message);
  }
}

main().catch(console.error);
