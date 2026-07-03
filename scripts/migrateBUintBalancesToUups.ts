/**
 * 将旧直连 B-Unit（v1）双池余额迁移至 UUPS proxy。
 *
 * 运行:
 *   DRY_RUN=1 npx hardhat run scripts/migrateBUintBalancesToUups.ts --network conet
 *   npx hardhat run scripts/migrateBUintBalancesToUups.ts --network conet
 *
 * 环境变量:
 *   LEGACY_BUINT — 旧合约（默认 0xa354…27f0）
 *   NEW_BUINT_PROXY — UUPS proxy（默认 BUINT_UUPS_PROXY_PREDICTED）
 */
import { network as networkModule } from "hardhat";
import { getAddress } from "ethers";
import {
  BUINT_UUPS_PROXY_PREDICTED,
} from "./erc20UupsDeployConstants.js";

const LEGACY_BUINT = getAddress(
  process.env.LEGACY_BUINT || "0xa354CC4c414568Dd14F6d63b53013f35483427f0"
);
const NEW_PROXY = getAddress(process.env.NEW_BUINT_PROXY || BUINT_UUPS_PROXY_PREDICTED);
const HOLDERS_API =
  process.env.BUINT_HOLDERS_API ||
  `https://mainnet.conet.network/api/v2/tokens/${LEGACY_BUINT}/holders`;

type HolderRow = { address: { hash: string }; value: string };

async function fetchAllHolders(): Promise<HolderRow[]> {
  const out: HolderRow[] = [];
  let url: string | null = HOLDERS_API;
  while (url) {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`holders API ${res.status}: ${url}`);
    const body = (await res.json()) as {
      items?: HolderRow[];
      next_page_params?: Record<string, string | number>;
    };
    out.push(...(body.items ?? []));
    const nxt = body.next_page_params;
    if (!nxt) {
      url = null;
      break;
    }
    const q = new URLSearchParams(
      Object.fromEntries(Object.entries(nxt).map(([k, v]) => [k, String(v)]))
    ).toString();
    url = `${HOLDERS_API}${HOLDERS_API.includes("?") ? "&" : "?"}${q}`;
  }
  return out;
}

async function main() {
  const dryRun = process.env.DRY_RUN === "1";
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("无签名账户");

  const legacy = await ethers.getContractAt(
    [
      "function balanceOfAll(address) view returns (uint256 total, uint256 free, uint256 paid)",
      "function totalSupply() view returns (uint256)",
    ],
    LEGACY_BUINT
  );
  const buint = await ethers.getContractAt(
    [
      "function mintCombo(address to, uint256 paidAmount, uint256 rewardAmount)",
      "function balanceOfAll(address) view returns (uint256 total, uint256 free, uint256 paid)",
      "function totalSupply() view returns (uint256)",
      "function admins(address) view returns (bool)",
    ],
    NEW_PROXY,
    signer
  );

  const proxyCode = await ethers.provider.getCode(NEW_PROXY);
  if (proxyCode === "0x" || proxyCode.length <= 2) {
    throw new Error(`新 proxy 未部署: ${NEW_PROXY}`);
  }

  const isAdmin = await buint.admins(signer.address);
  if (!isAdmin) {
    throw new Error(`Signer ${signer.address} 不是 admin`);
  }

  const holders = await fetchAllHolders();
  console.log("legacy:", LEGACY_BUINT);
  console.log("new proxy:", NEW_PROXY);
  console.log("holders from API:", holders.length);
  console.log("legacy totalSupply:", (await legacy.totalSupply()).toString());

  let migrated = 0;
  let skipped = 0;
  let freeSum = 0n;
  let paidSum = 0n;

  for (const row of holders) {
    const addr = getAddress(row.address.hash);
    const [, free, paid] = await legacy.balanceOfAll(addr);
    if (free === 0n && paid === 0n) {
      skipped++;
      continue;
    }
    const [, newFree, newPaid] = await buint.balanceOfAll(addr);
    // 仅补差额，避免已部分迁移账户被二次 mintCombo 双倍入账
    const freeDelta = free > newFree ? free - newFree : 0n;
    const paidDelta = paid > newPaid ? paid - newPaid : 0n;
    if (freeDelta === 0n && paidDelta === 0n) {
      console.log(`  ${addr} already covered on proxy (legacy free=${free} paid=${paid}; new free=${newFree} paid=${newPaid})`);
      skipped++;
      continue;
    }
    freeSum += freeDelta;
    paidSum += paidDelta;
    console.log(
      `  ${addr} mint freeDelta=${freeDelta} paidDelta=${paidDelta} (legacy free=${free} paid=${paid}; new free=${newFree} paid=${newPaid})`
    );
    if (!dryRun) {
      const tx = await buint.mintCombo(addr, paidDelta, freeDelta);
      console.log("    tx:", tx.hash);
      await tx.wait();
    }
    migrated++;
  }

  console.log("=".repeat(60));
  console.log("migrated accounts:", migrated, "skipped zero:", skipped);
  console.log("free sum:", freeSum.toString(), "paid sum:", paidSum.toString());
  if (dryRun) {
    console.log("DRY_RUN=1 — 未发链上交易");
    return;
  }
  const newSupply = await buint.totalSupply();
  const oldSupply = await legacy.totalSupply();
  console.log("new totalSupply:", newSupply.toString(), "legacy:", oldSupply.toString());
  if (newSupply !== oldSupply) {
    console.warn("WARN: totalSupply 与旧合约不完全一致，请核对未在 API 中的持有人");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
