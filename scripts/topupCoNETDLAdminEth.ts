/**
 * 检查 CoNET-DL / x402sdk cluster 在 CoNET(224422) 上发起交易的所有钱包地址余额；
 * 对「余额不足」的地址，由部署 admin 各向该地址转账 TOPUP_ETH（默认 5 ETH）。
 *
 * 覆盖的 ~/.master.json 字段：
 *   - initManager[]            （ConetPGP addRoutes / batch ETH airdrop）
 *   - ETH_Manager[]            （batch ETH 兜底）
 *   - epochManagre             （updateEpochToSC）
 *   - GB_airdrop               （eGB airdrop）
 *   - settle_contractAdmin[]   （x402sdk cluster：claimBUnits / purchaseCard / consumeFromUser /
 *                                 settleBeamioX402 / requestAccounting / OpenContainerRelay 等
 *                                 走 SC.walletConet 发出的全部 CoNET 链交易）
 *   - beamio_Admins[]          （x402sdk db.ts 的 followByAdmin / setNameHashBase64 /
 *                                 addPublicPGPByAdmin / addRoute / setBuintFee 等）
 *
 * 必须覆盖 settle_contractAdmin / beamio_Admins —— 否则 chain restart 后这两类钱包
 * 余额为 0，会出现：
 *   [claimBUnitsProcess] failed: insufficient funds for intrinsic transaction cost
 *   [followByAdmin] insufficient funds ...
 * 只有部分用户/部分请求随机失败（取决于 cluster 命中哪个 worker / 哪个 admin）。
 *
 * 不足判定：balance < MIN_BALANCE_ETH（默认 5，即低于 5 ETH 视为不足）
 * 强制模式：FORCE_TOPUP=1 时跳过阈值过滤，对所有地址各转 TOPUP_ETH。
 *
 * 用法:
 *   DRY_RUN=1 npx tsx scripts/topupCoNETDLAdminEth.ts
 *   npx tsx scripts/topupCoNETDLAdminEth.ts
 *   # 一次性给所有相关钱包各打 1 ETH（不看余额）：
 *   FORCE_TOPUP=1 TOPUP_ETH=1 npx tsx scripts/topupCoNETDLAdminEth.ts
 *
 * 环境变量:
 *   MIN_BALANCE_ETH — 低于此值视为不足（默认 5）
 *   TOPUP_ETH — 每笔转账数量（默认 5）
 *   FORCE_TOPUP — 1/true 时跳过阈值，无条件给所有地址各转 TOPUP_ETH
 *   MASTER_JSON / DEPLOYMENT_JSON / NEW_RPC — 与 addCoNETDLRouterAdminsToAddressPGP.ts 相同
 */

import { ethers } from "ethers";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const NEW_RPC = process.env.NEW_RPC || "https://rpc1.conet.network";
const NEW_CHAIN = 224422n;
const MASTER_JSON = process.env.MASTER_JSON || path.join(os.homedir(), ".master.json");
const DEPLOYMENT_JSON =
  process.env.DEPLOYMENT_JSON || path.join(__dirname, "..", "deployments", "conet-AddressPGP.json");
const DRY_RUN = process.env.DRY_RUN === "1" || process.env.DRY_RUN === "true";
const SLEEP_MS = Number(process.env.SLEEP_MS || "2000");

const MIN_BALANCE_ETH = process.env.MIN_BALANCE_ETH || "5";
const TOPUP_ETH = process.env.TOPUP_ETH || "5";
const FORCE_TOPUP = process.env.FORCE_TOPUP === "1" || process.env.FORCE_TOPUP === "true";

type MasterJson = {
  initManager?: string[];
  ETH_Manager?: string[];
  epochManagre?: string;
  GB_airdrop?: string;
  settle_contractAdmin?: string[];
  beamio_Admins?: string[];
  admin?: string[];
};

