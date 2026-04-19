/**
 * 将 ~/.master.json beamio_Admins 中的钱包添加到 AccountRegistry (beamioConetAccountRegistry) admin
 * 用于修复 addUserPoolProcess / addFollowPoolProcess 的 NotAdmin 报错
 *
 * 用法:
 *   npx hardhat run scripts/addBeamioAdminsToAccountRegistry.ts --network conet
 *   ACCOUNT_REGISTRY=0x... npx hardhat run scripts/addBeamioAdminsToAccountRegistry.ts --network conet
 *
 * 配置:
 *   - ~/.master.json 中 beamio_Admins（私钥数组）
 *   - 需用 AccountRegistry owner 私钥签名；默认用 settle_contractAdmin[0]，或设置 env REGISTRY_OWNER_PK
 */
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";

const CONET_RPC = "https://rpc1.conet.network";
const ACCOUNT_REGISTRY = process.env.ACCOUNT_REGISTRY || "0x46cBFC3f77b320Db545D1DC21138fa1ED2Fa3df3";
const MASTER_PATH = path.join(homedir(), ".master.json");

const AccountRegistryABI = [
  "function changeAddressInAdminlist(address account, bool status) external",
  "function isAdmin(address) view returns (bool)",
];

function loadMaster(): { beamio_Admins: string[]; settle_contractAdmin: string[] } {
  if (!fs.existsSync(MASTER_PATH)) throw new Error("未找到 ~/.master.json");
  const data = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  const beamio_Admins = data.beamio_Admins || [];
  const settle_contractAdmin = data.settle_contractAdmin || [];
  if (!beamio_Admins.length) throw new Error("~/.master.json 中 beamio_Admins 为空");
  return {
    beamio_Admins: beamio_Admins.map((pk: string) => (pk.startsWith("0x") ? pk : `0x${pk}`)),
    settle_contractAdmin: settle_contractAdmin.map((pk: string) => (pk.startsWith("0x") ? pk : `0x${pk}`)),
  };
}

async function main() {
  const master = loadMaster();
  const ownerPk = process.env.REGISTRY_OWNER_PK || master.settle_contractAdmin[0];
  if (!ownerPk) throw new Error("需配置 REGISTRY_OWNER_PK 或 settle_contractAdmin");

  const provider = new ethers.JsonRpcProvider(CONET_RPC);
  const signer = new ethers.Wallet(ownerPk, provider);
  const addresses = master.beamio_Admins.map((pk: string) => new ethers.Wallet(pk).address);

  console.log("=".repeat(60));
  console.log("添加 beamio_Admins 到 AccountRegistry Admin");
  console.log("=".repeat(60));
  console.log("AccountRegistry:", ACCOUNT_REGISTRY);
  console.log("Signer (owner):", signer.address);
  console.log("待添加地址数:", addresses.length);
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
