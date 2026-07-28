/**
 * Acceptance (live miners): wrap 1 CNET → wCNET on CoNET, BurnMint to Base, BurnMint back.
 *
 * Requires on-chain miner quorum (default 4 miners / requiredVotes=3) and running
 * SI `treasuryV3Listen` voters on miner hosts. Does NOT remove miners.
 *
 *   npx tsx scripts/acceptWCnetRoundTripV3.ts
 */
import { ethers } from "ethers";
import { loadSignerPk } from "./utils/loadSignerPk.js";

const BRIDGE = "0xa208982212978550594A7FEEB70a61665d129003";
const WCNET = "0x2DC57d67C9764DeE5788421029Abaf81B992FAaF";
const CONET_ID = 224422n;
const BASE_ID = 8453n;
const EXPECTED_MINERS = [
  "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1",
  "0xcbBB1371973D57e6bD45aC0dfeFD493b59F9D76B",
  "0x6bF3Aa7261e21Be5Fc781Ac09F9475c8A34AfEea",
  "0xe2E7A68E3D1e50F0Af15d713F90f4992CD19Dfc8",
] as const;

const BurnMint = 1;
const VOTE_POLL_MS = Number(process.env.ACCEPT_VOTE_POLL_MS || 8_000);
const VOTE_TIMEOUT_MS = Number(process.env.ACCEPT_VOTE_TIMEOUT_MS || 10 * 60_000);

const BRIDGE_ABI = [
  "function owner() view returns (address)",
  "function miners() view returns (address[])",
  "function requiredVotes() view returns (uint256)",
  "function isMiner(address) view returns (bool)",
  "function bridgeOperationVoteCount(bytes32) view returns (uint256)",
  "function proposeAssetPolicy((uint256 sourceChainId,address sourceTreasury,address sourceAsset,address destinationAsset,uint8 mode,uint8 decimals,bool enabled,uint256 version))",
  "function assetPolicy(bytes32) view returns (tuple(uint256 sourceChainId,address sourceTreasury,address sourceAsset,address destinationAsset,uint8 mode,uint8 decimals,bool enabled,uint256 version))",
  "function destinationFeeBps(uint256) view returns (uint256)",
  "function authorizedBridgeAsset(address) view returns (bool)",
  "function setBridgeAssetAuthorization(address,bool)",
  "function initiateBurnMintForUser(address,uint256,address,address,uint256,bytes32,uint256) returns (bytes32)",
  "function operationExecuted(bytes32) view returns (bool)",
  "event BridgeOperation(bytes32 indexed operationId,uint256 indexed sourceChainId,uint256 indexed destinationChainId,uint8 phase,uint8 mode,address sourceTreasury,address sourceAsset,address destinationAsset,address sender,address beneficiary,uint256 grossAmount,uint256 feeAmount,uint256 netAmount,bytes32 sourceTxHash,uint256 nonce)",
];

const WCNET_ABI = [
  "function deposit() payable",
  "function withdraw(uint256)",
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function nativeWrapEnabled() view returns (bool)",
];

function policyId(sourceChainId: bigint, sourceAsset: string, mode: number): string {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint256", "address", "address", "address", "uint8"],
      [sourceChainId, BRIDGE, sourceAsset, sourceAsset, mode],
    ),
  );
}

async function wait(ms: number) {
  await new Promise((r) => setTimeout(r, ms));
}

async function ensurePolicy(bridge: ethers.Contract, sourceChainId: bigint, label: string) {
  const id = policyId(sourceChainId, WCNET, BurnMint);
  const existing = await bridge.assetPolicy(id);
  if (existing.enabled) {
    console.log(`policy ok (${label})`, id);
    return;
  }
  const policy = {
    sourceChainId,
    sourceTreasury: BRIDGE,
    sourceAsset: WCNET,
    destinationAsset: WCNET,
    mode: BurnMint,
    decimals: 18,
    enabled: true,
    version: 1n,
  };
  const tx = await bridge.proposeAssetPolicy(policy);
  const receipt = await tx.wait();
  const after = await bridge.assetPolicy(id);
  if (!after.enabled) throw new Error(`policy not enabled after propose (${label}) tx=${tx.hash}`);
  console.log(`policy enabled (${label})`, { tx: tx.hash, block: receipt?.blockNumber, id });
}