function readConetDeployPrivateKeys(masterPath: string): string[] {
  const master = JSON.parse(fs.readFileSync(masterPath, "utf-8")) as MasterJson;
  const settle = Array.isArray(master.settle_contractAdmin) ? master.settle_contractAdmin : [];
  const beamio = Array.isArray(master.beamio_Admins) ? master.beamio_Admins : [];
  const extra = Array.isArray(master.admin) ? master.admin : [];
  const raw: string[] = [...settle, ...beamio, ...extra];
  const keys = raw
    .filter((k): k is string => typeof k === "string" && k.length > 0)
    .map((k) => (k.startsWith("0x") ? k : `0x${k}`));
  return [...new Set(keys)];
}

function findPrivateKeyForAddress(masterPath: string, targetAddress: string): string | null {
  const want = targetAddress.toLowerCase();
  for (const pk of readConetDeployPrivateKeys(masterPath)) {
    try {
      if (new ethers.Wallet(pk).address.toLowerCase() === want) return pk;
    } catch {
      /* skip */
    }
  }
  return null;
}

function loadDeployerPk(): string {
  const env = process.env.ADDRESS_PGP_ADMIN_PK;
  if (env) return env.trim();
  if (!fs.existsSync(MASTER_JSON)) throw new Error(`未找到 ${MASTER_JSON}`);
  if (fs.existsSync(DEPLOYMENT_JSON)) {
    const dep = JSON.parse(fs.readFileSync(DEPLOYMENT_JSON, "utf-8")) as { deployer?: string };
    if (dep.deployer) {
      const pk = findPrivateKeyForAddress(MASTER_JSON, dep.deployer);
      if (pk) return pk;
    }
  }
  const d = JSON.parse(fs.readFileSync(MASTER_JSON, "utf-8")) as MasterJson;
  const admins = d.beamio_Admins || d.settle_contractAdmin || [];
  if (admins[0]) return admins[0].startsWith("0x") ? admins[0] : `0x${admins[0]}`;
  throw new Error("无法解析部署 admin 私钥");
}

function normalizePk(hex: string): string {
  const s = hex.trim();
  return s.startsWith("0x") ? s : `0x${s}`;
}

function pkToAddress(pk: string): string {
  return new ethers.Wallet(normalizePk(pk)).address;
}

type ManagerEntry = { source: string; address: string };

