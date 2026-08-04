/**
 * 审计并修复 AddressPGP 上 Guardian 节点的 domain↔wallet 绑定。
 *
 * 根因：历史 addRoutes 时 Guardian `ipaddress2owner` 曾错成同一幽灵地址（如 0xb055…），
 * 导致 SI `isMyRoute`（`nodeWallet2KeyHash(本机钱包) === userRouteHash`）永久失败。
 *
 * 修复：对每个 IP 再调 `addRoutes`，从**当前** Guardian 读取正确 owner + PGP 重写绑定。
 *
 * 用法:
 *   DRY_RUN=1 npx tsx scripts/repairAddressPgpNodeWalletBindings.ts
 *   npx tsx scripts/repairAddressPgpNodeWalletBindings.ts
 *   ONLY_BROKEN=1 npx tsx scripts/repairAddressPgpNodeWalletBindings.ts   # 仅提交坏绑
 *   NFT_MIN=100 NFT_MAX=571 BATCH_SIZE=25 npx tsx ...
 *
 * Env:
 *   CONET_RPC / ADDRESS_PGP / GUARDIAN_NODES
 *   ADDRESS_PGP_ADMIN_PK 或 ~/.master.json settle_contractAdmin[0]
 *   MINING_RATE_URL — 默认 https://apiv4.conet.network/api/miningRate（交叉校验，不参与写链）
 *   OUT_JSON — 审计报告路径
 */

import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");

const RPC =
  process.env.CONET_RPC || process.env.NEW_RPC || "https://rpc1.conet.network";

const ADDRESS_PGP =
  process.env.ADDRESS_PGP ||
  (() => {
    const p = path.join(ROOT, "deployments", "conet-AddressPGP.json");
    if (fs.existsSync(p)) {
      const j = JSON.parse(fs.readFileSync(p, "utf-8")) as { AddressPGP?: string };
      if (j.AddressPGP) return j.AddressPGP;
    }
    return "0x684b0ac760cEE9c9b85de36d69746420648Cf9e2";
  })();

const GUARDIAN_NODES =
  process.env.GUARDIAN_NODES ||
  (() => {
    const p = path.join(ROOT, "deployments", "conet-AddressPGP.json");
    if (fs.existsSync(p)) {
      const j = JSON.parse(fs.readFileSync(p, "utf-8")) as {
        guardianNodesInfoV6?: string;
      };
      if (j.guardianNodesInfoV6) return j.guardianNodesInfoV6;
    }
    const a = path.join(ROOT, "deployments", "conet-addresses.json");
    if (fs.existsSync(a)) {
      const j = JSON.parse(fs.readFileSync(a, "utf-8")) as {
        GuardianNodesInfoV6?: string;
      };
      if (j.GuardianNodesInfoV6) return j.GuardianNodesInfoV6;
    }
    return "0xBC6b53065b5647261396d002bDBA0d3396E0722f";
  })();

const NFT_MIN = Number(process.env.NFT_MIN || "100");
const NFT_MAX = Number(process.env.NFT_MAX || "571");
const BATCH_SIZE = Math.max(1, Number(process.env.BATCH_SIZE || "25"));
const DRY_RUN = process.env.DRY_RUN === "1" || process.env.DRY_RUN === "true";
const ONLY_BROKEN =
  process.env.ONLY_BROKEN === "1" || process.env.ONLY_BROKEN === "true";
const MINING_RATE_URL =
  process.env.MINING_RATE_URL || "https://apiv4.conet.network/api/miningRate";
const OUT_JSON =
  process.env.OUT_JSON ||
  path.join(ROOT, "deployments", "addresspgp-node-wallet-repair-report.json");
const CONCURRENCY = Math.max(1, Number(process.env.CONCURRENCY || "12"));

const ZERO = ethers.ZeroAddress;
const ZERO_HASH = ethers.ZeroHash;

const GuardianABI = [
  "function getAllNodes(uint256 start, uint256 length) view returns (tuple(uint256 id, string PGP, string PGPKey, string ip_addr, string regionName)[])",
  "function ipaddress2owner(string) view returns (address)",
];

