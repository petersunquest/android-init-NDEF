/**
 * Acceptance (live miners): Base Circle USDC → CoNET canonical USDC → Base.
 *
 * Route:
 *   Base  LockMint(Circle USDC → conet-USDC)
 *   CoNET BurnRelease(conet-USDC → Circle USDC)
 *
 * Policies are enabled via a short sole-miner window (requiredVotes=3 otherwise),
 * then miners are restored before the actual bridge legs so quorum voting is live.
 *
 *   npx tsx scripts/acceptUsdcRoundTripV3.ts
 */
import { ethers } from "ethers";
import { loadSignerPk } from "./utils/loadSignerPk.js";

const BRIDGE = "0xa208982212978550594A7FEEB70a61665d129003";
const CIRCLE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const CONET_USDC = "0x5209865D404aA5646eDe5B91CD4218909eA72eDA";
const CONET_ID = 224422n;
const BASE_ID = 8453n;
/** Must match `TreasuryBridgeV3.AssetMode`: BurnMint=0, LockMint=1, BurnRelease=2 */
const LockMint = 1;
const BurnRelease = 2;
const AMOUNT = 100_000n; // 0.1 USDC (6 decimals)

const OTHER_MINERS = [
  "0xcbBB1371973D57e6bD45aC0dfeFD493b59F9D76B",
  "0x6bF3Aa7261e21Be5Fc781Ac09F9475c8A34AfEea",
  "0xe2E7A68E3D1e50F0Af15d713F90f4992CD19Dfc8",
] as const;

const VOTE_POLL_MS = Number(process.env.ACCEPT_VOTE_POLL_MS || 8_000);
const VOTE_TIMEOUT_MS = Number(process.env.ACCEPT_VOTE_TIMEOUT_MS || 10 * 60_000);

const BRIDGE_ABI = [
  "function miners() view returns (address[])",
  "function requiredVotes() view returns (uint256)",
  "function removeMiner(address)",
  "function addMiner(address)",
  "function isMiner(address) view returns (bool)",
  "function proposeAssetPolicy((uint256 sourceChainId,address sourceTreasury,address sourceAsset,address destinationAsset,uint8 mode,uint8 decimals,bool enabled,uint256 version))",
  "function assetPolicy(bytes32) view returns (tuple(uint256 sourceChainId,address sourceTreasury,address sourceAsset,address destinationAsset,uint8 mode,uint8 decimals,bool enabled,uint256 version))",
  "function destinationFeeBps(uint256) view returns (uint256)",
  "function authorizedBridgeAsset(address) view returns (bool)",
  "function setBridgeAssetAuthorization(address,bool)",
  "function initiateLockMint(uint256,address,address,address,uint256,bytes32,uint256) returns (bytes32)",
  "function initiateBurnRelease(address,uint256,address,address,uint256,bytes32,uint256) returns (bytes32)",
  "function bridgeOperationVoteCount(bytes32) view returns (uint256)",
  "function operationExecuted(bytes32) view returns (bool)",
  "event BridgeOperation(bytes32 indexed operationId,uint256 indexed sourceChainId,uint256 indexed destinationChainId,uint8 phase,uint8 mode,address sourceTreasury,address sourceAsset,address destinationAsset,address sender,address beneficiary,uint256 grossAmount,uint256 feeAmount,uint256 netAmount,bytes32 sourceTxHash,uint256 nonce)",
];

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function allowance(address,address) view returns (uint256)",
];

function policyId(sourceChainId: bigint, sourceAsset: string, destAsset: string, mode: number): string {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint256", "address", "address", "address", "uint8"],
      [sourceChainId, BRIDGE, sourceAsset, destAsset, mode],
    ),
  );
}

async function wait(ms: number) {
  await new Promise((r) => setTimeout(r, ms));
}

async function soleMinerMode(bridge: ethers.Contract, admin: string) {
  for (const m of OTHER_MINERS) {
    if (await bridge.isMiner(m)) {
      const tx = await bridge.removeMiner(m);
      await tx.wait();
      console.log("removed miner", m, tx.hash);
    }
  }
  const after = await bridge.miners();
  const req = await bridge.requiredVotes();
  if (after.length !== 1 || after[0].toLowerCase() !== admin.toLowerCase()) {
    throw new Error(`expected sole miner ${admin}, got ${after}`);
  }
  if (req !== 1n) throw new Error(`expected requiredVotes=1, got ${req}`);
  console.log("sole-miner mode", { miners: after, requiredVotes: req.toString() });
}