function loadCoNETDLManagerAddresses(): ManagerEntry[] {
  if (!fs.existsSync(MASTER_JSON)) throw new Error(`未找到 ${MASTER_JSON}`);
  const raw = JSON.parse(fs.readFileSync(MASTER_JSON, "utf-8")) as MasterJson;

  const buckets: { source: string; pks: string[] }[] = [
    { source: "initManager", pks: Array.isArray(raw.initManager) ? raw.initManager : [] },
    { source: "ETH_Manager", pks: Array.isArray(raw.ETH_Manager) ? raw.ETH_Manager : [] },
    { source: "epochManagre", pks: typeof raw.epochManagre === "string" && raw.epochManagre ? [raw.epochManagre] : [] },
    { source: "GB_airdrop", pks: typeof raw.GB_airdrop === "string" && raw.GB_airdrop ? [raw.GB_airdrop] : [] },
    // x402sdk cluster：claimBUnits / purchaseCard / consumeFromUser / requestAccounting 等
    // 全部走 SC.walletConet (private key 来自 settle_contractAdmin) 发交易，CoNET 链上必须有 gas。
    { source: "settle_contractAdmin", pks: Array.isArray(raw.settle_contractAdmin) ? raw.settle_contractAdmin : [] },
    // x402sdk db.ts: followByAdmin / setNameHashBase64 / addPublicPGPByAdmin / addRoute 等。
    { source: "beamio_Admins", pks: Array.isArray(raw.beamio_Admins) ? raw.beamio_Admins : [] },
  ];

  const total = buckets.reduce((n, b) => n + b.pks.length, 0);
  if (!total) {
    throw new Error(
      `${MASTER_JSON} 中未找到 initManager / ETH_Manager / epochManagre / GB_airdrop / settle_contractAdmin / beamio_Admins`
    );
  }

  const seen = new Map<string, ManagerEntry>();
  for (const { source, pks } of buckets) {
    for (const pk of pks) {
      if (!pk || typeof pk !== "string") continue;
      try {
        const addr = ethers.getAddress(pkToAddress(pk));
        const key = addr.toLowerCase();
        const existing = seen.get(key);
        if (existing) {
          existing.source += `, ${source}`;
        } else {
          seen.set(key, { source, address: addr });
        }
      } catch {
        /* skip */
      }
    }
  }
  return [...seen.values()].sort((a, b) => a.address.localeCompare(b.address));
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

async function main() {
  const provider = new ethers.JsonRpcProvider(NEW_RPC);
  const net = await provider.getNetwork();
  if (net.chainId !== NEW_CHAIN) {
    throw new Error(`期望 chainId ${NEW_CHAIN}，当前 ${net.chainId}`);
  }

  const minWei = ethers.parseEther(MIN_BALANCE_ETH);
  const topupWei = ethers.parseEther(TOPUP_ETH);

  const targets = loadCoNETDLManagerAddresses();

  console.log("=".repeat(60));
  console.log("CoNET-DL 224422 钱包余额检查 / TOPUP");
  console.log("=".repeat(60));
  console.log("RPC:", NEW_RPC);
  console.log("地址数:", targets.length);
  console.log("不足阈值: <", MIN_BALANCE_ETH, "ETH");
  console.log("单笔转账:", TOPUP_ETH, "ETH");
  console.log("FORCE_TOPUP:", FORCE_TOPUP);
  console.log("DRY_RUN:", DRY_RUN);
  console.log();

  const rows: { addr: string; source: string; wei: bigint; eth: string }[] = [];
  for (const t of targets) {
    const wei = await provider.getBalance(t.address);
    rows.push({ addr: t.address, source: t.source, wei, eth: ethers.formatEther(wei) });
  }

  console.log("全部地址余额:");
  for (const r of rows) {
    console.log(`  [${r.source}] ${r.addr}  ${r.eth} ETH`);
  }
  console.log();

  const todo = FORCE_TOPUP ? rows : rows.filter((r) => r.wei < minWei);

  if (FORCE_TOPUP) {
    console.log(`FORCE_TOPUP=1 → 将给全部 ${todo.length} 个地址各转 ${TOPUP_ETH} ETH`);
  } else {
    console.log("余额不足（< " + MIN_BALANCE_ETH + " ETH）:", todo.length, "个");
  }
  for (const r of todo) {
    console.log(`  [${r.source}] ${r.addr}  ${r.eth} ETH`);
  }
  console.log();

  if (!todo.length) {
    console.log("无需转账。");
    return;
  }

  const totalNeeded = topupWei * BigInt(todo.length);
  const signer = new ethers.Wallet(loadDeployerPk(), provider);
  const deployBal = await provider.getBalance(signer.address);
  console.log("部署 admin 签名:", signer.address);
  console.log("部署 admin 余额:", ethers.formatEther(deployBal), "ETH");
  console.log("本次约需转出:", ethers.formatEther(totalNeeded), "ETH (+ gas)");
  if (deployBal < totalNeeded) {
    throw new Error("部署 admin 余额不足以完成全部转账");
  }

  if (DRY_RUN) {
    console.log("[DRY_RUN] 未发送交易");
    return;
  }

  for (let i = 0; i < todo.length; i++) {
    const r = todo[i]!;
    const tx = await signer.sendTransaction({ to: r.addr, value: topupWei });
    console.log(`[${i + 1}/${todo.length}] [${r.source}] ${r.addr} tx ${tx.hash}`);
    await tx.wait();
    console.log("  done");
    if (i < todo.length - 1) await sleep(SLEEP_MS);
  }

  console.log("\n完成。");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
