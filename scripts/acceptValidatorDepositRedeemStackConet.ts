/**
 * CoNET 链上验收：ValidatorDepositRedeem 全栈（主合约 + ReferrerExtension + RewardIndexer + StatsLib + TransferMarket）
 *
 * 运行:
 *   npx tsx scripts/acceptValidatorDepositRedeemStackConet.ts
 *
 * 可选:
 *   CONET_RPC_URL=https://publicrpc.conet.network
 *   CONET_BLOCKSCOUT_API=https://mainnet.conet.network/api
 */

import * as fs from "fs";
import * as path from "path";
import { Contract, ethers, getAddress } from "ethers";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const CONET_RPC = process.env.CONET_RPC_URL || "https://publicrpc.conet.network";
const BLOCKSCOUT_API = (process.env.CONET_BLOCKSCOUT_API || "https://mainnet.conet.network/api").replace(/\/$/, "");
const BLOCKSCOUT_UI = (process.env.CONET_BLOCKSCOUT_UI || "https://mainnet.conet.network").replace(/\/$/, "");
const EXPECTED_DEPOSIT = getAddress(
  process.env.CONET_DEPOSIT_CONTRACT?.trim() || "0x4242424242424242424242424242424242424242"
);
const REFERRER_NODES_PER_REWARD = 10n;
const EIP170_MAX = 24576;

type StackAddrs = {
  redeem: string;
  statsLib: string;
  referrerExt: string;
  transferMarket: string;
  rewardIndexer: string;
};

function loadStack(): StackAddrs {
  const addrPath = path.join(root, "deployments", "conet-addresses.json");
  if (!fs.existsSync(addrPath)) throw new Error("缺少 deployments/conet-addresses.json");
  const data = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, string | undefined>;
  const pick = (k: string) => {
    const raw = data[k]?.trim();
    if (!raw || !ethers.isAddress(raw)) throw new Error(`conet-addresses.json 缺少 ${k}`);
    return getAddress(raw);
  };
  return {
    redeem: pick("ValidatorDepositRedeem"),
    statsLib: pick("ValidatorDepositRedeemStatsLib"),
    referrerExt: pick("ValidatorDepositRedeemReferrerExtension"),
    transferMarket: pick("ValidatorDepositRedeemTransferMarket"),
    rewardIndexer: pick("ValidatorNodeRewardIndexer"),
  };
}

async function rpc<T>(method: string, params: unknown[]): Promise<T> {
  const res = await fetch(CONET_RPC, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", method, params, id: 1 }),
  });
  const body = (await res.json()) as { result?: T; error?: { message?: string } };
  if (body.error) throw new Error(`${method}: ${body.error.message ?? JSON.stringify(body.error)}`);
  return body.result as T;
}

async function codeSize(address: string): Promise<number> {
  const code = await rpc<string>("eth_getCode", [address, "latest"]);
  return code.length > 2 ? (code.length - 2) / 2 : 0;
}

async function blockscoutVerified(address: string): Promise<boolean> {
  const res = await fetch(`${BLOCKSCOUT_API}/v2/smart-contracts/${address}`);
  if (!res.ok) return false;
  const data = (await res.json()) as { is_verified?: boolean; source_code?: string | null };
  return Boolean(data.is_verified || data.source_code);
}

type Check = { name: string; ok: boolean; detail: string };

