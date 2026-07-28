/**
 * 校验 BUnitAirdrop 是否为 BUint 的 admin
 * 必须为 admin 才能在 claimFor / consumeFuel 等路径调用 BUint.mintReward / consumeFuel。
 *
 * 地址优先级：环境变量 BUINT_ADDRESS / BUNIT_AIRDROP_ADDRESS > deployments/conet-addresses.json > 兜底常量
 * 禁止硬编码已废弃的旧 BUint 地址，遵循 conet-addresses.json 中 DEPRECATED_BUINT 列表。
 *
 * Run: npx tsx scripts/checkBUnitAirdropBUintAdmin.ts
 */
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const RPC = process.env.CONET_RPC || "https://rpc1.conet.network";

function loadAddresses(): { BUINT: string; BUNIT_AIRDROP: string; deprecated: string[] } {
  const data = fs.existsSync(ADDRESSES_PATH) ? JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8")) : {};
  const BUINT = process.env.BUINT_ADDRESS || data.BUint;
  const BUNIT_AIRDROP = process.env.BUNIT_AIRDROP_ADDRESS || data.BUnitAirdrop;
  if (!BUINT) throw new Error("未解析到 BUint 地址（缺少 BUINT_ADDRESS 或 conet-addresses.json BUint 字段）");
  if (!BUNIT_AIRDROP) throw new Error("未解析到 BUnitAirdrop 地址");
  const deprecated: string[] = (data.DEPRECATED_BUINT || []).map((s: string) => s.toLowerCase());
  if (deprecated.includes(BUINT.toLowerCase())) {
    throw new Error(`禁止使用已废弃的 BUint 地址 ${BUINT}（见 conet-addresses.json DEPRECATED_BUINT）`);
  }
  return { BUINT, BUNIT_AIRDROP, deprecated };
}

async function main() {
  const { BUINT, BUNIT_AIRDROP } = loadAddresses();
  const provider = new ethers.JsonRpcProvider(RPC);
  const buint = new ethers.Contract(BUINT, ["function admins(address) view returns (bool)"], provider);

  console.log("RPC:", RPC);
  console.log("BUint:", BUINT);
  console.log("BUnitAirdrop:", BUNIT_AIRDROP);

  let isAdmin: boolean;
  try {
    isAdmin = await buint.admins(BUNIT_AIRDROP);
  } catch (e: any) {
    throw new Error(`BUint.admins(BUnitAirdrop) 调用失败：${e?.shortMessage || e?.message || e}\n  → 请确认 BUint 地址 ${BUINT} 在链上有合约代码`);
  }

  console.log("BUnitAirdrop is BUint admin:", isAdmin);
  if (!isAdmin) {
    console.log("\n❌ 未登记。修复方法（任一已经是 BUint admin 的私钥）：");
    console.log(`   const buint = new ethers.Contract("${BUINT}", ["function addAdmin(address) external"], signer)`);
    console.log(`   await (await buint.addAdmin("${BUNIT_AIRDROP}")).wait()`);
    process.exitCode = 1;
  } else {
    console.log("\n✅ 已登记，BUnitAirdrop 可以正常调用 BUint.mintReward / consumeFuel");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
