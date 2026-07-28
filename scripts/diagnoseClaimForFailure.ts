/**
 * 诊断 Conet 链上 claimFor 交易失败原因。
 * 用法: npx hardhat run scripts/diagnoseClaimForFailure.ts --network conet
 *
 * 失败交易: 0xce2f0bb8e103a509be11bd81ddf8df133a7a9256f1036362623823e294675401
 * 参数: claimant=0xd5B0046D166266C51143e1221811672958c89ea3, nonce=0, deadline=1772823954
 */

import { network } from "hardhat";

const BUNIT_AIRDROP = "0xbE1CF54f76BcAb40DC49cDcD7FBA525b9ABDa264";
const FAILED_TX_HASH = "0xce2f0bb8e103a509be11bd81ddf8df133a7a9256f1036362623823e294675401";

const CLAIMANT_RAW = "0xd5b0046d166266c51143e1221811672958c89ea3";
const NONCE = 0n;
const DEADLINE = 1772823954n;
const SIGNATURE =
  "0x6f6ae4326f98f012c57a519e6436555b2f41139712f298729e97ee4d93673f14551276f10d6d4382885115e9e007c01dc40a3729876450f4cb35908704800b0c1c";

async function main() {
  const { ethers } = await network.connect();
  const provider = ethers.provider;
  const CLAIMANT = ethers.getAddress(CLAIMANT_RAW);

  const airdrop = await ethers.getContractAt("BUnitAirdrop", BUNIT_AIRDROP);

  console.log("=".repeat(70));
  console.log("claimFor 失败诊断");
  console.log("=".repeat(70));
  console.log("Tx hash:", FAILED_TX_HASH);
  console.log("Claimant:", CLAIMANT);
  console.log("Nonce:", NONCE.toString());
  console.log("Deadline:", DEADLINE.toString(), `(${new Date(Number(DEADLINE) * 1000).toISOString()})`);
  console.log("");

  // 1. 检查交易详情
  const tx = await provider.getTransaction(FAILED_TX_HASH);
  if (!tx) {
    console.log("❌ 无法获取交易，可能 hash 错误或网络问题");
    return;
  }
  const receipt = await provider.getTransactionReceipt(FAILED_TX_HASH);
  console.log("交易状态:", receipt?.status === 1 ? "成功" : "失败");
  console.log("Block:", receipt?.blockNumber ?? "pending");
  console.log("");

  // 2. 当前链上状态
  const block = await provider.getBlock("latest");
  const now = block?.timestamp ?? Math.floor(Date.now() / 1000);
  console.log("--- 链上状态 ---");
  console.log("当前 block.timestamp:", now, `(${new Date(now * 1000).toISOString()})`);

  const hasClaimed = await airdrop.hasClaimed(CLAIMANT);
  const claimNonces = await airdrop.claimNonces(CLAIMANT);

  console.log("hasClaimed(claimant):", hasClaimed);
  console.log("claimNonces(claimant):", claimNonces.toString());
  console.log("");

  // 3. 逐项检查 claimFor 的 revert 条件
  console.log("--- 失败原因分析 ---");

  if (Number(now) > Number(DEADLINE)) {
    console.log("❌ SignatureExpired: block.timestamp > deadline");
  } else {
    console.log("✓ deadline 未过期");
  }

  if (claimNonces !== NONCE) {
    console.log(
      `❌ InvalidSignature (nonce 不匹配): claimNonces[claimant]=${claimNonces} != nonce=${NONCE}`
    );
    console.log(
      "   可能原因: 该地址之前已成功 claimFor 过，nonce 已递增。需使用 nonce=",
      claimNonces.toString()
    );
  } else {
    console.log("✓ nonce 匹配");
  }

  // 4. 验证签名
  const digest = await airdrop.getClaimDigest(CLAIMANT, NONCE, DEADLINE);
  const recovered = ethers.recoverAddress(digest, SIGNATURE);
  console.log("");
  console.log("--- 签名验证 ---");
  console.log("Recovered signer:", recovered);
  console.log("Claimant:", CLAIMANT);
  if (recovered.toLowerCase() !== CLAIMANT.toLowerCase()) {
    console.log("❌ InvalidSignature: signer != claimant");
    console.log(
      "   可能原因: 1) 签名时使用了错误的 domain (verifyingContract/chainId) 2) 签名参数与链上不一致 3) 使用了错误的私钥"
    );
  } else {
    console.log("✓ 签名验证通过");
  }

  if (hasClaimed) {
    console.log("");
    console.log("❌ ClaimNotAvailable: 该地址已申领过 (hasClaimed=true)");
    console.log("   每人仅可申领一次，无法再次 claim");
  } else {
    console.log("");
    console.log("✓ hasClaimed=false，可申领");
  }

  // 5. 总结
  console.log("");
  console.log("--- 结论 ---");
  const reasons: string[] = [];
  if (Number(now) > Number(DEADLINE)) reasons.push("SignatureExpired");
  if (claimNonces !== NONCE) reasons.push("InvalidSignature(nonce)");
  if (recovered.toLowerCase() !== CLAIMANT.toLowerCase()) reasons.push("InvalidSignature(signer)");
  if (hasClaimed) reasons.push("ClaimNotAvailable");

  if (reasons.length > 0) {
    console.log("最可能的失败原因:", reasons.join(", "));
  } else {
    console.log("链上校验均通过。若交易仍失败，可能是: TransferFailed (mintReward 失败) 或 gas 不足");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