async function main() {
  const stack = loadStack();
  const provider = new ethers.JsonRpcProvider(CONET_RPC, 224422);
  const checks: Check[] = [];

  console.log("=".repeat(60));
  console.log("ValidatorDepositRedeem stack — CoNET acceptance");
  console.log("=".repeat(60));
  console.log("RPC:", CONET_RPC);
  console.log("redeem:", stack.redeem);
  console.log("referrerExt:", stack.referrerExt);
  console.log("rewardIndexer:", stack.rewardIndexer);
  console.log("statsLib:", stack.statsLib);
  console.log("transferMarket:", stack.transferMarket);
  console.log("");

  for (const [label, addr] of Object.entries(stack)) {
    const size = await codeSize(addr);
    checks.push({
      name: `${label} bytecode`,
      ok: size > 0,
      detail: size > 0 ? `${size} bytes` : "no code",
    });
    if (label === "redeem") {
      checks.push({
        name: "redeem EIP-170",
        ok: size > 0 && size <= EIP170_MAX,
        detail: `${size} / ${EIP170_MAX}`,
      });
    }
  }

  const redeem = new Contract(
    stack.redeem,
    [
      "function referrerExtension() view returns (address)",
      "function rewardIndexer() view returns (address)",
      "function depositContract() view returns (address)",
      "function transferMarket() view returns (address)",
      "function resolveUnifiedIncomeStats(address maybeWallet, string conetDepinNodeIp, uint256 anchorTs) view returns (tuple(uint256 gbTotal,uint256 cnetTotal,uint256 nodeCount,uint256 depinNodeCount))",
    ],
    provider
  );

  const probeWallet = getAddress(
    (JSON.parse(fs.readFileSync(path.join(root, "deployments", "conet-ValidatorDepositRedeem.json"), "utf-8")) as {
      initialRedeemAdmin?: string;
    }).initialRedeemAdmin || "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1"
  );

  const ext = new Contract(
    stack.referrerExt,
    [
      "function redeemHost() view returns (address)",
      "function REFERRER_NODES_PER_REWARD() view returns (uint256)",
      "function resolveReferrerDetail(address referrer, uint256 beneficiaryOffset, uint256 beneficiaryLimit) view returns (address[] referredBeneficiaries, uint256 referralNodeTotal, uint256 rewardNodesGranted, uint256 pendingRewardNodes, tuple(uint256 guardianNodeId, address nodeWallet, string depinNodeIp)[] rewardNodes)",
    ],
    provider
  );

  const indexer = new Contract(
    stack.rewardIndexer,
    [
      "function redeem() view returns (address)",
      "function PERIOD_HOUR() view returns (uint8)",
      "function totalCumulativeReward() view returns (uint256)",
    ],
    provider
  );

  const market = new Contract(stack.transferMarket, ["function redeemHost() view returns (address)"], provider);

  const onChainExt = getAddress(await redeem.referrerExtension());
  const onChainIdx = getAddress(await redeem.rewardIndexer());
  const onChainDep = getAddress(await redeem.depositContract());
  const onChainMarket = getAddress(await redeem.transferMarket());

  checks.push({
    name: "redeem.referrerExtension",
    ok: onChainExt === stack.referrerExt,
    detail: `${onChainExt} (expect ${stack.referrerExt})`,
  });
  checks.push({
    name: "redeem.rewardIndexer",
    ok: onChainIdx === stack.rewardIndexer,
    detail: `${onChainIdx} (expect ${stack.rewardIndexer})`,
  });
  checks.push({
    name: "redeem.depositContract",
    ok: onChainDep === EXPECTED_DEPOSIT,
    detail: `${onChainDep} (expect ${EXPECTED_DEPOSIT})`,
  });
  checks.push({
    name: "redeem.transferMarket",
    ok: onChainMarket === stack.transferMarket,
    detail: `${onChainMarket} (expect ${stack.transferMarket})`,
  });

  const extHost = getAddress(await ext.redeemHost());
  checks.push({
    name: "referrerExt.redeemHost",
    ok: extHost === stack.redeem,
    detail: `${extHost}`,
  });

  const perReward = await ext.REFERRER_NODES_PER_REWARD();
  checks.push({
    name: "referrerExt.REFERRER_NODES_PER_REWARD",
    ok: BigInt(perReward) === REFERRER_NODES_PER_REWARD,
    detail: String(perReward),
  });

  try {
    await ext.resolveReferrerDetail.staticCall(probeWallet, 0, 0);
    checks.push({ name: "referrerExt.resolveReferrerDetail", ok: true, detail: `callable @ ${probeWallet}` });
  } catch (e: unknown) {
    checks.push({
      name: "referrerExt.resolveReferrerDetail",
      ok: false,
      detail: (e as Error)?.message?.slice(0, 120) ?? String(e),
    });
  }

  const idxRedeem = getAddress(await indexer.redeem());
  checks.push({
    name: "rewardIndexer.redeem",
    ok: idxRedeem === stack.redeem,
    detail: idxRedeem,
  });

  const periodHour = await indexer.PERIOD_HOUR();
  checks.push({
    name: "rewardIndexer.PERIOD_HOUR",
    ok: Number(periodHour) === 0,
    detail: String(periodHour),
  });

  const marketHost = getAddress(await market.redeemHost());
  checks.push({
    name: "transferMarket.redeemHost",
    ok: marketHost === stack.redeem,
    detail: marketHost,
  });

  try {
    await redeem.resolveUnifiedIncomeStats.staticCall(probeWallet, "", 0);
    checks.push({ name: "redeem.resolveUnifiedIncomeStats", ok: true, detail: `callable @ ${probeWallet}` });
  } catch (e: unknown) {
    checks.push({
      name: "redeem.resolveUnifiedIncomeStats",
      ok: false,
      detail: (e as Error)?.message?.slice(0, 120) ?? String(e),
    });
  }

  for (const [label, addr] of Object.entries(stack)) {
    const verified = await blockscoutVerified(addr);
    checks.push({
      name: `blockscout verified (${label})`,
      ok: verified,
      detail: verified ? `${BLOCKSCOUT_UI}/address/${addr}#code` : "not verified",
    });
  }

  let failed = 0;
  console.log("Checks:");
  for (const c of checks) {
    const mark = c.ok ? "✅" : "❌";
    if (!c.ok) failed++;
    console.log(`  ${mark} ${c.name}: ${c.detail}`);
  }

  console.log("");
  if (failed) {
    console.error(`FAILED: ${failed} check(s)`);
    console.error("Fix: npx tsx scripts/verifyValidatorDepositRedeemStackConet.ts");
    process.exit(1);
  }
  console.log("ALL CHECKS PASSED");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