async function restoreMiners(bridge: ethers.Contract) {
  for (const m of OTHER_MINERS) {
    if (!(await bridge.isMiner(m))) {
      const tx = await bridge.addMiner(m);
      await tx.wait();
      console.log("restored miner", m, tx.hash);
    }
  }
  console.log("miners restored", await bridge.miners(), "requiredVotes", (await bridge.requiredVotes()).toString());
}

async function ensurePolicy(
  bridge: ethers.Contract,
  sourceChainId: bigint,
  sourceAsset: string,
  destinationAsset: string,
  mode: number,
  decimals: number,
  label: string,
) {
  const id = policyId(sourceChainId, sourceAsset, destinationAsset, mode);
  const existing = await bridge.assetPolicy(id);
  if (existing.enabled) {
    console.log(`policy ok (${label})`, id);
    return;
  }
  const policy = {
    sourceChainId,
    sourceTreasury: BRIDGE,
    sourceAsset,
    destinationAsset,
    mode,
    decimals,
    enabled: true,
    version: 1n,
  };
  const tx = await bridge.proposeAssetPolicy(policy);
  await tx.wait();
  const after = await bridge.assetPolicy(id);
  if (!after.enabled) throw new Error(`policy not enabled (${label}) tx=${tx.hash}`);
  console.log(`policy enabled (${label})`, { tx: tx.hash, id });
}

async function parseInitiated(receipt: ethers.TransactionReceipt, iface: ethers.Interface) {
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== BRIDGE.toLowerCase()) continue;
    try {
      const parsed = iface.parseLog({ topics: log.topics as string[], data: log.data });
      if (parsed?.name === "BridgeOperation" && Number(parsed.args.phase) === 0) {
        return {
          operationId: parsed.args.operationId as string,
          sourceChainId: BigInt(parsed.args.sourceChainId),
          destinationChainId: BigInt(parsed.args.destinationChainId),
          mode: Number(parsed.args.mode),
          sourceTreasury: parsed.args.sourceTreasury as string,
          sourceAsset: parsed.args.sourceAsset as string,
          destinationAsset: parsed.args.destinationAsset as string,
          beneficiary: parsed.args.beneficiary as string,
          grossAmount: BigInt(parsed.args.grossAmount),
          feeAmount: BigInt(parsed.args.feeAmount),
          sourceTxHash: parsed.args.sourceTxHash as string,
          nonce: BigInt(parsed.args.nonce),
        };
      }
    } catch {
      /* not ours */
    }
  }
  throw new Error("BridgeOperation Initiated not found in receipt");
}

async function waitForMinerExecute(destBridge: ethers.Contract, operationId: string, label: string) {
  const started = Date.now();
  let lastVotes = -1n;
  while (Date.now() - started < VOTE_TIMEOUT_MS) {
    const done = await destBridge.operationExecuted(operationId);
    let votes = 0n;
    try {
      votes = await destBridge.bridgeOperationVoteCount(operationId);
    } catch {
      /* ignore */
    }
    if (votes !== lastVotes || done) {
      console.log(`wait miners (${label})`, {
        operationId,
        votes: votes.toString(),
        executed: done,
        elapsedSec: Math.round((Date.now() - started) / 1000),
      });
      lastVotes = votes;
    }
    if (done) return;
    await wait(VOTE_POLL_MS);
  }
  throw new Error(`timeout waiting for miner quorum (${label}) op=${operationId}`);
}

