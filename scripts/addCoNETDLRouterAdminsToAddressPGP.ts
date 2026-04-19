/**
 * 将 CoNET-DL 中用于自动登记 router（CoNETPGP / AddressPGP）的私钥池对应地址，
 * 加入新链 224422 上 AddressPGP 合约的 adminList。
 *
 * 与源码对应关系（masterSetup 来自 ~/.master.json，与 src/CoNET-DL/src/util/util.ts 一致）：
 * - masterSetup.initManager — serverV4forMinerTotal.ts 中 managerSC_Pool（addRoute / addRoutes）
 * - masterSetup.ETH_Manager — layerMinusClient_data.ts 中 managerSC_Pool
 *
 * 合并去重后，对尚未为 admin 的地址各发一笔 changeAddressInAdminlist(addr, true)。
 *
 * 用法:
 *   DRY_RUN=1 npx tsx scripts/addCoNETDLRouterAdminsToAddressPGP.ts
 *   npx tsx scripts/addCoNETDLRouterAdminsToAddressPGP.ts
 *
 * 环境变量:
 *   MASTER_JSON — 默认 ~/.master.json
 *   NEW_RPC — 默认 https://rpc1.conet.network
 *   NEW_ADDRESS_PGP — 默认 deployments/conet-AddressPGP.json
 *   DEPLOYMENT_JSON — 含 deployer 字段的部署记录（默认 deployments/conet-AddressPGP.json），用于匹配「部署 admin」私钥
 *   ADDRESS_PGP_ADMIN_PK — 显式覆盖签名私钥（若设置则优先于部署 admin）
 *   SLEEP_MS — 默认 1500
 *   EXTRA_ADDRESSES — 逗号分隔额外地址（可选）
 *
 * 签名者选择（非 DRY_RUN，与 hardhat.config.ts conet 账户来源一致）:
 *   1) ADDRESS_PGP_ADMIN_PK
 *   2) 在 MASTER_JSON 的 settle_contractAdmin + beamio_Admins + admin 合并去重列表中，
 *      找出地址等于 DEPLOYMENT_JSON.deployer 的私钥（即合约部署者，constructor 后即为 admin）
 *   3) 否则回退 beamio_Admins[0] / settle_contractAdmin[0]
 */

import { ethers } from "ethers";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const NEW_RPC = process.env.NEW_RPC || "https://rpc1.conet.network";
const NEW_CHAIN = 224422n;

const NEW_ADDRESS_PGP =
  process.env.NEW_ADDRESS_PGP ||
  (() => {
    const p = path.join(__dirname, "..", "deployments", "conet-AddressPGP.json");
    if (fs.existsSync(p)) {
      const j = JSON.parse(fs.readFileSync(p, "utf-8")) as { AddressPGP?: string };
      if (j.AddressPGP) return j.AddressPGP;
    }
    return "0x9C94238945295146F3F572D77ae492C13DF90bDd";
  })();

const MASTER_JSON = process.env.MASTER_JSON || path.join(os.homedir(), ".master.json");
const DEPLOYMENT_JSON =
  process.env.DEPLOYMENT_JSON || path.join(__dirname, "..", "deployments", "conet-AddressPGP.json");
const DRY_RUN = process.env.DRY_RUN === "1" || process.env.DRY_RUN === "true";
const SLEEP_MS = Number(process.env.SLEEP_MS || "1500");

const AddressPGPABI = [
  "function adminList(address) view returns (bool)",
  "function changeAddressInAdminlist(address addr, bool status) external",
];

type MasterJson = {
  initManager?: string[];
  ETH_Manager?: string[];
  settle_contractAdmin?: string[];
  beamio_Admins?: string[];
  admin?: string[];
};

/** 与 hardhat.config.ts getConetAccounts 相同顺序：settle → beamio_Admins → admin，去重 */
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

function loadAdminPk(): { pk: string; source: "env" | "deployer" | "fallback" } {
  const env = process.env.ADDRESS_PGP_ADMIN_PK;
  if (env) return { pk: env.trim(), source: "env" };

  if (!fs.existsSync(MASTER_JSON)) {
    throw new Error(`未找到 ${MASTER_JSON}`);
  }

  if (fs.existsSync(DEPLOYMENT_JSON)) {
    const dep = JSON.parse(fs.readFileSync(DEPLOYMENT_JSON, "utf-8")) as { deployer?: string };
    if (dep.deployer) {
      const pk = findPrivateKeyForAddress(MASTER_JSON, dep.deployer);
      if (pk) return { pk, source: "deployer" };
    }
  }

  const d = JSON.parse(fs.readFileSync(MASTER_JSON, "utf-8")) as MasterJson;
  const admins = d.beamio_Admins || d.settle_contractAdmin || [];
  if (admins[0]) {
    const pk = admins[0].startsWith("0x") ? admins[0] : `0x${admins[0]}`;
    return { pk, source: "fallback" };
  }
  throw new Error(
    "无法解析签名私钥：请设置 ADDRESS_PGP_ADMIN_PK，或在 MASTER_JSON 中配置与 DEPLOYMENT_JSON.deployer 匹配的私钥，或 beamio_Admins/settle_contractAdmin"
  );
}

