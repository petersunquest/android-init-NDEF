/**
 * ValidatorDepositRedeem（CoNET）redeem admin / contract admin 链上增删。
 *
 * Redeem admin（redeemAdmins）：创建/取消 redeem、配置 tokens/deposit/guardian 等。
 * Contract admin（admins）：仅 withdrawNative / withdrawNativeBatch。
 *
 * 用法（可组合）:
 *   REMOVE_REDEEM_ADMIN=0x... NEW_REDEEM_ADMIN=0x... \\
 *     npx hardhat run scripts/manageValidatorDepositRedeemAdminConet.ts --network conet
 *
 *   ADD_CONTRACT_ADMIN=0x... / REMOVE_CONTRACT_ADMIN=0x... （须当前签名者为 contract admin）
 *
 * 约束（链上）:
 *   - removeRedeemAdmin / removeAdmin：不能移除自己（msg.sender == account 会 revert）
 *   - addRedeemAdmin：须 redeem admin 签名
 *   - addAdmin / removeAdmin：须 contract admin 签名
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const DEPLOY_PATH = path.join(__dirname, "..", "deployments", "conet-ValidatorDepositRedeem.json");

const REDEEM_ABI = [
  "function redeemAdmins(address account) view returns (bool)",
  "function admins(address account) view returns (bool)",
  "function addRedeemAdmin(address account) external",
  "function removeRedeemAdmin(address account) external",
  "function addAdmin(address account) external",
  "function removeAdmin(address account) external",
] as const;

function envAddr(key: string): string | null {
  const raw = process.env[key]?.trim();
  if (!raw) return null;
  if (!ethers.isAddress(raw)) throw new Error(`${key} 非法地址: ${raw}`);
  return ethers.getAddress(raw);
}

function syncDeployJson(patch: { redeemAdmins?: string[]; contractAdmins?: string[] }) {
  if (!fs.existsSync(DEPLOY_PATH)) return;
  const j = JSON.parse(fs.readFileSync(DEPLOY_PATH, "utf-8")) as Record<string, unknown>;
  if (patch.redeemAdmins) j.redeemAdmins = patch.redeemAdmins;
  if (patch.contractAdmins) j.contractAdmins = patch.contractAdmins;
  fs.writeFileSync(DEPLOY_PATH, JSON.stringify(j, null, 2) + "\n", "utf-8");
  console.log("已更新 conet-ValidatorDepositRedeem.json");
}

async function main() {
  const removeRedeem = envAddr("REMOVE_REDEEM_ADMIN");
  const addRedeem = envAddr("NEW_REDEEM_ADMIN") ?? envAddr("ADD_REDEEM_ADMIN");
  const removeContract = envAddr("REMOVE_CONTRACT_ADMIN");
  const addContract = envAddr("ADD_CONTRACT_ADMIN");

  if (!removeRedeem && !addRedeem && !removeContract && !addContract) {
    throw new Error(
      "请设置 REMOVE_REDEEM_ADMIN / NEW_REDEEM_ADMIN / ADD_CONTRACT_ADMIN / REMOVE_CONTRACT_ADMIN 至少一项",
    );
  }

  if (!fs.existsSync(ADDRESSES_PATH)) throw new Error("缺少 deployments/conet-addresses.json");
  const addrData = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8")) as { ValidatorDepositRedeem?: string };
  const redeemAddr = addrData.ValidatorDepositRedeem?.trim();
  if (!redeemAddr || !ethers.isAddress(redeemAddr)) {
    throw new Error("conet-addresses.json 中无有效 ValidatorDepositRedeem");
  }

  const { ethers: ethersHH } = await networkModule.connect();
  const [signer] = await ethersHH.getSigners();
  const me = await signer.getAddress();
  const c = await ethersHH.getContractAt([...REDEEM_ABI], redeemAddr, signer);

  console.log("ValidatorDepositRedeem:", redeemAddr);
  console.log("Signer:", me);

  let redeemList: string[] = [];
  let contractList: string[] = [];
  if (fs.existsSync(DEPLOY_PATH)) {
    const j = JSON.parse(fs.readFileSync(DEPLOY_PATH, "utf-8")) as {
      redeemAdmins?: string[];
      contractAdmins?: string[];
    };
    redeemList = Array.isArray(j.redeemAdmins) ? [...j.redeemAdmins] : [];
    contractList = Array.isArray(j.contractAdmins) ? [...j.contractAdmins] : [];
  }

  if (removeRedeem || addRedeem) {
    const iAmRedeem = await c.redeemAdmins(me);
    if (!iAmRedeem) {
      throw new Error(`签名者 ${me} 不是 redeem admin，无法 add/remove redeemAdmins`);
    }
  }

  if (removeRedeem) {
    if (removeRedeem.toLowerCase() === me.toLowerCase()) {
      throw new Error("removeRedeemAdmin 不能移除自己；请用其他 redeem admin 签名");
    }
    const isAdmin = await c.redeemAdmins(removeRedeem);
    if (!isAdmin) {
      console.log("redeem admin 已不存在，跳过 remove:", removeRedeem);
    } else {
      console.log("removeRedeemAdmin:", removeRedeem);
      const tx = await c.removeRedeemAdmin(removeRedeem);
      console.log("tx:", tx.hash);
      await tx.wait();
      console.log("removeRedeemAdmin OK");
    }
    redeemList = redeemList.filter((a) => a.toLowerCase() !== removeRedeem.toLowerCase());
  }

  if (addRedeem) {
    const already = await c.redeemAdmins(addRedeem);
    if (already) {
      console.log("已是 redeem admin，跳过 add:", addRedeem);
    } else {
      console.log("addRedeemAdmin:", addRedeem);
      const tx = await c.addRedeemAdmin(addRedeem);
      console.log("tx:", tx.hash);
      await tx.wait();
      console.log("addRedeemAdmin OK");
    }
    if (!redeemList.map((a) => a.toLowerCase()).includes(addRedeem.toLowerCase())) {
      redeemList.push(addRedeem);
    }
  }

  if (removeContract || addContract) {
    const iAmContract = await c.admins(me);
    if (!iAmContract) {
      throw new Error(`签名者 ${me} 不是 contract admin，无法 add/remove admins`);
    }
  }

  if (removeContract) {
    if (removeContract.toLowerCase() === me.toLowerCase()) {
      throw new Error("removeAdmin 不能移除自己；请用其他 contract admin 签名");
    }
    const isAdmin = await c.admins(removeContract);
    if (!isAdmin) {
      console.log("contract admin 已不存在，跳过 remove:", removeContract);
    } else {
      console.log("removeAdmin:", removeContract);
      const tx = await c.removeAdmin(removeContract);
      console.log("tx:", tx.hash);
      await tx.wait();
      console.log("removeAdmin OK");
    }
    contractList = contractList.filter((a) => a.toLowerCase() !== removeContract.toLowerCase());
  }

  if (addContract) {
    const already = await c.admins(addContract);
    if (already) {
      console.log("已是 contract admin，跳过 add:", addContract);
    } else {
      console.log("addAdmin:", addContract);
      const tx = await c.addAdmin(addContract);
      console.log("tx:", tx.hash);
      await tx.wait();
      console.log("addAdmin OK");
    }
    if (!contractList.map((a) => a.toLowerCase()).includes(addContract.toLowerCase())) {
      contractList.push(addContract);
    }
  }

  syncDeployJson({
    redeemAdmins: redeemList.length ? redeemList : undefined,
    contractAdmins: contractList.length ? contractList : undefined,
  });

  console.log("\n链上状态:");
  for (const a of redeemList) {
    console.log("  redeemAdmins", a, "=", await c.redeemAdmins(a));
  }
  for (const a of contractList) {
    console.log("  admins", a, "=", await c.admins(a));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
