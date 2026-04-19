/**
 * 检查 CoNET-DL initManager+ETH_Manager 对应 16 个地址在 CoNET(224422) 上的原生余额；
 * 对「余额不足」的地址，由部署 admin 各向该地址转账 TOPUP_ETH（默认 5 ETH）。
 *
 * 不足判定：balance < MIN_BALANCE_ETH（默认 5，即低于 5 ETH 视为不足）
 *
 * 用法:
 *   DRY_RUN=1 npx tsx scripts/topupCoNETDLAdminEth.ts
 *   npx tsx scripts/topupCoNETDLAdminEth.ts
 *
 * 环境变量:
 *   MIN_BALANCE_ETH — 低于此值视为不足（默认 5）
 *   TOPUP_ETH — 每笔转账数量（默认 5）
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

type MasterJson = {
  initManager?: string[];
  ETH_Manager?: string[];
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

function loadCoNETDLManagerAddresses(): string[] {
  if (!fs.existsSync(MASTER_JSON)) throw new Error(`未找到 ${MASTER_JSON}`);
  const raw = JSON.parse(fs.readFileSync(MASTER_JSON, "utf-8")) as MasterJson;
  const combined = [...(raw.initManager ?? []), ...(raw.ETH_Manager ?? [])];
  if (!combined.length) throw new Error(`${MASTER_JSON} 中未找到 initManager / ETH_Manager`);
  const set = new Set<string>();
  for (const pk of combined) {
    if (!pk || typeof pk !== "string") continue;
    try {
      set.add(pkToAddress(pk).toLowerCase());
    } catch {
      /* skip */
    }
  }
  return [...set].sort();
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

  const targets = loadCoNETDLManagerAddresses().map((a) => ethers.getAddress(a));

  console.log("=".repeat(60));
  console.log("CoNET-DL admin 地址余额检查 / 不足则 TOPUP");
  console.log("=".repeat(60));
  console.log("RPC:", NEW_RPC);
  console.log("地址数:", targets.length);
  console.log("不足阈值: <", MIN_BALANCE_ETH, "ETH");
  console.log("单笔转账:", TOPUP_ETH, "ETH");
  console.log("DRY_RUN:", DRY_RUN);
  console.log();

  const rows: { addr: string; wei: bigint; eth: string }[] = [];
  for (const addr of targets) {
    const wei = await provider.getBalance(addr);
    rows.push({ addr, wei, eth: ethers.formatEther(wei) });
  }

  const insufficient = rows.filter((r) => r.wei < minWei);

  console.log("全部地址余额:");
  for (const r of rows) {
    console.log(`  ${r.addr}  ${r.eth} ETH`);
  }
  console.log();
  console.log("余额不足（< " + MIN_BALANCE_ETH + " ETH）:", insufficient.length, "个");
  for (const r of insufficient) {
    console.log(`  ${r.addr}  ${r.eth} ETH`);
  }
  console.log();

  if (!insufficient.length) {
    console.log("无需转账。");
    return;
  }

  const totalNeeded = topupWei * BigInt(insufficient.length);
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

  for (let i = 0; i < insufficient.length; i++) {
    const to = insufficient[i]!.addr;
    const tx = await signer.sendTransaction({ to, value: topupWei });
    console.log(`[${i + 1}/${insufficient.length}] ${to} tx ${tx.hash}`);
    await tx.wait();
    console.log("  ✅");
    if (i < insufficient.length - 1) await sleep(SLEEP_MS);
  }

  console.log("\n完成。");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
