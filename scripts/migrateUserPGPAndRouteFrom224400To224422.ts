/**
 * 将旧链 224400 AddressPGP 上用户的 PGP 与路由状态迁移到新链 224422 的 AddressPGP。
 *
 * 数据来源：旧合约 `_pgpKeys(to)` + `searchKey(to)`；上链：`addPublicPGPByAdmin`。
 * PGPKeySet / RouteSet 各有 331 条事件，唯一用户 **266** 个；每笔用户一条 `addPublicPGPByAdmin`。
 *
 * **并行模型**：待迁移任务进入 **等待队列**；从 `~/.master.json` 的 `initManager` + `ETH_Manager`
 * 去重得到最多 **16** 个 admin 私钥，启动 **16 个 worker**，各从队列 **pop** 一条记录，
 * 并行发交易（每 admin 独立 nonce，互不阻塞）。
 *
 * 224400 RPC: https://mainnet-rpc.conet.network
 * 224422 RPC: https://rpc1.conet.network
 *
 * 用法:
 *   DRY_RUN=1 npx tsx scripts/migrateUserPGPAndRouteFrom224400To224422.ts
 *   npx tsx scripts/migrateUserPGPAndRouteFrom224400To224422.ts
 *
 * 环境变量:
 *   LEGACY_RPC / NEW_RPC / OLD_ADDRESS_PGP / NEW_ADDRESS_PGP / GUARDIAN_NEW
 *   MASTER_JSON — 默认 ~/.master.json（读取 initManager、ETH_Manager 作为 worker 私钥池）
 *   WORKERS — 最大并行 worker 数（默认 16；实际不超过池中 admin 数量）
 *   START_INDEX / LIMIT — 对用户列表分页
 *   DRY_RUN — 只打印队列与 worker 分配，不发交易
 */

import { ethers } from "ethers";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const LEGACY_RPC = process.env.LEGACY_RPC || "https://mainnet-rpc.conet.network";
const NEW_RPC = process.env.NEW_RPC || "https://rpc1.conet.network";
const OLD_ADDRESS_PGP = process.env.OLD_ADDRESS_PGP || "0x13A96Bcd6aB010619d1004A1Cb4f5FE149e0F4c4";
const MASTER_JSON = process.env.MASTER_JSON || path.join(os.homedir(), ".master.json");

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
const GUARDIAN_NEW = process.env.GUARDIAN_NEW || "0xdE51f1daaCa6eae9BDeEe33E324c3e6e96837e94";

const LEGACY_CHAIN = 224400n;
const NEW_CHAIN = 224422n;

const DRY_RUN = process.env.DRY_RUN === "1" || process.env.DRY_RUN === "true";
const START_INDEX = Number(process.env.START_INDEX || "0");
const LIMIT = process.env.LIMIT === undefined ? undefined : Number(process.env.LIMIT);
const MAX_WORKERS = Math.max(1, Number(process.env.WORKERS || "16"));

const PgpEventIface = new ethers.Interface([
  "event PGPKeySet(address indexed to, string pgpKeyID)",
]);

const OldPgpABI = [
  "function _pgpKeys(address) view returns (string pgpKeyID, string publicKeyArmored, string encrypKeyArmored, bool exists)",
  "function searchKey(address to) view returns (string userPgpKeyID, string userPublicKeyArmored, string routePgpKeyID, string routePublicKeyArmored, bool routeOnline)",
];

const NewPgpABI = [
  "function addPublicPGPByAdmin(address to, string pgpKeyID, string publicKeyArmored, string encrypKeyArmored, string routePgpKeyID) external",
  "function _pgpKeys(address) view returns (string pgpKeyID, string publicKeyArmored, string encrypKeyArmored, bool exists)",
  "function adminList(address) view returns (bool)",
];

const GuardianABI = ["function getPGPKeyIPaddress(string memory pgpKey) view returns (string memory ipaddress)"];

type MasterJson = {
  initManager?: string[];
  ETH_Manager?: string[];
};

