/**
 * 将运维钱包加入 AccountRegistry admin（changeAddressInAdminlist）。
 * 用于修复 addUserPoolProcess / addFollowPoolProcess 的 NotAdmin 报错。
 *
 * 待添加地址来源（合并去重）：
 *   - ~/.master.json beamio_Admins（私钥 → 地址）
 *   - ~/.master.json settle_contractAdmin（私钥 → 地址）
 *   - ~/.master.json admin：可为私钥或 0x 地址字符串
 *   - 环境变量 ACCOUNT_REGISTRY_EXTRA_ADMINS：逗号/空格分隔的地址，例 0xabc...,0xdef...
 *
 * 用法:
 *   npx hardhat run scripts/addBeamioAdminsToAccountRegistry.ts --network conet
 *   ACCOUNT_REGISTRY=0x... npx hardhat run scripts/addBeamioAdminsToAccountRegistry.ts --network conet
 *   ACCOUNT_REGISTRY_EXTRA_ADMINS=0x6add... npx hardhat run scripts/addBeamioAdminsToAccountRegistry.ts --network conet
 *
 * 签名者:
 *   默认 REGISTRY_OWNER_PK，否则 settle_contractAdmin[0]；须已是链上 admin。
 */
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";

const CONET_RPC = "https://rpc1.conet.network";
const ACCOUNT_REGISTRY = process.env.ACCOUNT_REGISTRY || "0x2dF9c4c51564FfF861965572CE11ebe27d3C1B35";
const MASTER_PATH = path.join(homedir(), ".master.json");

const AccountRegistryABI = [
  "function changeAddressInAdminlist(address account, bool status) external",
  "function isAdmin(address) view returns (bool)",
];

function normPk(s: string): string {
  const t = s.trim();
  return t.startsWith("0x") ? t : `0x${t}`;
}

function isPrivateKeyHex(s: string): boolean {
  const hex = s.trim().startsWith("0x") ? s.trim().slice(2) : s.trim();
  return hex.length === 64 && /^[0-9a-fA-F]+$/.test(hex);
}

type MasterFile = {
  beamio_Admins: string[];
  settle_contractAdmin: string[];
  admin: unknown[];
};

function loadMaster(): MasterFile {
  if (!fs.existsSync(MASTER_PATH)) throw new Error("未找到 ~/.master.json");
  const data = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  const beamio_Admins = Array.isArray(data.beamio_Admins) ? data.beamio_Admins : [];
  const settle_contractAdmin = Array.isArray(data.settle_contractAdmin) ? data.settle_contractAdmin : [];
  const admin = Array.isArray(data.admin) ? data.admin : [];
  return {
    beamio_Admins: beamio_Admins.map((pk: string) => normPk(String(pk))),
    settle_contractAdmin: settle_contractAdmin.map((pk: string) => normPk(String(pk))),
    admin,
  };
}

/** 合并所有应登记为 admin 的地址（checksum） */
function collectTargetAdminAddresses(master: MasterFile): string[] {
  const lower = new Set<string>();

  const addPk = (pk: string) => {
    if (!isPrivateKeyHex(pk)) return;
    lower.add(new ethers.Wallet(normPk(pk)).address.toLowerCase());
  };

  for (const pk of master.beamio_Admins) addPk(pk);
  for (const pk of master.settle_contractAdmin) addPk(pk);

  for (const entry of master.admin) {
    if (typeof entry !== "string") continue;
    const t = entry.trim();
    if (ethers.isAddress(t)) {
      lower.add(ethers.getAddress(t).toLowerCase());
    } else if (isPrivateKeyHex(t)) {
      addPk(t);
    }
  }

  const extra =
    process.env.ACCOUNT_REGISTRY_EXTRA_ADMINS?.trim() ||
    process.env.REGISTRY_EXTRA_ADMINS?.trim() ||
    "";
  if (extra) {
    for (const part of extra.split(/[,;\s]+/).filter(Boolean)) {
      const p = part.trim();
      if (ethers.isAddress(p)) lower.add(ethers.getAddress(p).toLowerCase());
    }
  }

  if (lower.size === 0) {
    throw new Error(
      "无任何待添加地址：请在 ~/.master.json 配置 beamio_Admins / settle_contractAdmin / admin，或设置 ACCOUNT_REGISTRY_EXTRA_ADMINS"
    );
  }

  return [...lower].map((a) => ethers.getAddress(a));
}

async function main() {
  const master = loadMaster();
  const ownerPk =
    process.env.REGISTRY_OWNER_PK?.trim() ||
    master.settle_contractAdmin[0] ||
    master.beamio_Admins[0];
  if (!ownerPk || !isPrivateKeyHex(ownerPk)) {
    throw new Error("需配置 REGISTRY_OWNER_PK，或 ~/.master.json 中 settle_contractAdmin / beamio_Admins 含有效私钥");
  }

  const provider = new ethers.JsonRpcProvider(CONET_RPC);
  const signer = new ethers.Wallet(normPk(ownerPk), provider);
  const addresses = collectTargetAdminAddresses(master);

  console.log("=".repeat(60));
  console.log("添加运维地址到 AccountRegistry Admin");
  console.log("=".repeat(60));
  console.log("AccountRegistry:", ACCOUNT_REGISTRY);
  console.log("Signer (须已是 admin):", signer.address);
  console.log("待添加/校验地址数:", addresses.length);
  addresses.forEach((a, i) => console.log(`  ${i + 1}. ${a}`));
  console.log();

  const registry = new ethers.Contract(ACCOUNT_REGISTRY, AccountRegistryABI, signer);

  const signerIsAdmin = await registry.isAdmin(signer.address);
  if (!signerIsAdmin) {
    console.error("\n❌ 当前 signer (" + signer.address + ") 不是 AccountRegistry admin，无法执行 changeAddressInAdminlist");
    console.error("请设置 REGISTRY_OWNER_PK 为部署该合约的 deployer 私钥，或任一已登记 admin 的私钥");
    process.exit(1);
  }

  for (let i = 0; i < addresses.length; i++) {
    const addr = addresses[i];
    let already = false;
    try {
      already = await registry.isAdmin(addr);
    } catch (_) {}
    if (already) {
      console.log(`[${i + 1}/${addresses.length}] ${addr} 已是 admin，跳过`);
      continue;
    }
    try {
      const tx = await registry.changeAddressInAdminlist(addr, true);
      console.log(`[${i + 1}/${addresses.length}] changeAddressInAdminlist(${addr}, true) tx: ${tx.hash}`);
      await tx.wait();
      console.log(`  ✅ 已添加`);
    } catch (e: any) {
      console.error(`  ❌ 失败: ${e?.message?.slice?.(0, 120) ?? e}`);
    }
  }

  console.log("\n完成");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
