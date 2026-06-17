/**
 * 从源 RPC 上的 AccountRegistry 批量迁移账号到目标链（默认 publicrpc / --network conet）。
 *
 * 用法:
 *   SOURCE_RPC=https://rpc1.conet.network \
 *   SOURCE_REGISTRY=0x26626a515EDFb5DF9547ac1A32Ec1785352211Ba \
 *   DRY_RUN=1 npx hardhat run scripts/migrateAccountRegistryFromSourceToConet.ts --network conet
 *
 * 环境变量:
 *   SOURCE_RPC / SOURCE_REGISTRY — 源链只读 RPC 与合约地址
 *   DEST_REGISTRY — 默认 deployments/conet-addresses.json AccountRegistry
 *   PAGE_SIZE — getAccountsPaginated 每页，默认 50
 *   START_CURSOR — 断点续传游标，默认 0
 *   LIMIT — 最多迁移条数（测试用）
 *   TX_DELAY_MS — 两笔交易间隔
 *   DRY_RUN=1 — 只拉取统计，不发交易
 */

import { network as hreNetwork } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const SOURCE_RPC_DEFAULT = "https://rpc1.conet.network";
const SOURCE_REGISTRY_DEFAULT = "0x26626a515EDFb5DF9547ac1A32Ec1785352211Ba";

const RegistryABI = [
  "function getOwnersArrayLength() view returns (uint256)",
  "function getAccountsPaginated(uint256 cursor, uint256 pageSize) view returns (address[] owners, string[] names, uint256[] timestamps, uint256 nextCursor)",
  "function getAccount(address owner) view returns (tuple(string accountName,string image,bool darkTheme,bool isUSDCFaucet,bool isETHFaucet,bool initialLoading,string firstName,string lastName,uint256 createdAt,bool exists,string pgpKeyID,string pgpKey))",
  "function getBase64ByAccountName(string accountName) view returns (string)",
  "function getOwnerByAccountName(string accountName) view returns (address)",
  "function setAccountByAdmin(address account, tuple(string accountName,string image,bool darkTheme,bool isUSDCFaucet,bool isETHFaucet,bool initialLoading,string firstName,string lastName,string pgpKeyID,string pgpKey) input) external",
  "function setBase64NameByAdmin(bytes32 hash, string base64Data, string accountName, address to) external",
  "function isAdmin(address) view returns (bool)",
];

function loadDestRegistry(): string {
  const env = (process.env.DEST_REGISTRY || "").trim();
  if (env) return env;
  const p = path.join(__dirname, "..", "deployments", "conet-addresses.json");
  if (fs.existsSync(p)) {
    const j = JSON.parse(fs.readFileSync(p, "utf-8")) as { AccountRegistry?: string };
    if (j.AccountRegistry) return j.AccountRegistry;
  }
  throw new Error("无法解析 DEST_REGISTRY");
}

type AccountRow = {
  owner: string;
  accountName: string;
  image: string;
  darkTheme: boolean;
  isUSDCFaucet: boolean;
  isETHFaucet: boolean;
  initialLoading: boolean;
  firstName: string;
  lastName: string;
  pgpKeyID: string;
  pgpKey: string;
  base64: string;
};

async function fetchAllAccounts(
  src: import("ethers").Contract,
  pageSize: number,
  startCursor: number,
  limit?: number
): Promise<AccountRow[]> {
  const { ethers } = await hreNetwork.connect();
  const len = await src.getOwnersArrayLength();
  const totalLen = Number(len);
  const rows: AccountRow[] = [];
  let cursor = startCursor;

  while (cursor < totalLen) {
    const [owners, , , nextCursor] = await src.getAccountsPaginated(cursor, pageSize);
    for (const owner of owners) {
      const acc = await src.getAccount(owner);
      const accountName = String(acc.accountName ?? "");
      let base64 = "";
      if (accountName) {
        try {
          base64 = String(await src.getBase64ByAccountName(accountName));
        } catch {
          base64 = "";
        }
      }
      rows.push({
        owner: ethers.getAddress(owner),
        accountName,
        image: String(acc.image ?? ""),
        darkTheme: Boolean(acc.darkTheme),
        isUSDCFaucet: Boolean(acc.isUSDCFaucet),
        isETHFaucet: Boolean(acc.isETHFaucet),
        initialLoading: Boolean(acc.initialLoading),
        firstName: String(acc.firstName ?? ""),
        lastName: String(acc.lastName ?? ""),
        pgpKeyID: String(acc.pgpKeyID ?? ""),
        pgpKey: String(acc.pgpKey ?? ""),
        base64,
      });
      if (limit !== undefined && rows.length >= limit) return rows;
    }
    if (Number(nextCursor) <= cursor) break;
    cursor = Number(nextCursor);
  }
  return rows;
}

