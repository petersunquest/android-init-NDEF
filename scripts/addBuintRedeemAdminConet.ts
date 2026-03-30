/**
 * 由当前 Hardhat 签名者（须已是 BuintRedeemAirdrop.redeemAdmins）链上添加新的 Redeem Admin。
 *
 * 用法:
 *   npx hardhat run scripts/addBuintRedeemAdminConet.ts --network conet -- 0xNewAdmin...
 * 或:
 *   NEW_REDEEM_ADMIN=0x... npx hardhat run scripts/addBuintRedeemAdminConet.ts --network conet
 *
 * BuintRedeemAirdrop 地址来自 deployments/conet-addresses.json
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");

async function main() {
  const argAdmin = process.argv.find((a, i) => i >= 2 && a.startsWith("0x") && a.length === 42);
  const newAdmin = (process.env.NEW_REDEEM_ADMIN || argAdmin || "").trim();

  if (!newAdmin || !/^0x[a-fA-F0-9]{40}$/.test(newAdmin)) {
    throw new Error("请提供新管理员地址: argv 0x... 或环境变量 NEW_REDEEM_ADMIN");
  }

  if (!fs.existsSync(ADDRESSES_PATH)) {
    throw new Error("缺少 deployments/conet-addresses.json");
  }
  const addrData = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
  const redeemAddr = addrData.BuintRedeemAirdrop as string;
  if (!redeemAddr || !/^0x[a-fA-F0-9]{40}$/i.test(redeemAddr)) {
    throw new Error("conet-addresses.json 中无有效 BuintRedeemAirdrop");
  }

  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  const me = await signer.getAddress();

  const redeem = await ethers.getContractAt(
    [
      "function redeemAdmins(address) view returns (bool)",
      "function addRedeemAdmin(address account) external",
    ],
    redeemAddr,
    signer
  );

  const iAmAdmin = await redeem.redeemAdmins(me);
  if (!iAmAdmin) {
    throw new Error(`当前签名者 ${me} 不是 BuintRedeemAirdrop redeem admin，无法用其添加他人`);
  }

  const normalized = ethers.getAddress(newAdmin);
  const already = await redeem.redeemAdmins(normalized);
  if (already) {
    console.log("该地址已是 redeem admin，跳过:", normalized);
    return;
  }

  console.log("BuintRedeemAirdrop:", redeemAddr);
  console.log("Signer (admin):", me);
  console.log("Adding redeem admin:", normalized);

  const tx = await redeem.addRedeemAdmin(normalized);
  console.log("tx:", tx.hash);
  await tx.wait();
  console.log("addRedeemAdmin OK");

  const deployPath = path.join(__dirname, "..", "deployments", "conet-BuintRedeemAirdrop.json");
  if (fs.existsSync(deployPath)) {
    const j = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
    const list: string[] = j.contracts?.BuintRedeemAirdrop?.redeemAdmins;
    if (Array.isArray(list) && !list.map((a) => a.toLowerCase()).includes(normalized.toLowerCase())) {
      list.push(normalized);
      fs.writeFileSync(deployPath, JSON.stringify(j, null, 2) + "\n", "utf-8");
      console.log("已更新 conet-BuintRedeemAirdrop.json redeemAdmins 文档");
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
