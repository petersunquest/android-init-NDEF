/**
 * 将 ~/.master.json beamio_Admins 中的钱包地址登记为 AddressPGP 合约的 admin
 * 用于 regiestChatRoute API 调用 addPublicPGPByAdmin
 *
 * 用法:
 *   npx hardhat run scripts/addBeamioAdminsToAddressPGP.ts --network conet
 *   ADDRESS_PGP=0x... npx hardhat run scripts/addBeamioAdminsToAddressPGP.ts --network conet
 *
 * 配置:
 *   - ~/.master.json 中 beamio_Admins（私钥数组）
 *   - 需用 AddressPGP 已有 admin 私钥签名；设置 env ADDRESS_PGP_ADMIN_PK（部署者或任一 admin）
 */
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const CONET_RPC = "https://rpc1.conet.network";
const MASTER_PATH = path.join(homedir(), ".master.json");

const AddressPGPABI = [
  "function changeAddressInAdminlist(address addr, bool status) external",
  "function adminList(address) view returns (bool)",
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

function getAddressPGPAddress(): string {
  const env = process.env.ADDRESS_PGP;
  if (env) return env;
  const deployPath = path.join(__dirname, "..", "deployments", "conet-AddressPGP.json");
  if (fs.existsSync(deployPath)) {
    const d = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
    return d.AddressPGP || "";
  }
  return "0x13A96Bcd6aB010619d1004A1Cb4f5FE149e0F4c4";
}

async function main() {
  const master = loadMaster();
  const adminPk = process.env.ADDRESS_PGP_ADMIN_PK || master.settle_contractAdmin[0] || master.beamio_Admins[0];
  if (!adminPk) throw new Error("需配置 ADDRESS_PGP_ADMIN_PK，或 ~/.master.json 中 settle_contractAdmin/beamio_Admins 至少一个为已有 admin");

  const addressPGP = getAddressPGPAddress();
  if (!addressPGP) throw new Error("需配置 ADDRESS_PGP 或存在 deployments/conet-AddressPGP.json");

  const provider = new ethers.JsonRpcProvider(CONET_RPC);
  const signer = new ethers.Wallet(adminPk, provider);
  const addresses = master.beamio_Admins.map((pk: string) => new ethers.Wallet(pk).address);

  console.log("=".repeat(60));
  console.log("登记 beamio_Admins 为 AddressPGP Admin");
  console.log("=".repeat(60));
  console.log("AddressPGP:", addressPGP);
  console.log("Signer (admin):", signer.address);
  console.log("待登记地址数:", addresses.length);
  addresses.forEach((a, i) => console.log(`  ${i + 1}. ${a}`));
  console.log();

  const contract = new ethers.Contract(addressPGP, AddressPGPABI, signer);

  const signerIsAdmin = await contract.adminList(signer.address);
  if (!signerIsAdmin) {
    console.error("\n❌ 当前 signer (" + signer.address + ") 不是 AddressPGP admin，无法执行 changeAddressInAdminlist");
    console.error("请设置 ADDRESS_PGP_ADMIN_PK 为部署该合约的 deployer 私钥，或任一已登记 admin 的私钥");
    process.exit(1);
  }

  for (let i = 0; i < addresses.length; i++) {
    const addr = addresses[i];
    let already = false;
    try {
      already = await contract.adminList(addr);
    } catch (_) {}
    if (already) {
      console.log(`[${i + 1}/${addresses.length}] ${addr} 已是 admin，跳过`);
      continue;
    }
    try {
      const tx = await contract.changeAddressInAdminlist(addr, true);
      console.log(`[${i + 1}/${addresses.length}] changeAddressInAdminlist(${addr}, true) tx: ${tx.hash}`);
      await tx.wait();
      console.log(`  ✅ 已登记`);
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
