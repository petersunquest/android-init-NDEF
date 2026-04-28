/**
 * 由已有 redeemAdmin 调用 BusinessStartKetRedeem.addRedeemAdmin(newAdmin)。
 *
 * 运行: npx hardhat run scripts/addBusinessStartKetRedeemAdminConet.ts --network conet
 *
 * 签名者: hardhat `conet` 网络的 accounts（默认 ~/.master.json settle_contractAdmin[0]）。
 * 目标地址: 环境变量 REDEEM_ADMIN_TO_ADD，缺省为本次要添加的地址。
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DEFAULT_NEW_REDEEM_ADMIN = "0xc4c14f2A7566B7176a98E6D4E2fF9961C5D05d95";

const REDEEM_ABI = [
  "function redeemAdmins(address) view returns (bool)",
  "function addRedeemAdmin(address) external",
] as const;

async function main() {
  const { ethers: ethersHH } = await networkModule.connect();
  const [signer] = await ethersHH.getSigners();
  if (!signer) {
    throw new Error("无签名者：请配置 ~/.master.json settle_contractAdmin[0] 或 conet 网络 accounts");
  }

  const rawTarget = (process.env.REDEEM_ADMIN_TO_ADD || DEFAULT_NEW_REDEEM_ADMIN).trim();
  if (!ethers.isAddress(rawTarget)) {
    throw new Error(`无效地址: ${rawTarget}`);
  }
  const newAdmin = ethers.getAddress(rawTarget);

  const addrPath = path.join(__dirname, "..", "deployments", "conet-addresses.json");
  if (!fs.existsSync(addrPath)) throw new Error("缺少 deployments/conet-addresses.json");
  const addrData = JSON.parse(fs.readFileSync(addrPath, "utf-8"));
  const redeemAddr = addrData.BusinessStartKetRedeem as string | undefined;
  if (!redeemAddr || !ethers.isAddress(redeemAddr)) {
    throw new Error("conet-addresses.json 缺少 BusinessStartKetRedeem");
  }

  const redeem = new ethers.Contract(redeemAddr, REDEEM_ABI, signer);

  console.log("BusinessStartKetRedeem:", redeemAddr);
  console.log("signer (must be redeemAdmin):", signer.address);
  console.log("new redeemAdmin:", newAdmin);

  const signerOk = await redeem.redeemAdmins(signer.address);
  if (!signerOk) {
    throw new Error(`当前签名者 ${signer.address} 不是该合约的 redeemAdmin，无法 addRedeemAdmin`);
  }

  if (await redeem.redeemAdmins(newAdmin)) {
    console.log("目标已是 redeemAdmin，跳过。");
    return;
  }

  const tx = await redeem.addRedeemAdmin(newAdmin);
  console.log("tx:", tx.hash);
  await tx.wait();
  console.log("addRedeemAdmin 已确认。");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