async function assertLiveMinerQuorum(bridge: ethers.Contract, chain: string) {
  const miners: string[] = await bridge.miners();
  const req: bigint = await bridge.requiredVotes();
  console.log(`quorum (${chain})`, { miners, requiredVotes: req.toString() });
  if (miners.length < 3) throw new Error(`${chain}: need ≥3 miners for live acceptance, got ${miners.length}`);
  if (req < 2n) throw new Error(`${chain}: requiredVotes=${req} looks like sole-miner; refuse live acceptance`);
  for (const m of EXPECTED_MINERS) {
    if (!(await bridge.isMiner(m))) throw new Error(`${chain}: expected miner missing ${m}`);
  }
  if (req > BigInt(miners.length)) throw new Error(`${chain}: requiredVotes ${req} > minerCount ${miners.length}`);
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

/** Wait for SI miners to vote + auto-execute (no local vote). */
async function waitForMinerExecute(
  destBridge: ethers.Contract,
  operationId: string,
  label: string,
) {
  const started = Date.now();
  let lastVotes = -1n;
  while (Date.now() - started < VOTE_TIMEOUT_MS) {
    const done = await destBridge.operationExecuted(operationId);
    let votes = 0n;
    try {
      votes = await destBridge.bridgeOperationVoteCount(operationId);
    } catch {
      /* older ABI without getter — ignore */
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
  throw new Error(
    `timeout waiting for miner quorum execute (${label}) op=${operationId} after ${VOTE_TIMEOUT_MS}ms`,
  );
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
  const wcnetConet = new ethers.Contract(WCNET, WCNET_ABI, walletConet);
  const wcnetBase = new ethers.Contract(WCNET, WCNET_ABI, walletBase);
  const iface = new ethers.Interface(BRIDGE_ABI);

  await assertLiveMinerQuorum(bridgeConet, "CoNET");
  await assertLiveMinerQuorum(bridgeBase, "Base");

  const snap = async (tag: string) => {
    const [cBal, bBal, cNat, bNat, cSup, bSup] = await Promise.all([
      wcnetConet.balanceOf(admin),
      wcnetBase.balanceOf(admin),
      conet.getBalance(admin),
      base.getBalance(admin),
      wcnetConet.totalSupply(),
      wcnetBase.totalSupply(),
    ]);
    const row = {
      tag,
      conetWCnet: ethers.formatEther(cBal),
      baseWCnet: ethers.formatEther(bBal),
      conetNative: ethers.formatEther(cNat),
      baseEth: ethers.formatEther(bNat),
      supplyConet: ethers.formatEther(cSup),
      supplyBase: ethers.formatEther(bSup),
    };
    console.log(JSON.stringify(row));
    return { cBal, bBal, cNat, bNat, cSup, bSup };
  };

  const beforeAll = await snap("start");
  if (beforeAll.bNat < ethers.parseEther("0.0003")) {
    throw new Error(`admin Base ETH too low for initiate: ${ethers.formatEther(beforeAll.bNat)}`);
  }

  if (!(await bridgeConet.authorizedBridgeAsset(WCNET))) {
    await (await bridgeConet.setBridgeAssetAuthorization(WCNET, true)).wait();
  }
  if (!(await bridgeBase.authorizedBridgeAsset(WCNET))) {
    await (await bridgeBase.setBridgeAssetAuthorization(WCNET, true)).wait();
  }

  await ensurePolicy(bridgeConet, CONET_ID, "CoNET storage / CoNET→Base initiate");
  await ensurePolicy(bridgeBase, CONET_ID, "Base storage / CoNET→Base execute");
  await ensurePolicy(bridgeBase, BASE_ID, "Base storage / Base→CoNET initiate");
  await ensurePolicy(bridgeConet, BASE_ID, "CoNET storage / Base→CoNET execute");

  // ── 1) Wrap exactly 1 CNET → wCNET ─────────────────────────────────
  if (!(await wcnetConet.nativeWrapEnabled())) throw new Error("nativeWrapEnabled=false");
  const wrapAmt = ethers.parseEther("1");
  const wrapTx = await wcnetConet.deposit({ value: wrapAmt });
  await wrapTx.wait();
  console.log("wrap 1 CNET→wCNET", wrapTx.hash);
  await snap("after-wrap");

  // ── 2) CoNET → Base BurnMint ───────────────────────────────────────
  const feeBps = await bridgeConet.destinationFeeBps(BASE_ID);
  const spend = wrapAmt;
  const amountOut = (spend * 10_000n) / (10_000n + feeBps);
  const feeOut = (amountOut * feeBps) / 10_000n;
  if (amountOut + feeOut > spend) throw new Error("fee math overflow");
  console.log("outbound", {
    feeBps: feeBps.toString(),
    amount: ethers.formatEther(amountOut),
    fee: ethers.formatEther(feeOut),
    total: ethers.formatEther(amountOut + feeOut),
  });

  if (feeOut > 0n) {
    const appr = await wcnetConet.approve(BRIDGE, feeOut);
    await appr.wait();
  }
  const nonceOut = BigInt(Date.now());
  const initOut = await bridgeConet.initiateBurnMintForUser(
    WCNET,
    BASE_ID,
    WCNET,
    admin,
    amountOut,
    ethers.ZeroHash,
    nonceOut,
  );
  const initOutReceipt = await initOut.wait();
  if (!initOutReceipt) throw new Error("missing initOut receipt");
  const opOut = await parseInitiated(initOutReceipt, iface);
  console.log("initiated CoNET→Base", { tx: initOut.hash, operationId: opOut.operationId });

  await waitForMinerExecute(bridgeBase, opOut.operationId, "CoNET→Base");
  const afterOut = await snap("after-conet-to-base");
  if (afterOut.bBal < amountOut) {
    throw new Error(`Base wCNET balance ${afterOut.bBal} < minted ${amountOut}`);
  }

  // ── 3) Base → CoNET BurnMint ────────────────────────────────────────
  const feeBpsBack = await bridgeBase.destinationFeeBps(CONET_ID);
  const balBase = await wcnetBase.balanceOf(admin);
  const amountBack = (balBase * 10_000n) / (10_000n + feeBpsBack);
  const feeBack = (amountBack * feeBpsBack) / 10_000n;
  console.log("inbound", {
    feeBps: feeBpsBack.toString(),
    amount: ethers.formatEther(amountBack),
    fee: ethers.formatEther(feeBack),
    baseBal: ethers.formatEther(balBase),
  });
  if (feeBack > 0n) {
    const appr2 = await wcnetBase.approve(BRIDGE, feeBack);
    await appr2.wait();
  }
  const nonceBack = BigInt(Date.now() + 1);
  const initBack = await bridgeBase.initiateBurnMintForUser(
    WCNET,
    CONET_ID,
    WCNET,
    admin,
    amountBack,
    ethers.ZeroHash,
    nonceBack,
  );
  const initBackReceipt = await initBack.wait();
  if (!initBackReceipt) throw new Error("missing initBack receipt");
  const opBack = await parseInitiated(initBackReceipt, iface);
  console.log("initiated Base→CoNET", { tx: initBack.hash, operationId: opBack.operationId });

  await waitForMinerExecute(bridgeConet, opBack.operationId, "Base→CoNET");
  const afterBack = await snap("after-base-to-conet");

  // ── 4) Unwrap returned wCNET → native CNET ─────────────────────────
  const unwrapAmt = amountBack < afterBack.cBal ? amountBack : afterBack.cBal;
  let unwrapTxHash: string | undefined;
  if (unwrapAmt > 0n) {
    const wTx = await wcnetConet.withdraw(unwrapAmt);
    await wTx.wait();
    unwrapTxHash = wTx.hash;
    console.log("unwrap wCNET→CNET", { tx: unwrapTxHash, amount: ethers.formatEther(unwrapAmt) });
  }
  const finalSnap = await snap("final");

  console.log(
    JSON.stringify(
      {
        ok: true,
        mode: "live-miner-quorum",
        wrapTx: wrapTx.hash,
        outTx: initOut.hash,
        outOp: opOut.operationId,
        backTx: initBack.hash,
        backOp: opBack.operationId,
        unwrapTx: unwrapTxHash,
        amountOut: ethers.formatEther(amountOut),
        amountBack: ethers.formatEther(amountBack),
        final: {
          conetWCnet: ethers.formatEther(finalSnap.cBal),
          baseWCnet: ethers.formatEther(finalSnap.bBal),
          conetNative: ethers.formatEther(finalSnap.cNat),
          baseEth: ethers.formatEther(finalSnap.bNat),
          supplyConet: ethers.formatEther(finalSnap.cSup),
          supplyBase: ethers.formatEther(finalSnap.bSup),
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
