/**
 * Relayer 代付 gas：调用 BuintRedeemAirdrop.redeemWithCodeFor。
 *
 * 用户侧先用 beamio.app `signBuintRedeemWithCode`（或等价 EIP-712）产出 signature。
 *
 * 环境变量:
 *   REDEEM_RECIPIENT  领取 B-Unit 免费池的地址
 *   REDEEM_CODE       与链上 create 时一致的明文字符串
 *   REDEEM_DEADLINE   unix 秒，须 >= block.timestamp
 *   REDEEM_SIGNATURE  0x 开头 hex（用户签名的 RedeemWithCode）
 *
 * 运行: npx hardhat run scripts/relayBuintRedeemConet.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");

async function main() {
  const recipient = (process.env.REDEEM_RECIPIENT ?? "").trim();
  const code = process.env.REDEEM_CODE ?? "";
  const deadlineStr = (process.env.REDEEM_DEADLINE ?? "").trim();
  const signature = (process.env.REDEEM_SIGNATURE ?? "").trim();

  if (!recipient || !code || !deadlineStr || !signature) {
    throw new Error(
      "需要 REDEEM_RECIPIENT, REDEEM_CODE, REDEEM_DEADLINE, REDEEM_SIGNATURE"
    );
  }
  const deadline = BigInt(deadlineStr);
  if (!signature.startsWith("0x") || signature.length < 130) {
    throw new Error("REDEEM_SIGNATURE 应为 hex");
  }

  const addrData = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
  const redeemAddr = addrData.BuintRedeemAirdrop as string;
  if (!redeemAddr) throw new Error("conet-addresses.json 缺少 BuintRedeemAirdrop");

  const { ethers } = await networkModule.connect();
  const [relayer] = await ethers.getSigners();

  const abi = [
    "function redeemWithCodeFor(address recipient, string code, uint256 deadline, bytes signature) external",
  ];
  const c = new ethers.Contract(redeemAddr, abi, relayer);
  console.log("relayer:", await relayer.getAddress());
  console.log("redeem contract:", redeemAddr);
  const tx = await c.redeemWithCodeFor!(recipient, code, deadline, signature);
  console.log("tx:", tx.hash);
  await tx.wait();
  console.log("redeemWithCodeFor OK");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