const AddressPgpABI = [
  "function addRoutes(string[] ipaddresses) external",
  "function adminList(address) view returns (bool)",
  "function nodeKeyExists(bytes32) view returns (bool)",
  "function nodeKeyIDByHash(bytes32) view returns (string)",
  "function nodeKeyHash2Wallet(bytes32) view returns (address)",
  "function nodeWallet2KeyHash(address) view returns (bytes32)",
];

type NodeAudit = {
  nft: number;
  ip: string;
  domain: string;
  routeKeyHash: string;
  guardianOwner: string;
  miningRateWallet: string | null;
  addressPgpBoundWallet: string;
  realWalletMapsToHash: string;
  ok: boolean;
  reasons: string[];
};

function loadAdminPk(): string {
  const env = process.env.ADDRESS_PGP_ADMIN_PK;
  if (env) return env.startsWith("0x") ? env : `0x${env}`;
  const masterPath = path.join(process.env.HOME || "", ".master.json");
  if (!fs.existsSync(masterPath)) {
    throw new Error("需 ADDRESS_PGP_ADMIN_PK 或 ~/.master.json");
  }
  const d = JSON.parse(fs.readFileSync(masterPath, "utf-8")) as Record<
    string,
    unknown
  >;
  for (const key of ["settle_contractAdmin", "beamio_Admins", "initManager"]) {
    const arr = d[key];
    if (!Array.isArray(arr) || !arr.length) continue;
    const first = arr[0];
    const pk =
      typeof first === "string"
        ? first
        : (first as { privateKey?: string })?.privateKey;
    if (pk) return pk.startsWith("0x") ? pk : `0x${pk}`;
  }
  throw new Error("master.json 中无 settle_contractAdmin / beamio_Admins / initManager");
}

async function mapPool<T, R>(
  items: T[],
  concurrency: number,
  fn: (item: T, index: number) => Promise<R>
): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  async function worker() {
    for (;;) {
      const i = next++;
      if (i >= items.length) return;
      out[i] = await fn(items[i]!, i);
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(concurrency, items.length) }, () => worker())
  );
  return out;
}

