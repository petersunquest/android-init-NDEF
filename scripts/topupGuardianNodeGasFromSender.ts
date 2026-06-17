/**
 * 从指定 EOA 向 apiv4 miningRate.nodeWallets（Guardian #100–#130）批量转原生 CONET gas。
 *
 * 用法:
 *   DRY_RUN=1 SENDER_PK=0x... npx tsx scripts/topupGuardianNodeGasFromSender.ts
 *   SENDER_PK=0x... TOPUP_ETH=0.1 NEW_RPC=https://publicrpc.conet.network \
 *     npx tsx scripts/topupGuardianNodeGasFromSender.ts
 *
 * 环境变量:
 *   SENDER_PK — 发送方私钥（可选；默认 ~/.master.json conet_seed_private_key）
 *   SENDER_ADDRESS — 期望发送地址（默认 0x098127…；仅用于校验 SENDER_PK）
 *   TOPUP_ETH — 每笔金额（默认 0.1）
 *   NEW_RPC — CoNET RPC（默认 https://publicrpc.conet.network）
 *   APIV4_MINING_RATE_URL — 收款人来源（默认 apiv4 miningRate?eposh=1）
 *   RECIPIENTS — 可选逗号分隔地址，覆盖 apiv4 列表
 *   SLEEP_MS — 每笔间隔（默认 1500）
 *   DRY_RUN — 1 时只预检不发交易
 */

import { ethers } from "ethers";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

const NEW_RPC = process.env.NEW_RPC || "https://publicrpc.conet.network";
const NEW_CHAIN = 224422n;
const DEFAULT_SENDER = "0x0981275553A41E00ec1006fe074971285E00c2A3";
const SENDER_ADDRESS = ethers.getAddress(process.env.SENDER_ADDRESS || DEFAULT_SENDER);
const TOPUP_ETH = process.env.TOPUP_ETH || "0.1";
const APIV4_MINING_RATE_URL =
  process.env.APIV4_MINING_RATE_URL || "https://apiv4.conet.network/api/miningRate?eposh=1";
const SLEEP_MS = Number(process.env.SLEEP_MS || "1500");
const DRY_RUN = process.env.DRY_RUN === "1" || process.env.DRY_RUN === "true";

function normalizePk(hex: string): string {
  const s = hex.trim();
  return s.startsWith("0x") ? s : `0x${s}`;
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

async function loadRecipients(): Promise<string[]> {
  const envList = process.env.RECIPIENTS?.split(",").map((a) => a.trim()).filter(Boolean);
  if (envList?.length) {
    return [...new Set(envList.map((a) => ethers.getAddress(a)))].sort();
  }

  const res = await fetch(APIV4_MINING_RATE_URL);
  if (!res.ok) throw new Error(`apiv4 miningRate HTTP ${res.status}`);
  const data = (await res.json()) as {
    nodeWallets?: Array<{ wallet?: string; ipAddr?: string } | string>;
  };
  const raw = data.nodeWallets ?? [];
  const wallets = raw
    .map((row) => (typeof row === "string" ? row : row.wallet))
    .filter((w): w is string => typeof w === "string" && w.length > 0)
    .map((w) => ethers.getAddress(w));
  if (!wallets.length) throw new Error("apiv4 nodeWallets 为空");
  return [...new Set(wallets)].sort();
}

function resolveSenderPk(): string {
  const envPk = process.env.SENDER_PK?.trim();
  if (envPk) return envPk;

  const masterPath = process.env.MASTER_JSON || path.join(os.homedir(), ".master.json");
  if (fs.existsSync(masterPath)) {
    const master = JSON.parse(fs.readFileSync(masterPath, "utf-8")) as Record<string, unknown>;
    const seed = master.conet_seed_private_key;
    if (typeof seed === "string" && seed.length > 0) {
      return seed.startsWith("0x") ? seed : `0x${seed}`;
    }
  }

  const file =
    process.env.DEPOSIT_SENDER_PRIVATE_KEY_FILE?.trim() ||
    path.join(os.homedir(), "ethereum-pos-mainnet", "secrets", "deposit_sender_private_key.txt");
  if (fs.existsSync(file)) {
    const line = fs.readFileSync(file, "utf-8").trim().split(/\s+/)[0];
    if (line) return line.startsWith("0x") ? line : `0x${line}`;
  }
  throw new Error(
    "缺少发送方私钥：设置 SENDER_PK，或在 ~/.master.json 配置 conet_seed_private_key，或提供 DEPOSIT_SENDER_PRIVATE_KEY_FILE。"
  );
}

async function main() {
  const pkRaw = resolveSenderPk();
  const pk = normalizePk(pkRaw);
  const wallet = new ethers.Wallet(pk);
  if (wallet.address.toLowerCase() !== SENDER_ADDRESS.toLowerCase()) {
    throw new Error(`SENDER_PK 地址 ${wallet.address} 与 SENDER_ADDRESS ${SENDER_ADDRESS} 不一致`);
  }

  const provider = new ethers.JsonRpcProvider(NEW_RPC);
  const net = await provider.getNetwork();
  if (net.chainId !== NEW_CHAIN) {
    throw new Error(`期望 chainId ${NEW_CHAIN}，当前 ${net.chainId}`);
  }

  const sender = wallet.connect(provider);
  const recipients = await loadRecipients();
  const topupWei = ethers.parseEther(TOPUP_ETH);
  const need = topupWei * BigInt(recipients.length);
  const balance = await provider.getBalance(sender.address);

  console.log("=".repeat(60));
  console.log("Guardian 节点 gas 批量投放");
  console.log("=".repeat(60));
  console.log("RPC:", NEW_RPC);
  console.log("from:", sender.address);
  console.log("balance:", ethers.formatEther(balance), "CONET");
  console.log("each:", TOPUP_ETH, "CONET ×", recipients.length, "=", ethers.formatEther(need), "CONET");
  console.log("DRY_RUN:", DRY_RUN);

  if (balance < need) {
    throw new Error(`余额不足: ${ethers.formatEther(balance)} < ${ethers.formatEther(need)}`);
  }

  const low: { addr: string; bal: string }[] = [];
  for (const addr of recipients) {
    const bal = await provider.getBalance(addr);
    if (bal < topupWei) low.push({ addr, bal: ethers.formatEther(bal) });
  }
  console.log("当前余额 <", TOPUP_ETH, "的节点:", low.length, "/", recipients.length);

  if (DRY_RUN) {
    console.log("\n[DRY_RUN] 将转账至:");
    for (const addr of recipients) {
      const bal = await provider.getBalance(addr);
      console.log(`  ${addr}  balance=${ethers.formatEther(bal)}`);
    }
    return;
  }

  let sent = 0;
  for (const to of recipients) {
    const before = await provider.getBalance(to);
    if (before >= topupWei) {
      console.log(`skip ${to} (already >= ${TOPUP_ETH})`);
      continue;
    }
    const tx = await sender.sendTransaction({ to, value: topupWei });
    const receipt = await tx.wait();
    sent++;
    console.log(`[${sent}/${recipients.length}] ${TOPUP_ETH} -> ${to} tx=${tx.hash} block=${receipt?.blockNumber}`);
    if (SLEEP_MS > 0 && sent < recipients.length) await sleep(SLEEP_MS);
  }
  console.log("done. sent:", sent);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
