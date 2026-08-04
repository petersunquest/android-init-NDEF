/**
 * 批量扫描 AddressPGP：Guardian domain 的 route key hash
 * 与 `nodeWallet2KeyHash(nodeKeyHash2Wallet(hash))` 是否一致。
 *
 * SI `isMyRoute(user, nodeWallet)` 要求：
 *   nodeWallet2KeyHash(nodeWallet) === userRouteHash(user)
 * 当用户 route 指向 domain D（hash H）时，托管该 mailbox 的节点钱包 W 必须满足
 *   nodeWallet2KeyHash(W) === H
 * 否则 `setUserOnlineOnMe` 永不触发 → 用户 `routeOnline` 恒为 false。
 *
 * 用法:
 *   npx tsx scripts/scanAddressPgpNodeWalletRouteConsistency.ts
 *   ALLNODES_JSON=... OUT_JSON=.../report.json npx tsx scripts/scanAddressPgpNodeWalletRouteConsistency.ts
 *   USERS=0x11C7...,0x... npx tsx scripts/scanAddressPgpNodeWalletRouteConsistency.ts
 *
 * 环境变量:
 *   CONET_RPC / NEW_RPC — 默认 https://rpc1.conet.network
 *   ADDRESS_PGP — 默认 deployments/conet-AddressPGP.json
 *   ALLNODES_JSON — Guardian domain 列表（默认 SilentPassUI allnodes.json）
 *   USERS — 可选逗号分隔 EOA；额外检查 userRouteHash vs 对应节点 wallet 映射
 *   CONCURRENCY — 默认 8
 *   OUT_JSON — 可选写入完整报告
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

const ALLNODES_JSON =
  process.env.ALLNODES_JSON ||
  path.join(ROOT, "src", "SilentPassUI", "src", "pages", "Home", "assets", "allnodes.json");

const CONCURRENCY = Math.max(1, Number(process.env.CONCURRENCY || "8"));
const OUT_JSON = process.env.OUT_JSON || "";
const USERS = (process.env.USERS || "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

const ABI = [
  "function nodeKeyExists(bytes32) view returns (bool)",
  "function nodeKeyIDByHash(bytes32) view returns (string)",
  "function nodeKeyHash2Wallet(bytes32) view returns (address)",
  "function nodeWallet2KeyHash(address) view returns (bytes32)",
  "function userRouteHash(address) view returns (bytes32)",
  "function searchKey(address) view returns (string,string,string,string,bool)",
];

type NodeRow = {
  domain: string;
  ip_addr?: string;
  region?: string;
  nftNumber?: number;
};

type NodeScanResult = {
  domain: string;
  ip_addr?: string;
  region?: string;
  nftNumber?: number;
  routeKeyHash: string;
  nodeKeyExists: boolean;
  registeredWallet: string;
  walletMapsToHash: string;
  walletMapsToDomain: string;
  ok: boolean;
  reason?: string;
};

type UserScanResult = {
  user: string;
  userRouteHash: string;
  routeDomain: string;
  routeOnline: boolean;
  registeredWallet: string;
  walletMapsToHash: string;
  walletMapsToDomain: string;
  isMyRouteWouldPass: boolean;
  reason?: string;
};

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
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, () => worker()));
  return out;
}

function loadNodes(): NodeRow[] {
  if (!fs.existsSync(ALLNODES_JSON)) {
    throw new Error(`ALLNODES_JSON not found: ${ALLNODES_JSON}`);
  }
  const raw = JSON.parse(fs.readFileSync(ALLNODES_JSON, "utf-8")) as NodeRow[];
  const seen = new Set<string>();
  const nodes: NodeRow[] = [];
  for (const n of raw) {
    const domain = String(n.domain || "").trim().toUpperCase();
    if (!domain || seen.has(domain)) continue;
    seen.add(domain);
    nodes.push({ ...n, domain });
  }
  return nodes;
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const pgp = new ethers.Contract(ADDRESS_PGP, ABI, provider);
  const nodes = loadNodes();

  console.log(`[scan] rpc=${RPC}`);
  console.log(`[scan] AddressPGP=${ADDRESS_PGP}`);
  console.log(`[scan] nodes=${nodes.length} from ${ALLNODES_JSON}`);
  console.log(`[scan] concurrency=${CONCURRENCY}`);

  const nodeResults = await mapPool(nodes, CONCURRENCY, async (n) => {
    const routeKeyHash = ethers.id(n.domain);
    const result: NodeScanResult = {
      domain: n.domain,
      ip_addr: n.ip_addr,
      region: n.region,
      nftNumber: n.nftNumber,
      routeKeyHash,
      nodeKeyExists: false,
      registeredWallet: ethers.ZeroAddress,
      walletMapsToHash: ethers.ZeroHash,
      walletMapsToDomain: "",
      ok: false,
    };
    try {
      result.nodeKeyExists = Boolean(await pgp.nodeKeyExists!(routeKeyHash));
      if (!result.nodeKeyExists) {
        result.reason = "nodeKeyExists=false (domain hash not on AddressPGP)";
        return result;
      }
      const w = await pgp.nodeKeyHash2Wallet!(routeKeyHash);
      result.registeredWallet = ethers.getAddress(w);
      if (result.registeredWallet === ethers.ZeroAddress) {
        result.reason = "nodeKeyHash2Wallet=0x0";
        return result;
      }
      const h2 = await pgp.nodeWallet2KeyHash!(result.registeredWallet);
      result.walletMapsToHash = String(h2);
      if (result.walletMapsToHash === ethers.ZeroHash) {
        result.reason = "nodeWallet2KeyHash(registeredWallet)=0x0";
        return result;
      }
      try {
        result.walletMapsToDomain = String(await pgp.nodeKeyIDByHash!(result.walletMapsToHash));
      } catch {
        result.walletMapsToDomain = "";
      }
      if (result.walletMapsToHash.toLowerCase() !== routeKeyHash.toLowerCase()) {
        result.reason = `wallet maps to other domain ${result.walletMapsToDomain || result.walletMapsToHash.slice(0, 18)}`;
        return result;
      }
      result.ok = true;
      return result;
    } catch (e: any) {
      result.reason = e?.shortMessage || e?.message || String(e);
      return result;
    }
  });

  const mismatched = nodeResults.filter((r) => !r.ok);
  const okCount = nodeResults.filter((r) => r.ok).length;
  const notOnPgp = mismatched.filter((r) => (r.reason || "").includes("nodeKeyExists=false"));
  const walletMapsOther = mismatched.filter((r) => (r.reason || "").includes("maps to other"));
  const zeroMap = mismatched.filter(
    (r) =>
      !(r.reason || "").includes("nodeKeyExists=false") &&
      !(r.reason || "").includes("maps to other")
  );

  console.log("");
  console.log(
    `=== Node scan: ok=${okCount} | wallet≠routeHash=${walletMapsOther.length} | notOnAddressPGP=${notOnPgp.length} | other=${zeroMap.length} | total=${nodeResults.length} ===`
  );
  if (walletMapsOther.length) {
    console.log("--- nodeWallet2KeyHash ≠ route key hash (isMyRoute broken) ---");
    for (const r of walletMapsOther) {
      console.log(
        [r.domain, r.ip_addr || "-", r.registeredWallet, `→${r.walletMapsToDomain || "?"}`, r.reason || ""].join(
          " | "
        )
      );
    }
  }
  if (zeroMap.length) {
    console.log("--- other errors ---");
    for (const r of zeroMap) {
      console.log([r.domain, r.ip_addr || "-", r.registeredWallet, r.reason || ""].join(" | "));
    }
  }
  if (notOnPgp.length && process.env.VERBOSE_NOT_ON_PGP === "1") {
    console.log("--- not on AddressPGP ---");
    for (const r of notOnPgp) {
      console.log([r.domain, r.ip_addr || "-", r.reason || ""].join(" | "));
    }
  } else if (notOnPgp.length) {
    console.log(
      `(${notOnPgp.length} domains in allnodes but nodeKeyExists=false — omit listing; VERBOSE_NOT_ON_PGP=1 to print)`
    );
  }

  let userResults: UserScanResult[] = [];
  if (USERS.length) {
    console.log("");
    console.log(`=== User route scan (${USERS.length}) ===`);
    userResults = await mapPool(USERS, CONCURRENCY, async (raw) => {
      const user = ethers.getAddress(raw);
      const userRoute = String(await pgp.userRouteHash!(user));
      const row: UserScanResult = {
        user,
        userRouteHash: userRoute,
        routeDomain: "",
        routeOnline: false,
        registeredWallet: ethers.ZeroAddress,
        walletMapsToHash: ethers.ZeroHash,
        walletMapsToDomain: "",
        isMyRouteWouldPass: false,
      };
      if (userRoute === ethers.ZeroHash) {
        row.reason = "userRouteHash=0x0 (no route)";
        return row;
      }
      try {
        row.routeDomain = String(await pgp.nodeKeyIDByHash!(userRoute));
      } catch {
        row.routeDomain = "";
      }
      try {
        const sk = await pgp.searchKey!(user);
        row.routeOnline = Boolean(sk[4]);
      } catch {
        /* ignore */
      }
      row.registeredWallet = ethers.getAddress(await pgp.nodeKeyHash2Wallet!(userRoute));
      row.walletMapsToHash = String(await pgp.nodeWallet2KeyHash!(row.registeredWallet));
      try {
        row.walletMapsToDomain = String(await pgp.nodeKeyIDByHash!(row.walletMapsToHash));
      } catch {
        row.walletMapsToDomain = "";
      }
      row.isMyRouteWouldPass =
        row.registeredWallet !== ethers.ZeroAddress &&
        row.walletMapsToHash !== ethers.ZeroHash &&
        row.walletMapsToHash.toLowerCase() === userRoute.toLowerCase();
      if (!row.isMyRouteWouldPass) {
        row.reason =
          row.walletMapsToHash === ethers.ZeroHash
            ? "nodeWallet2KeyHash(routeWallet)=0x0"
            : `nodeWallet2KeyHash→${row.walletMapsToDomain || row.walletMapsToHash.slice(0, 18)} ≠ userRouteHash→${row.routeDomain}`;
      }
      console.log(
        [
          row.user,
          `route=${row.routeDomain || "?"} online=${row.routeOnline}`,
          `wallet=${row.registeredWallet}`,
          row.isMyRouteWouldPass ? "isMyRoute=OK" : `isMyRoute=FAIL (${row.reason})`,
        ].join(" | ")
      );
      return row;
    });
  }

  const report = {
    scannedAt: new Date().toISOString(),
    rpc: RPC,
    addressPgp: ADDRESS_PGP,
    allnodesJson: ALLNODES_JSON,
    summary: {
      nodesTotal: nodeResults.length,
      nodesOk: okCount,
      nodesMismatch: mismatched.length,
      nodesWalletMapsOtherDomain: walletMapsOther.length,
      nodesNotOnAddressPgp: notOnPgp.length,
      nodesOtherError: zeroMap.length,
      usersChecked: userResults.length,
      usersIsMyRouteFail: userResults.filter((u) => !u.isMyRouteWouldPass).length,
    },
    mismatchedNodes: mismatched,
    walletMapsOtherDomain: walletMapsOther,
    notOnAddressPgp: notOnPgp,
    allNodes: nodeResults,
    users: userResults,
  };

  if (OUT_JSON) {
    fs.mkdirSync(path.dirname(path.resolve(OUT_JSON)), { recursive: true });
    fs.writeFileSync(OUT_JSON, JSON.stringify(report, null, 2));
    console.log(`\n[scan] wrote ${OUT_JSON}`);
  } else {
    const fallback = path.join(ROOT, "deployments", "addresspgp-node-wallet-route-scan.json");
    fs.writeFileSync(fallback, JSON.stringify(report, null, 2));
    console.log(`\n[scan] wrote ${fallback}`);
  }

  // Non-zero exit if mismatches (useful for CI / ops gates)
  if (mismatched.length > 0 || userResults.some((u) => !u.isMyRouteWouldPass)) {
    process.exitCode = 2;
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