type MigrationJob = {
  user: string;
  pgpKeyID: string;
  publicKeyArmored: string;
  encrypKeyArmored: string;
  routeForTx: string;
};

function normalizePk(hex: string): string {
  const s = hex.trim();
  return s.startsWith("0x") ? s : `0x${s}`;
}

/** initManager + ETH_Manager 去重（按地址），排序后返回私钥列表（CoNET-DL 与 addCoNETDLRouterAdmins 一致） */
function loadCoNETDLAdminPrivateKeys(): string[] {
  if (!fs.existsSync(MASTER_JSON)) {
    throw new Error(`未找到 ${MASTER_JSON}`);
  }
  const raw = JSON.parse(fs.readFileSync(MASTER_JSON, "utf-8")) as MasterJson;
  const combined = [...(raw.initManager ?? []), ...(raw.ETH_Manager ?? [])];
  if (!combined.length) {
    throw new Error(`${MASTER_JSON} 中未找到 initManager / ETH_Manager`);
  }
  const byAddr = new Map<string, string>();
  for (const pk of combined) {
    if (!pk || typeof pk !== "string") continue;
    try {
      const k = normalizePk(pk);
      const addr = new ethers.Wallet(k).address.toLowerCase();
      if (!byAddr.has(addr)) byAddr.set(addr, k);
    } catch {
      /* skip */
    }
  }
  return [...byAddr.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([, k]) => k);
}

async function uniqueUsersFromPGPKeySet(
  legacyProvider: ethers.JsonRpcProvider,
  oldAddr: string
): Promise<string[]> {
  const latest = await legacyProvider.getBlockNumber();
  const topic = PgpEventIface.getEvent("PGPKeySet")!.topicHash;
  const logs = await legacyProvider.getLogs({
    address: oldAddr,
    fromBlock: 0,
    toBlock: latest,
    topics: [topic],
  });
  const set = new Set<string>();
  for (const log of logs) {
    const parsed = PgpEventIface.parseLog({
      topics: log.topics as string[],
      data: log.data,
    });
    set.add((parsed.args[0] as string).toLowerCase());
  }
  return [...set].sort();
}