async function main() {
  const dry = process.env.DRY_RUN === "1" || process.env.DRY_RUN === "true";
  const pageSize = Math.max(1, parseInt(process.env.PAGE_SIZE || "50", 10) || 50);
  const startCursor = Math.max(0, parseInt(process.env.START_CURSOR || "0", 10) || 0);
  const limit = process.env.LIMIT === undefined ? undefined : Number(process.env.LIMIT);
  const txDelay = Math.max(0, parseInt(process.env.TX_DELAY_MS || "0", 10) || 0);

  const sourceRpc = (process.env.SOURCE_RPC || SOURCE_RPC_DEFAULT).trim();
  const sourceAddr = (process.env.SOURCE_REGISTRY || SOURCE_REGISTRY_DEFAULT).trim();
  const destAddr = loadDestRegistry();

  const { ethers } = await hreNetwork.connect();
  const sourceProvider = new ethers.JsonRpcProvider(sourceRpc);
  const src = new ethers.Contract(sourceAddr, RegistryABI, sourceProvider);

  console.log("=".repeat(60));
  console.log("AccountRegistry 迁移: 源 → conet (--network)");
  console.log("=".repeat(60));
  console.log("源 RPC:", sourceRpc);
  console.log("源合约:", sourceAddr);
  console.log("目标合约:", destAddr);
  console.log("DRY_RUN:", dry);
  console.log("START_CURSOR:", startCursor, "PAGE_SIZE:", pageSize);
  console.log();

  const srcCode = await sourceProvider.getCode(sourceAddr);
  if (srcCode === "0x") throw new Error(`源合约无代码: ${sourceAddr}`);

  const rows = await fetchAllAccounts(src, pageSize, startCursor, limit);
  console.log(`待迁移有效账号: ${rows.length}`);
  if (rows.length === 0) return;

  const dumpPath = (process.env.ACCOUNT_REGISTRY_DUMP_PATH || "").trim();
  if (dumpPath) {
    fs.writeFileSync(dumpPath, JSON.stringify(rows, null, 2), "utf-8");
    console.log("已写入 dump:", dumpPath);
  }

  if (dry) {
    for (const r of rows.slice(0, 10)) {
      console.log(`  ${r.owner} @${r.accountName} base64Len=${r.base64.length}`);
    }
    if (rows.length > 10) console.log(`  ... 共 ${rows.length} 条`);
    console.log("\nDRY_RUN: 未发送交易");
    return;
  }

  const [signer] = await ethers.getSigners();
  const dest = new ethers.Contract(destAddr, RegistryABI, signer);
  const isAdmin = await dest.isAdmin(signer.address);
  if (!isAdmin) {
    throw new Error(`签名地址 ${signer.address} 不是目标 AccountRegistry admin`);
  }

  let ok = 0;
  let skipped = 0;
  for (const r of rows) {
    const existing = await dest.getOwnerByAccountName(r.accountName).catch(() => ethers.ZeroAddress);
    if (existing !== ethers.ZeroAddress && existing.toLowerCase() === r.owner.toLowerCase()) {
      console.log(`已存在，跳过: @${r.accountName} ${r.owner}`);
      skipped++;
      continue;
    }
    if (existing !== ethers.ZeroAddress && existing.toLowerCase() !== r.owner.toLowerCase()) {
      console.warn(`名字冲突，跳过: @${r.accountName} 已有 owner ${existing}，源 ${r.owner}`);
      skipped++;
      continue;
    }

    const input = {
      accountName: r.accountName,
      image: r.image,
      darkTheme: r.darkTheme,
      isUSDCFaucet: r.isUSDCFaucet,
      isETHFaucet: r.isETHFaucet,
      initialLoading: r.initialLoading,
      firstName: r.firstName,
      lastName: r.lastName,
      pgpKeyID: r.pgpKeyID,
      pgpKey: r.pgpKey,
    };
    const tx = await dest.setAccountByAdmin(r.owner, input);
    console.log(`setAccountByAdmin @${r.accountName} tx ${tx.hash}`);
    await tx.wait();

    if (r.base64 && r.base64.length > 0) {
      const nameHash = ethers.keccak256(ethers.toUtf8Bytes(r.accountName));
      const tx2 = await dest.setBase64NameByAdmin(nameHash, r.base64, r.accountName, r.owner);
      console.log(`  setBase64NameByAdmin tx ${tx2.hash}`);
      await tx2.wait();
    }
    ok++;
    if (txDelay > 0) await new Promise((res) => setTimeout(res, txDelay));
  }

  console.log("\n完成: 新写入", ok, "笔，跳过", skipped, "笔");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
