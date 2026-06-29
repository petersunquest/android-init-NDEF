/**
 * 重部署被修改的 ValidatorNodeRewardIndexer 到 CoNET，并把主合约 rewardIndexer 指针切到新地址。
 *
 * 背景：ValidatorNodeRewardIndexer 由「设置绝对小时值 reportNodeRewardHourly」重构为
 *       「按区块小时桶累加 + eventKey 幂等 reportNodeReward」。它与 ValidatorDepositRedeem /
 *       ValidatorDepositRedeemStatsLib 的接口（getNodeRewardSummary / getBeneficiaryRewardSummary）
 *       未变，故仅需重部署 indexer 本身并 setRewardIndexer，关联合约无需重部署。
 *
 * 动作：
 *   1) 部署 ValidatorNodeRewardIndexer(initialRedeemAdmin, redeem)
 *   2) addAdmin 把 ~/.master.json 中全部 CoNET admin（含 relayer / Settle 钱包）加为 indexer admin
 *   3) redeem.setRewardIndexer(newIndexer)（覆盖旧指针）
 *   4) 旧 indexer 移入 DEPRECATED_VALIDATOR_NODE_REWARD_INDEXER，更新 deployments JSON
 *
 * 运行:
 *   npx hardhat run scripts/redeployValidatorNodeRewardIndexerConet.ts --network conet
 *
 * 部署后:
 *   npx tsx scripts/verifyValidatorDepositRedeemStackConet.ts ValidatorNodeRewardIndexer
 *   npx tsx scripts/updateConetReferences.ts
 *   npx tsx scripts/acceptValidatorDepositRedeemStackConet.ts
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";
import { mergeConetAdminAddressesFromMasterFile } from "./utils/conetMasterAdmins.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

const REDEEM_ABI = [
  "function rewardIndexer() view returns (address)",
  "function setRewardIndexer(address rewardIndexer_) external",
] as const;

const INDEXER_ABI = [
  "function admins(address account) view returns (bool)",
  "function redeem() view returns (address)",
  "function addAdmin(address account) external",
] as const;

function loadConetAddresses(): Record<string, unknown> {
  const addrPath = path.join(root, "deployments", "conet-addresses.json");
  if (!fs.existsSync(addrPath)) return {};
  return JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, unknown>;
}

function loadRedeemAddress(addrData: Record<string, unknown>): string {
  const env = process.env.VALIDATOR_DEPOSIT_REDEEM?.trim();
  if (env && ethers.isAddress(env)) return ethers.getAddress(env);
  const raw = typeof addrData.ValidatorDepositRedeem === "string" ? addrData.ValidatorDepositRedeem : "";
  if (!raw || !ethers.isAddress(raw)) throw new Error("conet-addresses.json 缺少 ValidatorDepositRedeem");
  return ethers.getAddress(raw);
}

function loadInitialAdmin(addrData: Record<string, unknown>, deployer: string): string {
  const env = process.env.VALIDATOR_DEPOSIT_REDEEM_INITIAL_ADMIN?.trim();
  if (env && ethers.isAddress(env)) return ethers.getAddress(env);
  const deployPath = path.join(root, "deployments", "conet-ValidatorDepositRedeem.json");
  if (fs.existsSync(deployPath)) {
    const d = JSON.parse(fs.readFileSync(deployPath, "utf-8")) as { initialRedeemAdmin?: string };
    if (d.initialRedeemAdmin && ethers.isAddress(d.initialRedeemAdmin)) return ethers.getAddress(d.initialRedeemAdmin);
  }
  void addrData;
  return ethers.getAddress(deployer);
}

async function main() {
  const { ethers: ethersHH } = await networkModule.connect();
  const [signer] = await ethersHH.getSigners();
  const net = await ethersHH.provider.getNetwork();
  if (net.chainId !== 224422n) throw new Error(`期望 chainId 224422，当前 ${net.chainId}`);

  const addrData = loadConetAddresses();
  const redeemAddr = loadRedeemAddress(addrData);
  const initialAdmin = loadInitialAdmin(addrData, signer.address);
  const oldIndexer =
    typeof addrData.ValidatorNodeRewardIndexer === "string" && ethers.isAddress(addrData.ValidatorNodeRewardIndexer)
      ? ethers.getAddress(addrData.ValidatorNodeRewardIndexer)
      : "";

  console.log("=".repeat(60));
  console.log("Redeploy ValidatorNodeRewardIndexer on CoNET");
  console.log("=".repeat(60));
  console.log("signer:", signer.address);
  console.log("chainId:", net.chainId.toString());
  console.log("redeem:", redeemAddr);
  console.log("initialAdmin:", initialAdmin);
  console.log("old indexer:", oldIndexer || "(none)");
  console.log("balance:", ethers.formatEther(await ethersHH.provider.getBalance(signer.address)), "CNET\n");

  // 1) deploy
  const Factory = await ethersHH.getContractFactory("ValidatorNodeRewardIndexer");
  const indexer = await Factory.deploy(initialAdmin, redeemAddr);
  await indexer.waitForDeployment();
  const newIndexer = await indexer.getAddress();
  const deployTx = indexer.deploymentTransaction()?.hash ?? "";
  console.log("ValidatorNodeRewardIndexer deployed:", newIndexer);
  if (deployTx) console.log("  tx:", deployTx);

  // sanity: redeem wired into indexer
  const idxRead = new ethers.Contract(newIndexer, INDEXER_ABI, signer);
  const idxRedeem = ethers.getAddress(await idxRead.redeem());
  if (idxRedeem.toLowerCase() !== redeemAddr.toLowerCase()) {
    throw new Error(`indexer.redeem mismatch: ${idxRedeem} != ${redeemAddr}`);
  }

  // 2) addAdmin for all CoNET admin wallets (relayer / Settle pool) so reportNodeReward works from any of them
  const adminAddrs = mergeConetAdminAddressesFromMasterFile().map((a) => ethers.getAddress(a));
  console.log(`\nadmin wallets from master.json: ${adminAddrs.length}`);
  for (const a of adminAddrs) {
    if (a.toLowerCase() === initialAdmin.toLowerCase()) {
      console.log("  already admin (constructor):", a);
      continue;
    }
    const isAdmin = await idxRead.admins(a);
    if (isAdmin) {
      console.log("  already admin:", a);
      continue;
    }
    const tx = await idxRead.addAdmin(a);
    await tx.wait();
    console.log("  addAdmin ok:", a);
  }

  // 3) setRewardIndexer override on the main redeem contract
  const redeem = new ethers.Contract(redeemAddr, REDEEM_ABI, signer);
  const cur = ethers.getAddress(await redeem.rewardIndexer());
  if (cur.toLowerCase() === newIndexer.toLowerCase()) {
    console.log("\nredeem.rewardIndexer already new:", cur);
  } else {
    console.log("\nredeem.setRewardIndexer →", newIndexer, "(was", cur, ")");
    const tx = await redeem.setRewardIndexer(newIndexer);
    const rc = await tx.wait();
    console.log("  tx:", rc?.hash);
  }
  const finalIdx = ethers.getAddress(await redeem.rewardIndexer());
  if (finalIdx.toLowerCase() !== newIndexer.toLowerCase()) {
    throw new Error(`setRewardIndexer 未生效: redeem.rewardIndexer=${finalIdx}`);
  }
  console.log("on-chain redeem.rewardIndexer:", finalIdx);

  // 4) persist deployments/*.json (deprecate old)
  const addrPath = path.join(root, "deployments", "conet-addresses.json");
  if (fs.existsSync(addrPath)) {
    const merged = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, unknown>;
    if (oldIndexer && oldIndexer.toLowerCase() !== newIndexer.toLowerCase()) {
      const dep = Array.isArray(merged.DEPRECATED_VALIDATOR_NODE_REWARD_INDEXER)
        ? (merged.DEPRECATED_VALIDATOR_NODE_REWARD_INDEXER as string[])
        : [];
      if (!dep.some((x) => x.toLowerCase() === oldIndexer.toLowerCase())) dep.push(oldIndexer);
      merged.DEPRECATED_VALIDATOR_NODE_REWARD_INDEXER = dep;
    }
    merged.ValidatorNodeRewardIndexer = newIndexer;
    if (deployTx) merged.validatorNodeRewardIndexerTx = deployTx;
    merged.validatorNodeRewardIndexerConfiguredAt = new Date().toISOString();
    fs.writeFileSync(addrPath, JSON.stringify(merged, null, 2) + "\n", "utf-8");
    console.log("\nupdated deployments/conet-addresses.json");
  }

  const deployPath = path.join(root, "deployments", "conet-ValidatorDepositRedeem.json");
  if (fs.existsSync(deployPath)) {
    const d = JSON.parse(fs.readFileSync(deployPath, "utf-8")) as Record<string, unknown>;
    const contracts = (d.contracts ?? {}) as Record<string, unknown>;
    contracts.ValidatorNodeRewardIndexer = {
      address: newIndexer,
      admin: initialAdmin,
      redeem: redeemAddr,
      ...(deployTx ? { transactionHash: deployTx } : {}),
    };
    d.contracts = contracts;
    d.rewardIndexer = newIndexer;
    fs.writeFileSync(deployPath, JSON.stringify(d, null, 2) + "\n", "utf-8");
    console.log("updated deployments/conet-ValidatorDepositRedeem.json");
  }

  console.log("\n下一步:");
  console.log("  npx tsx scripts/verifyValidatorDepositRedeemStackConet.ts ValidatorNodeRewardIndexer");
  console.log("  npx tsx scripts/updateConetReferences.ts");
  console.log("  npx tsx scripts/acceptValidatorDepositRedeemStackConet.ts");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