async function main() {
  const legacyProvider = new ethers.JsonRpcProvider(LEGACY_RPC);
  const newProvider = new ethers.JsonRpcProvider(NEW_RPC);

  const [legacyId, newId] = await Promise.all([legacyProvider.getNetwork(), newProvider.getNetwork()]);
  if (legacyId.chainId !== LEGACY_CHAIN) {
    throw new Error(`LEGACY_RPC 期望 chainId ${LEGACY_CHAIN}，当前 ${legacyId.chainId}`);
  }
  if (newId.chainId !== NEW_CHAIN) {
    throw new Error(`NEW_RPC 期望 chainId ${NEW_CHAIN}，当前 ${newId.chainId}`);
  }

  const oldPgp = new ethers.Contract(OLD_ADDRESS_PGP, OldPgpABI, legacyProvider);
  const guardianNew = new ethers.Contract(GUARDIAN_NEW, GuardianABI, newProvider);
  const newPgpRead = new ethers.Contract(NEW_ADDRESS_PGP, NewPgpABI, newProvider);

  const adminKeys = loadCoNETDLAdminPrivateKeys();
  const workerCount = Math.min(MAX_WORKERS, adminKeys.length);
  const workerKeys = adminKeys.slice(0, workerCount);

  const allUsers = await uniqueUsersFromPGPKeySet(legacyProvider, OLD_ADDRESS_PGP);
  const slice = allUsers.slice(START_INDEX, LIMIT === undefined ? undefined : START_INDEX + LIMIT);

  console.log("=".repeat(60));
  console.log("用户 PGP + 路由迁移: 224400 → 224422（等待队列 + 并行 admin）");
  console.log("=".repeat(60));
  console.log("LEGACY_RPC:", LEGACY_RPC);
  console.log("NEW_RPC:", NEW_RPC);
  console.log("旧 AddressPGP:", OLD_ADDRESS_PGP);
  console.log("新 AddressPGP:", NEW_ADDRESS_PGP);
  console.log("MASTER_JSON:", MASTER_JSON);
  console.log("admin 私钥池（去重）:", adminKeys.length, "使用 worker 数:", workerKeys.length);
  console.log("PGPKeySet 唯一用户:", allUsers.length, "本批 slice:", slice.length);
  console.log("DRY_RUN:", DRY_RUN);
  console.log();

  let skipNoOld = 0;
  let skipNewExists = 0;
  let routeClearedForGuardian = 0;

  /** 等待队列：先入队全部待迁移任务，再由各 worker 并行 shift pop */
  const waitQueue: MigrationJob[] = [];

  for (const user of slice) {
    const row = await oldPgp._pgpKeys(user);
    if (!row.exists) {
      skipNoOld++;
      continue;
    }

    const newRow = await newPgpRead._pgpKeys(user);
    if (newRow.exists) {
      skipNewExists++;
      continue;
    }

    const sk = await oldPgp.searchKey(user);
    let routeForTx = ((sk[2] as string) || "").trim();
    if (routeForTx.length > 0) {
      const ip = await guardianNew.getPGPKeyIPaddress(routeForTx);
      if (!ip || String(ip).trim().length === 0) {
        routeClearedForGuardian++;
        routeForTx = "";
      }
    }

    waitQueue.push({
      user: ethers.getAddress(user),
      pgpKeyID: row.pgpKeyID,
      publicKeyArmored: row.publicKeyArmored,
      encrypKeyArmored: row.encrypKeyArmored,
      routeForTx,
    });
  }

  console.log("阶段1 扫描完成 — 入队:", waitQueue.length);
  console.log("跳过 旧链无 PGP:", skipNoOld);
  console.log("跳过 新链已存在:", skipNewExists);
  console.log("路由因新 Guardian 无记录置空:", routeClearedForGuardian);
  console.log();

  if (!waitQueue.length) {
    console.log("队列为空，结束。");
    return;
  }

  if (DRY_RUN) {
    waitQueue.forEach((job, i) => {
      const wid = i % workerKeys.length;
      const w = new ethers.Wallet(workerKeys[wid]!);
      console.log(
        `[DRY_RUN][W${wid}] ${w.address.slice(0, 10)}… → ${job.user} route=${job.routeForTx || "(empty)"}`
      );
    });
    console.log("\n[DRY_RUN] 未发交易");
    return;
  }

  for (let w = 0; w < workerKeys.length; w++) {
    const wallet = new ethers.Wallet(workerKeys[w]!, newProvider);
    const ok = await newPgpRead.adminList(wallet.address);
    if (!ok) {
      throw new Error(`Worker ${w} ${wallet.address} 不是新 AddressPGP admin，请先执行 addCoNETDLRouterAdminsToAddressPGP`);
    }
  }

  let done = 0;
  let failed = 0;
  let txSeq = 0;

  async function worker(workerId: number, pk: string) {
    const wallet = new ethers.Wallet(pk, newProvider);
    const c = new ethers.Contract(NEW_ADDRESS_PGP, NewPgpABI, wallet);

    for (;;) {
      const job = waitQueue.shift();
      if (!job) break;

      try {
        const tx = await c.addPublicPGPByAdmin(
          job.user,
          job.pgpKeyID,
          job.publicKeyArmored,
          job.encrypKeyArmored,
          job.routeForTx
        );
        const num = ++txSeq;
        console.log(`[W${workerId}] [${num}] ${job.user} tx ${tx.hash}`);
        await tx.wait();
        console.log(`[W${workerId}]   ✅`);
        done++;
      } catch (e: unknown) {
        failed++;
        console.error(`[W${workerId}] FAIL ${job.user}`, e instanceof Error ? e.message : e);
      }
    }
  }

  console.log("阶段2 启动", workerKeys.length, "个 worker 并行 pop 等待队列…\n");
  await Promise.all(workerKeys.map((pk, i) => worker(i, pk)));

  console.log();
  console.log("完成。成功:", done, "失败:", failed);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
