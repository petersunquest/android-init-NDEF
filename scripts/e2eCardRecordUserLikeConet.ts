/**
 * Plan A E2E：构造 RecordUserLike EIP-712 签名 → POST /api/cardRecordUserLike → 链上 like token 余额变化。
 *
 * 运行:
 *   npx tsx scripts/e2eCardRecordUserLikeConet.ts
 *
 * 环境变量:
 *   E2E_LIKE_API_URL      — 默认 https://beamio.app
 *   E2E_LIKE_CARD         — 默认 LongDhang（已 init cumulative stat）
 *   E2E_LIKE_PRIVATE_KEY  — 可选；未设则临时随机钱包
 *   E2E_LIKE_SKIP_UNLIKE   — 设为 1 则点赞后不取消
 *   CONET_RPC_URL         — 默认 https://publicrpc.conet.network
 */

import { ethers } from "ethers";

const API_BASE = (process.env.E2E_LIKE_API_URL || "https://beamio.app").replace(/\/$/, "");
const CONET_RPC = process.env.CONET_RPC_URL || "https://publicrpc.conet.network";
const CHAIN_ID = 224422;

const DEFAULT_CARD =
  process.env.E2E_LIKE_CARD || "0xc06055AEEd896F832e602a5876D2Dbe1CB365A8A";

const RECORD_USER_LIKE_EIP712_TYPE = {
  RecordUserLike: [
    { name: "cardAddress", type: "address" },
    { name: "userEOA", type: "address" },
    { name: "targetKind", type: "uint8" },
    { name: "issuedParentId", type: "uint256" },
    { name: "liked", type: "bool" },
    { name: "deadline", type: "uint256" },
    { name: "nonce", type: "bytes32" },
  ],
} as const;

const UC_METRIC_USER_LIKE = 5;
const UC_TARGET_MERCHANT_CARD = 1;

async function readFactoryGateway(card: string, provider: ethers.Provider): Promise<string> {
  const reader = new ethers.Contract(card, ["function factoryGateway() view returns (address)"], provider);
  const gw = (await reader.factoryGateway()) as string;
  if (!gw || !ethers.isAddress(gw)) throw new Error(`factoryGateway invalid for ${card}`);
  return ethers.getAddress(gw);
}

async function readLikeScopedBalance(
  card: string,
  user: string,
  targetKind: number,
  issuedParentId: bigint,
  provider: ethers.Provider,
): Promise<bigint> {
  const reader = new ethers.Contract(
    card,
    [
      "function balanceOf(address account, uint256 id) view returns (uint256)",
      "function resolveUserCumulativeStatTokenId(uint8 metricKind, uint8 targetKind, uint256 issuedParentId) view returns (uint256 globalTokenId, uint256 scopedTokenId)",
    ],
    provider,
  );
  const [, scopedTokenId] = (await reader.resolveUserCumulativeStatTokenId(
    UC_METRIC_USER_LIKE,
    targetKind,
    issuedParentId,
  )) as [bigint, bigint];
  if (scopedTokenId === 0n) return 0n;
  return (await reader.balanceOf(user, scopedTokenId)) as bigint;
}

async function readCumulativeStatInitialized(card: string, provider: ethers.Provider): Promise<boolean> {
  const reader = new ethers.Contract(
    card,
    ["function cardUserCumulativeStatTokensInitialized() view returns (bool)"],
    provider,
  );
  return Boolean(await reader.cardUserCumulativeStatTokensInitialized());
}

async function signRecordUserLike(params: {
  signer: ethers.Wallet;
  card: string;
  verifyingContract: string;
  targetKind: number;
  issuedParentId: bigint;
  liked: boolean;
}): Promise<{ deadline: number; nonce: string; userSignature: string; userEOA: string }> {
  const userEOA = ethers.getAddress(params.signer.address);
  const cardNorm = ethers.getAddress(params.card);
  const deadline = Math.floor(Date.now() / 1000) + 15 * 60;
  const nonce = ethers.hexlify(ethers.randomBytes(32));
  const userSignature = await params.signer.signTypedData(
    {
      name: "BeamioUserCardFactory",
      version: "1",
      chainId: CHAIN_ID,
      verifyingContract: params.verifyingContract,
    },
    RECORD_USER_LIKE_EIP712_TYPE,
    {
      cardAddress: cardNorm,
      userEOA,
      targetKind: params.targetKind,
      issuedParentId: params.issuedParentId,
      liked: params.liked,
      deadline: BigInt(deadline),
      nonce,
    },
  );
  return { deadline, nonce, userSignature, userEOA };
}