function normalizePk(hex: string): string {
  const s = hex.trim();
  return s.startsWith("0x") ? s : `0x${s}`;
}

function pkToAddress(pk: string): string {
  return new ethers.Wallet(normalizePk(pk)).address;
}

function loadCoNETDLManagerAddresses(): string[] {
  if (!fs.existsSync(MASTER_JSON)) {
    throw new Error(`未找到 ${MASTER_JSON}（与 CoNET-DL masterSetup 同源）`);
  }
  const raw = JSON.parse(fs.readFileSync(MASTER_JSON, "utf-8")) as MasterJson;
  const init = raw.initManager ?? [];
  const eth = raw.ETH_Manager ?? [];
  const combined = [...init, ...eth];
  if (!combined.length) {
    throw new Error(`${MASTER_JSON} 中未找到 initManager / ETH_Manager 数组`);
  }
  const set = new Set<string>();
  for (const pk of combined) {
    if (!pk || typeof pk !== "string") continue;
    try {
      set.add(pkToAddress(pk).toLowerCase());
    } catch {
      /* skip invalid */
    }
  }
  return [...set].sort();
}

function parseExtraAddresses(): string[] {
  const raw = process.env.EXTRA_ADDRESSES?.trim();
  if (!raw) return [];
  return raw
    .split(",")
    .map((a) => a.trim())
    .filter(Boolean)
    .map((a) => ethers.getAddress(a));
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

  const dlAddresses = loadCoNETDLManagerAddresses();
  const extra = parseExtraAddresses();
  const allSet = new Set<string>();
  for (const a of dlAddresses) allSet.add(a.toLowerCase());
  for (const a of extra) allSet.add(a.toLowerCase());
  const allTargets = [...allSet].sort();

  const pgpRead = new ethers.Contract(NEW_ADDRESS_PGP, AddressPGPABI, provider);

  console.log("=".repeat(60));
  console.log("CoNET-DL router 管理地址 → AddressPGP adminList");
  console.log("=".repeat(60));
  console.log("MASTER_JSON:", MASTER_JSON);
  console.log("DEPLOYMENT_JSON:", DEPLOYMENT_JSON);
  console.log("NEW_RPC:", NEW_RPC);
  console.log("AddressPGP:", NEW_ADDRESS_PGP);
  console.log("来自 initManager+ETH_Manager 去重地址数:", dlAddresses.length);
  console.log("额外 EXTRA_ADDRESSES 数:", extra.length);
  console.log("合并后待检查:", allTargets.length);
  console.log("DRY_RUN:", DRY_RUN);
  console.log();

  const toGrant: string[] = [];
  for (const addr of allTargets) {
    const ok = await pgpRead.adminList(addr);
    if (!ok) {
      toGrant.push(ethers.getAddress(addr));
    }
  }

  console.log("已是 admin（跳过）:", allTargets.length - toGrant.length);
  console.log("需新增 admin:", toGrant.length);
  if (toGrant.length) {
    console.log("地址列表:");
    for (const a of toGrant) console.log(" ", a);
  }
  console.log();

  if (!toGrant.length) {
    console.log("无需发送交易。");
    return;
  }

  if (DRY_RUN) {
    try {
      const { pk, source } = loadAdminPk();
      const w = new ethers.Wallet(pk);
      const sourceLabel =
        source === "env"
          ? "ADDRESS_PGP_ADMIN_PK"
          : source === "deployer"
            ? `deployer（${path.basename(DEPLOYMENT_JSON)}）`
            : "beamio_Admins/settle_contractAdmin[0]";
      console.log("[DRY_RUN] 将使用的 Signer:", w.address, "|", sourceLabel);
    } catch (e: unknown) {
      console.log("[DRY_RUN] 无法解析签名私钥（正式运行前请配置）:", e instanceof Error ? e.message : e);
    }
    console.log("[DRY_RUN] 未发送 changeAddressInAdminlist");
    return;
  }

  const { pk, source } = loadAdminPk();
  const signer = new ethers.Wallet(pk, provider);
  const pgpWrite = new ethers.Contract(NEW_ADDRESS_PGP, AddressPGPABI, signer);

  if (!(await pgpRead.adminList(signer.address))) {
    throw new Error(`Signer ${signer.address} 不是当前 AddressPGP admin`);
  }
  const sourceLabel =
    source === "env"
      ? "ADDRESS_PGP_ADMIN_PK"
      : source === "deployer"
        ? `deployer（${DEPLOYMENT_JSON}）`
        : "beamio_Admins/settle_contractAdmin[0]";
  console.log("Signer:", signer.address, "| 私钥来源:", sourceLabel);

  for (let i = 0; i < toGrant.length; i++) {
    const addr = toGrant[i]!;
    const tx = await pgpWrite.changeAddressInAdminlist(addr, true);
    console.log(`[${i + 1}/${toGrant.length}] ${addr} tx ${tx.hash}`);
    await tx.wait();
    console.log("  ✅");
    if (i < toGrant.length - 1) await sleep(SLEEP_MS);
  }

  console.log("\n完成。");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