async function fetchMiningRateByIp(): Promise<Map<string, string>> {
  const map = new Map<string, string>();
  try {
    const res = await fetch(MINING_RATE_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    if (!res.ok) {
      console.warn(`[miningRate] HTTP ${res.status}, skip cross-check`);
      return map;
    }
    const j = (await res.json()) as {
      nodeWallets?: { ipAddr?: string; wallet?: string }[];
    };
    for (const row of j.nodeWallets || []) {
      const ip = String(row.ipAddr || "").trim();
      const w = String(row.wallet || "").trim();
      if (ip && w && ethers.isAddress(w)) {
        map.set(ip, ethers.getAddress(w));
      }
    }
    console.log(`[miningRate] loaded ${map.size} ip→wallet`);
  } catch (e: any) {
    console.warn(`[miningRate] fetch failed: ${e?.message || e}`);
  }
  return map;
}

async function loadGuardianNodes(
  guardian: ethers.Contract
): Promise<{ nft: number; domain: string; ip: string }[]> {
  const all: { nft: number; domain: string; ip: string }[] = [];
  for (let start = 0; start < 5000; start += 400) {
    const chunk = await guardian.getAllNodes!(start, 400);
    if (!chunk?.length) break;
    for (const n of chunk) {
      const nft = Number(n.id ?? n[0]);
      const domain = String(n.PGPKey ?? n[2] ?? "").trim();
      const ip = String(n.ip_addr ?? n[3] ?? "").trim();
      if (!ip || !domain) continue;
      if (nft < NFT_MIN || nft > NFT_MAX) continue;
      all.push({ nft, domain, ip });
    }
    if (chunk.length < 400) break;
  }
  all.sort((a, b) => a.nft - b.nft);
  return all;
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const guardian = new ethers.Contract(GUARDIAN_NODES, GuardianABI, provider);
  const pgpRead = new ethers.Contract(ADDRESS_PGP, AddressPgpABI, provider);

  console.log("=".repeat(64));
  console.log("AddressPGP node wallet binding repair");
  console.log("=".repeat(64));
  console.log(`RPC=${RPC}`);
  console.log(`Guardian=${GUARDIAN_NODES}`);
  console.log(`AddressPGP=${ADDRESS_PGP}`);
  console.log(`NFT=${NFT_MIN}..${NFT_MAX}  DRY_RUN=${DRY_RUN}  ONLY_BROKEN=${ONLY_BROKEN}`);
  console.log();

  const nodes = await loadGuardianNodes(guardian);
  console.log(`Guardian nodes in range: ${nodes.length}`);
  if (nodes.length === 0) throw new Error("no nodes loaded from Guardian");

  const miningByIp = await fetchMiningRateByIp();

  const audits = await mapPool(nodes, CONCURRENCY, async (n) => {
    const h = ethers.keccak256(ethers.toUtf8Bytes(n.domain));
    const reasons: string[] = [];
    let guardianOwner = ZERO;
    try {
      guardianOwner = ethers.getAddress(await guardian.ipaddress2owner!(n.ip));
    } catch {
      reasons.push("guardian.ipaddress2owner failed");
    }
    if (guardianOwner === ZERO) reasons.push("guardianOwner=0");

    const miningRateWallet = miningByIp.get(n.ip) || null;
    if (miningRateWallet && guardianOwner !== ZERO && miningRateWallet !== guardianOwner) {
      reasons.push(
        `miningRate≠guardian (${miningRateWallet.slice(0, 10)}≠${guardianOwner.slice(0, 10)})`
      );
    }

    const exists = await pgpRead.nodeKeyExists!(h);
    if (!exists) reasons.push("nodeKeyExists=false");

    let addressPgpBoundWallet = ZERO;
    try {
      addressPgpBoundWallet = ethers.getAddress(await pgpRead.nodeKeyHash2Wallet!(h));
    } catch {
      reasons.push("nodeKeyHash2Wallet failed");
    }

    let realWalletMapsToHash = ZERO_HASH;
    if (guardianOwner !== ZERO) {
      realWalletMapsToHash = await pgpRead.nodeWallet2KeyHash!(guardianOwner);
    }

    if (addressPgpBoundWallet === ZERO) {
      reasons.push("AddressPGP bound wallet=0");
    } else if (guardianOwner !== ZERO && addressPgpBoundWallet !== guardianOwner) {
      reasons.push(
        `boundWallet≠guardianOwner (${addressPgpBoundWallet}≠${guardianOwner})`
      );
    }

    if (guardianOwner !== ZERO) {
      if (realWalletMapsToHash === ZERO_HASH) {
        reasons.push("nodeWallet2KeyHash(guardianOwner)=0");
      } else if (realWalletMapsToHash.toLowerCase() !== h.toLowerCase()) {
        reasons.push("nodeWallet2KeyHash(guardianOwner)≠this domain hash");
      }
    }

    const ok = reasons.length === 0;
    const row: NodeAudit = {
      nft: n.nft,
      ip: n.ip,
      domain: n.domain,
      routeKeyHash: h,
      guardianOwner,
      miningRateWallet,
      addressPgpBoundWallet,
      realWalletMapsToHash,
      ok,
      reasons,
    };
    return row;
  });

  const broken = audits.filter((a) => !a.ok);
  const okCount = audits.length - broken.length;
  const ghostHits = broken.filter((a) =>
    a.addressPgpBoundWallet.toLowerCase() ===
    "0xb0559c92e9ca3887556d202792a596fcc7760f10"
  ).length;
  const miningMismatch = audits.filter((a) =>
    a.reasons.some((r) => r.startsWith("miningRate≠guardian"))
  ).length;

  console.log(
    `Audit: ok=${okCount} broken=${broken.length} ghost0xb055=${ghostHits} mining≠guardian=${miningMismatch}`
  );
  if (broken.length) {
    console.log("Sample broken (first 15):");
    for (const b of broken.slice(0, 15)) {
      console.log(
        `  #${b.nft} ${b.ip} domain=${b.domain} bound=${b.addressPgpBoundWallet} guardian=${b.guardianOwner} :: ${b.reasons.join("; ")}`
      );
    }
  }

  const report = {
    at: new Date().toISOString(),
    rpc: RPC,
    addressPgp: ADDRESS_PGP,
    guardian: GUARDIAN_NODES,
    nftMin: NFT_MIN,
    nftMax: NFT_MAX,
    dryRun: DRY_RUN,
    onlyBroken: ONLY_BROKEN,
    totals: {
      audited: audits.length,
      ok: okCount,
      broken: broken.length,
      ghost0xb055: ghostHits,
      miningMismatch,
    },
    broken,
    all: audits,
    txs: [] as { hash: string; ips: string[]; ok: boolean; error?: string }[],
  };

  const toFix = ONLY_BROKEN
    ? broken.filter((b) => b.guardianOwner !== ZERO).map((b) => b.ip)
    : audits.filter((a) => a.guardianOwner !== ZERO).map((a) => a.ip);

  // unique IPs preserve order
  const ips: string[] = [];
  const seen = new Set<string>();
  for (const ip of toFix) {
    if (seen.has(ip)) continue;
    seen.add(ip);
    ips.push(ip);
  }

  console.log(`\nWill ${DRY_RUN ? "DRY-RUN skip" : "submit"} addRoutes for ${ips.length} IPs`);

  if (!DRY_RUN && ips.length) {
    const adminPk = loadAdminPk();
    const signer = new ethers.Wallet(adminPk, provider);
    const pgpWrite = new ethers.Contract(ADDRESS_PGP, AddressPgpABI, signer);
    const isAdmin = await pgpWrite.adminList!(signer.address);
    if (!isAdmin) {
      throw new Error(`signer ${signer.address} is not AddressPGP admin`);
    }
    const bal = await provider.getBalance(signer.address);
    console.log(`Signer=${signer.address} bal=${ethers.formatEther(bal)} CNET`);
    if (bal === 0n) throw new Error("admin balance is 0");

    for (let i = 0; i < ips.length; i += BATCH_SIZE) {
      const batch = ips.slice(i, i + BATCH_SIZE);
      const label = `[${Math.floor(i / BATCH_SIZE) + 1}/${Math.ceil(ips.length / BATCH_SIZE)}]`;
      try {
        const tx = await pgpWrite.addRoutes!(batch);
        console.log(`${label} addRoutes(${batch.length}) tx=${tx.hash}`);
        await tx.wait();
        report.txs.push({ hash: tx.hash, ips: batch, ok: true });
        console.log(`${label} ✅ confirmed`);
      } catch (e: any) {
        const msg = e?.shortMessage || e?.message || String(e);
        console.error(`${label} ❌ batch failed: ${msg.slice(0, 200)}`);
        report.txs.push({ hash: "", ips: batch, ok: false, error: msg });
        for (const ip of batch) {
          try {
            const tx = await pgpWrite.addRoutes!([ip]);
            console.log(`  single ${ip} tx=${tx.hash}`);
            await tx.wait();
            report.txs.push({ hash: tx.hash, ips: [ip], ok: true });
          } catch (e2: any) {
            const m2 = e2?.shortMessage || e2?.message || String(e2);
            console.error(`  single ${ip} failed: ${m2.slice(0, 120)}`);
            report.txs.push({ hash: "", ips: [ip], ok: false, error: m2 });
          }
        }
      }
    }

    // Re-audit after repair
    console.log("\nRe-audit after repair...");
    const recheck = await mapPool(
      nodes.filter((n) => ips.includes(n.ip)),
      CONCURRENCY,
      async (n) => {
        const h = ethers.keccak256(ethers.toUtf8Bytes(n.domain));
        const owner = ethers.getAddress(await guardian.ipaddress2owner!(n.ip));
        const bound = ethers.getAddress(await pgpRead.nodeKeyHash2Wallet!(h));
        const reverse = await pgpRead.nodeWallet2KeyHash!(owner);
        const ok =
          owner !== ZERO &&
          bound === owner &&
          reverse.toLowerCase() === h.toLowerCase();
        return { nft: n.nft, ip: n.ip, domain: n.domain, owner, bound, reverse, ok };
      }
    );
    const stillBad = recheck.filter((r) => !r.ok);
    console.log(
      `Post-repair: checked=${recheck.length} ok=${recheck.length - stillBad.length} stillBad=${stillBad.length}`
    );
    if (stillBad.length) {
      console.log("Still bad sample:", stillBad.slice(0, 10));
    }
    ;(report as any).postRepair = {
      checked: recheck.length,
      ok: recheck.length - stillBad.length,
      stillBad,
    };
  }

  fs.mkdirSync(path.dirname(OUT_JSON), { recursive: true });
  fs.writeFileSync(OUT_JSON, JSON.stringify(report, null, 2));
  console.log(`\nReport → ${OUT_JSON}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