async function postCardRecordUserLike(body: Record<string, unknown>): Promise<{
  ok: boolean;
  status: number;
  data: { success?: boolean; hash?: string; tx?: string; error?: string; code?: string };
}> {
  const res = await fetch(`${API_BASE}/api/cardRecordUserLike`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = (await res.json().catch(() => ({}))) as {
    success?: boolean;
    hash?: string;
    tx?: string;
    error?: string;
    code?: string;
  };
  return { ok: res.ok, status: res.status, data };
}

async function waitForBalance(
  provider: ethers.Provider,
  card: string,
  user: string,
  targetKind: number,
  issuedParentId: bigint,
  expect: (bal: bigint) => boolean,
  label: string,
): Promise<bigint> {
  for (let i = 0; i < 45; i++) {
    const bal = await readLikeScopedBalance(card, user, targetKind, issuedParentId, provider);
    if (expect(bal)) {
      console.log(`  ✅ ${label} balance=${bal.toString()}`);
      return bal;
    }
    await new Promise((r) => setTimeout(r, 4000));
  }
  throw new Error(`${label}: balance did not reach expected state within 180s`);
}

async function runLikeCycle(params: {
  signer: ethers.Wallet;
  card: string;
  verifyingContract: string;
  targetKind: number;
  issuedParentId: bigint;
  liked: boolean;
  provider: ethers.Provider;
}): Promise<string> {
  const signed = await signRecordUserLike({
    signer: params.signer,
    card: params.card,
    verifyingContract: params.verifyingContract,
    targetKind: params.targetKind,
    issuedParentId: params.issuedParentId,
    liked: params.liked,
  });
  console.log(`\nPOST ${params.liked ? "like" : "unlike"} user=${signed.userEOA}`);
  const resp = await postCardRecordUserLike({
    cardAddress: params.card,
    userEOA: signed.userEOA,
    targetKind: params.targetKind,
    issuedParentId: String(params.issuedParentId),
    liked: params.liked,
    deadline: signed.deadline,
    nonce: signed.nonce,
    userSignature: signed.userSignature,
  });
  console.log("  HTTP", resp.status, JSON.stringify(resp.data));
  if (!resp.ok || resp.data.success === false) {
    throw new Error(resp.data.error || `API failed (${resp.status})`);
  }
  const hash = resp.data.hash || resp.data.tx;
  if (!hash) throw new Error("API success but missing tx hash");
  console.log(`  tx: https://mainnet.conet.network/tx/${hash}`);
  await waitForBalance(
    params.provider,
    params.card,
    signed.userEOA,
    params.targetKind,
    params.issuedParentId,
    params.liked ? (b) => b > 0n : (b) => b === 0n,
    params.liked ? "after like" : "after unlike",
  );
  return hash;
}

async function main() {
  const card = ethers.getAddress(DEFAULT_CARD);
  const provider = new ethers.JsonRpcProvider(CONET_RPC, CHAIN_ID);

  const pk = process.env.E2E_LIKE_PRIVATE_KEY?.trim();
  const signer = pk
    ? new ethers.Wallet(pk.startsWith("0x") ? pk : `0x${pk}`, provider)
    : ethers.Wallet.createRandom(provider);

  const targetKind = UC_TARGET_MERCHANT_CARD;
  const issuedParentId = 0n;

  console.log("Plan A cardRecordUserLike E2E");
  console.log("API:", API_BASE);
  console.log("RPC:", CONET_RPC);
  console.log("card:", card);
  console.log("user:", signer.address, pk ? "(env key)" : "(ephemeral)");

  const initialized = await readCumulativeStatInitialized(card, provider);
  if (!initialized) {
    throw new Error(`Card ${card} cumulative stat tokens not initialized — pick an init card or run init first`);
  }
  const verifyingContract = await readFactoryGateway(card, provider);
  console.log("factoryGateway (EIP-712 verifyingContract):", verifyingContract);

  let balBefore = await readLikeScopedBalance(card, signer.address, targetKind, issuedParentId, provider);
  console.log("like scoped balance before:", balBefore.toString());

  if (balBefore > 0n) {
    console.log("\n-- pre-clean: unlike existing like --");
    await runLikeCycle({
      signer,
      card,
      verifyingContract,
      targetKind,
      issuedParentId,
      liked: false,
      provider,
    });
    balBefore = 0n;
  }

  console.log("\n-- like --");
  await runLikeCycle({
    signer,
    card,
    verifyingContract,
    targetKind,
    issuedParentId,
    liked: true,
    provider,
  });

  if (process.env.E2E_LIKE_SKIP_UNLIKE !== "1") {
    console.log("\n-- unlike (cleanup) --");
    await runLikeCycle({
      signer,
      card,
      verifyingContract,
      targetKind,
      issuedParentId,
      liked: false,
      provider,
    });
  }

  console.log("\n✅ E2E complete — Plan A applyUserLikeWithSignature path OK");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