async function main() {
  const pk = loadSignerPk();
  const conet = new ethers.JsonRpcProvider("https://rpc1.conet.network");
  const base = new ethers.JsonRpcProvider("https://base-rpc.conet.network");
  const walletConet = new ethers.Wallet(pk, conet);
  const walletBase = new ethers.Wallet(pk, base);
  const admin = walletConet.address;
  if (admin.toLowerCase() !== "0x87caed4e51c36a2c2ece3aaf4ddac9693d2405e1") {
    throw new Error(`expected admin 0x87cA…, got ${admin}`);
  }

  const bridgeConet = new ethers.Contract(BRIDGE, BRIDGE_ABI, walletConet);
  const bridgeBase = new ethers.Contract(BRIDGE, BRIDGE_ABI, walletBase);
  const circle = new ethers.Contract(CIRCLE_USDC, ERC20_ABI, walletBase);
  const conetUsdc = new ethers.Contract(CONET_USDC, ERC20_ABI, walletConet);
  const iface = new ethers.Interface(BRIDGE_ABI);

  const snap = async (tag: string) => {
    const [cUsdcBal, bUsdcBal, bridgeUsdc, cNat, bEth] = await Promise.all([
      conetUsdc.balanceOf(admin),
      circle.balanceOf(admin),
      circle.balanceOf(BRIDGE),
      conet.getBalance(admin),
      base.getBalance(admin),
    ]);
    const row = {
      tag,
      conetUsdc: ethers.formatUnits(cUsdcBal, 6),
      baseCircleUsdc: ethers.formatUnits(bUsdcBal, 6),
      bridgeCircleUsdc: ethers.formatUnits(bridgeUsdc, 6),
      conetNative: ethers.formatEther(cNat),
      baseEth: ethers.formatEther(bEth),
    };
    console.log(JSON.stringify(row));
    return { cUsdcBal, bUsdcBal, bridgeUsdc, cNat, bEth };
  };

  const before = await snap("start");
  if (before.bUsdcBal < AMOUNT) {
    throw new Error(`need ≥0.1 Circle USDC on Base, have ${ethers.formatUnits(before.bUsdcBal, 6)}`);
  }
  if (before.bEth < ethers.parseEther("0.0002")) {
    throw new Error(`admin Base ETH too low: ${ethers.formatEther(before.bEth)}`);
  }

  // ── Policy bootstrap (sole-miner) then restore live quorum ─────────
  console.log("=== enable USDC policies (temporary sole-miner) ===");
  await soleMinerMode(bridgeBase, admin);
  await soleMinerMode(bridgeConet, admin);
  try {
    // LockMint: Base Circle → CoNET USDC (needed on both storages)
    await ensurePolicy(bridgeBase, BASE_ID, CIRCLE_USDC, CONET_USDC, LockMint, 6, "Base storage LockMint");
    await ensurePolicy(bridgeConet, BASE_ID, CIRCLE_USDC, CONET_USDC, LockMint, 6, "CoNET storage LockMint");
    // BurnRelease: CoNET USDC → Base Circle
    await ensurePolicy(bridgeConet, CONET_ID, CONET_USDC, CIRCLE_USDC, BurnRelease, 6, "CoNET storage BurnRelease");
    await ensurePolicy(bridgeBase, CONET_ID, CONET_USDC, CIRCLE_USDC, BurnRelease, 6, "Base storage BurnRelease");
    if (!(await bridgeConet.authorizedBridgeAsset(CONET_USDC))) {
      await (await bridgeConet.setBridgeAssetAuthorization(CONET_USDC, true)).wait();
      console.log("authorized CONET USDC on CoNET bridge");
    }
  } finally {
    await restoreMiners(bridgeBase);
    await restoreMiners(bridgeConet);
  }

  const reqBase = await bridgeBase.requiredVotes();
  const reqConet = await bridgeConet.requiredVotes();
  if (reqBase < 2n || reqConet < 2n) {
    throw new Error(`expected live quorum ≥2, got base=${reqBase} conet=${reqConet}`);
  }
  console.log("=== live miner quorum ready ===", {
    baseMiners: await bridgeBase.miners(),
    baseReq: reqBase.toString(),
    conetReq: reqConet.toString(),
  });

  // ── 1) Base → CoNET LockMint 0.1 USDC ───────────────────────────────
  const feeOutBps = await bridgeBase.destinationFeeBps(CONET_ID);
  const feeOut = (AMOUNT * feeOutBps) / 10_000n;
  const needApprove = AMOUNT + feeOut;
  console.log("outbound LockMint", {
    amount: ethers.formatUnits(AMOUNT, 6),
    feeBps: feeOutBps.toString(),
    fee: ethers.formatUnits(feeOut, 6),
  });
  if ((await circle.allowance(admin, BRIDGE)) < needApprove) {
    const appr = await circle.approve(BRIDGE, needApprove);
    await appr.wait();
    console.log("approved Circle USDC", appr.hash);
  }
  const nonceOut = BigInt(Date.now());
  const initOut = await bridgeBase.initiateLockMint(
    CONET_ID,
    CIRCLE_USDC,
    CONET_USDC,
    admin,
    AMOUNT,
    ethers.ZeroHash,
    nonceOut,
  );
  const initOutReceipt = await initOut.wait();
  if (!initOutReceipt) throw new Error("missing LockMint receipt");
  const opOut = await parseInitiated(initOutReceipt, iface);
  console.log("initiated Base→CoNET LockMint", { tx: initOut.hash, operationId: opOut.operationId });

  await waitForMinerExecute(bridgeConet, opOut.operationId, "Base→CoNET");
  const afterIn = await snap("after-base-to-conet");
  if (afterIn.cUsdcBal < before.cUsdcBal + AMOUNT) {
    throw new Error(
      `CoNET USDC ${ethers.formatUnits(afterIn.cUsdcBal, 6)} < expected ≥ ${ethers.formatUnits(before.cUsdcBal + AMOUNT, 6)}`,
    );
  }

  // ── 2) CoNET → Base BurnRelease (spend minted USDC; fee on CoNET→Base) ─
  const feeBackBps = await bridgeConet.destinationFeeBps(BASE_ID);
  const balConet = await conetUsdc.balanceOf(admin);
  // Spend up to the just-minted AMOUNT (leave any prior dust)
  const spend = balConet < AMOUNT ? balConet : AMOUNT;
  const amountBack = (spend * 10_000n) / (10_000n + feeBackBps);
  const feeBack = (amountBack * feeBackBps) / 10_000n;
  console.log("inbound BurnRelease", {
    feeBps: feeBackBps.toString(),
    amount: ethers.formatUnits(amountBack, 6),
    fee: ethers.formatUnits(feeBack, 6),
    spend: ethers.formatUnits(amountBack + feeBack, 6),
  });
  const needBack = amountBack + feeBack;
  if ((await conetUsdc.allowance(admin, BRIDGE)) < needBack) {
    const appr2 = await conetUsdc.approve(BRIDGE, needBack);
    await appr2.wait();
    console.log("approved CONET USDC", appr2.hash);
  }
  const nonceBack = BigInt(Date.now() + 1);
  const initBack = await bridgeConet.initiateBurnRelease(
    CONET_USDC,
    BASE_ID,
    CIRCLE_USDC,
    admin,
    amountBack,
    ethers.ZeroHash,
    nonceBack,
  );
  const initBackReceipt = await initBack.wait();
  if (!initBackReceipt) throw new Error("missing BurnRelease receipt");
  const opBack = await parseInitiated(initBackReceipt, iface);
  console.log("initiated CoNET→Base BurnRelease", { tx: initBack.hash, operationId: opBack.operationId });

  await waitForMinerExecute(bridgeBase, opBack.operationId, "CoNET→Base");
  const finalSnap = await snap("final");

  const circleDelta = finalSnap.bUsdcBal - before.bUsdcBal;
  console.log(
    JSON.stringify(
      {
        ok: true,
        mode: "live-miner-quorum",
        amountIn: ethers.formatUnits(AMOUNT, 6),
        amountBack: ethers.formatUnits(amountBack, 6),
        feeBack: ethers.formatUnits(feeBack, 6),
        circleUsdcDelta: ethers.formatUnits(circleDelta, 6),
        outTx: initOut.hash,
        outOp: opOut.operationId,
        backTx: initBack.hash,
        backOp: opBack.operationId,
        final: {
          conetUsdc: ethers.formatUnits(finalSnap.cUsdcBal, 6),
          baseCircleUsdc: ethers.formatUnits(finalSnap.bUsdcBal, 6),
          bridgeCircleUsdc: ethers.formatUnits(finalSnap.bridgeUsdc, 6),
        },
      },
      null,
      2,
    ),
  );
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
