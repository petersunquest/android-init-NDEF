/**
 * 配置已部署的 ValidatorDepositRedeem（CoNET）：
 *   - setDepositContract(0x4242…4242)
 *   - 部署 ValidatorNodeRewardIndexer（若尚未部署）
 *   - setRewardIndexer(indexer)
 *
 * 运行:
 *   npx hardhat run scripts/configureValidatorDepositRedeemConet.ts --network conet
 *
 * 可选环境变量:
 *   VALIDATOR_DEPOSIT_REDEEM=0x…     覆盖 redeem 地址（默认 deployments/conet-addresses.json）
 *   CONET_DEPOSIT_CONTRACT=0x4242…   覆盖 beacon deposit 地址
 *   VALIDATOR_NODE_REWARD_INDEXER=0x…  已有 indexer 时跳过部署，仅 setRewardIndexer
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";
import { mergeConetAdminPrivateKeysFromMasterFile } from "./utils/conetMasterAdmins.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

const DEFAULT_DEPOSIT = "0x4242424242424242424242424242424242424242";

const REDEEM_ABI = [
  "function depositContract() view returns (address)",
  "function rewardIndexer() view returns (address)",
  "function setDepositContract(address depositContract_) external",
  "function setRewardIndexer(address rewardIndexer_) external",
] as const;

function loadRedeemAddress(): string {
  const env = process.env.VALIDATOR_DEPOSIT_REDEEM?.trim();
  if (env && ethers.isAddress(env)) return ethers.getAddress(env);
  const addrPath = path.join(root, "deployments", "conet-addresses.json");
  if (!fs.existsSync(addrPath)) throw new Error("缺少 deployments/conet-addresses.json");
  const data = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as { ValidatorDepositRedeem?: string };
  const raw = data.ValidatorDepositRedeem?.trim();
  if (!raw || !ethers.isAddress(raw)) throw new Error("conet-addresses.json 缺少 ValidatorDepositRedeem");
  return ethers.getAddress(raw);
}

function loadInitialAdmin(): string {
  const env = process.env.VALIDATOR_DEPOSIT_REDEEM_INITIAL_ADMIN?.trim();
  if (env && ethers.isAddress(env)) return ethers.getAddress(env);
  const deployPath = path.join(root, "deployments", "conet-ValidatorDepositRedeem.json");
  if (fs.existsSync(deployPath)) {
    const d = JSON.parse(fs.readFileSync(deployPath, "utf-8")) as { initialRedeemAdmin?: string };
    if (d.initialRedeemAdmin && ethers.isAddress(d.initialRedeemAdmin)) {
      return ethers.getAddress(d.initialRedeemAdmin);
    }
  }
  const pks = mergeConetAdminPrivateKeysFromMasterFile();
  if (!pks.length) throw new Error("无可用 admin 私钥（~/.master.json）");
  return new ethers.Wallet(pks[0]).address;
}

function loadDepositContract(): string {
  const env = process.env.CONET_DEPOSIT_CONTRACT?.trim();
  const raw = env || DEFAULT_DEPOSIT;
  if (!ethers.isAddress(raw)) throw new Error("CONET_DEPOSIT_CONTRACT 无效");
  return ethers.getAddress(raw);
}

function loadExistingRewardIndexer(): string | null {
  const env = process.env.VALIDATOR_NODE_REWARD_INDEXER?.trim();
  if (env && ethers.isAddress(env)) {
    const a = ethers.getAddress(env);
    return a === ethers.ZeroAddress ? null : a;
  }
  const addrPath = path.join(root, "deployments", "conet-addresses.json");
  if (!fs.existsSync(addrPath)) return null;
  const data = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as { ValidatorNodeRewardIndexer?: string };
  const raw = data.ValidatorNodeRewardIndexer?.trim();
  if (!raw || !ethers.isAddress(raw)) return null;
  const a = ethers.getAddress(raw);
  return a === ethers.ZeroAddress ? null : a;
}

function persistRewardIndexer(indexerAddr: string, txHash?: string) {
  const addrPath = path.join(root, "deployments", "conet-addresses.json");
  if (fs.existsSync(addrPath)) {
    const merged = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, unknown>;
    merged.ValidatorNodeRewardIndexer = indexerAddr;
    if (txHash) merged.validatorNodeRewardIndexerTx = txHash;
    merged.validatorNodeRewardIndexerConfiguredAt = new Date().toISOString();
    fs.writeFileSync(addrPath, JSON.stringify(merged, null, 2) + "\n", "utf-8");
    console.log("updated deployments/conet-addresses.json");
  }

  const deployPath = path.join(root, "deployments", "conet-ValidatorDepositRedeem.json");
  if (fs.existsSync(deployPath)) {
    const d = JSON.parse(fs.readFileSync(deployPath, "utf-8")) as Record<string, unknown>;
    const contracts = (d.contracts ?? {}) as Record<string, unknown>;
    contracts.ValidatorNodeRewardIndexer = {
      address: indexerAddr,
      ...(txHash ? { transactionHash: txHash } : {}),
    };
    d.contracts = contracts;
    d.rewardIndexer = indexerAddr;
    d.depositContract = loadDepositContract();
    fs.writeFileSync(deployPath, JSON.stringify(d, null, 2) + "\n", "utf-8");
    console.log("updated deployments/conet-ValidatorDepositRedeem.json");
  }
}

async function main() {
  const { ethers: ethersHH } = await networkModule.connect();
  const [signer] = await ethersHH.getSigners();
  const net = await ethersHH.provider.getNetwork();
  if (net.chainId !== 224422n) {
    throw new Error(`期望 chainId 224422，当前 ${net.chainId}`);
  }

  const redeemAddr = loadRedeemAddress();
  const depositAddr = loadDepositContract();
  const initialAdmin = loadInitialAdmin();

  console.log("=".repeat(60));
  console.log("Configure ValidatorDepositRedeem on CoNET");
  console.log("=".repeat(60));
  console.log("signer:", signer.address);
  console.log("redeem:", redeemAddr);
  console.log("depositContract:", depositAddr);
  console.log("rewardIndexer admin:", initialAdmin);
  console.log("balance:", ethers.formatEther(await ethersHH.provider.getBalance(signer.address)), "CNET\n");

  const redeem = new ethers.Contract(redeemAddr, REDEEM_ABI, signer);

  const curDeposit = ethers.getAddress(await redeem.depositContract());
  if (curDeposit === ethers.ZeroAddress) {
    console.log("setDepositContract →", depositAddr);
    const tx = await redeem.setDepositContract(depositAddr);
    const rc = await tx.wait();
    console.log("  tx:", rc?.hash);
  } else if (curDeposit.toLowerCase() === depositAddr.toLowerCase()) {
    console.log("depositContract already set:", curDeposit);
  } else {
    console.warn("depositContract already set to different address:", curDeposit, "(skip)");
  }

  let indexerAddr = loadExistingRewardIndexer();
  const curIndexer = ethers.getAddress(await redeem.rewardIndexer());

  if (indexerAddr) {
    const code = await ethersHH.provider.getCode(indexerAddr);
    if (!code || code === "0x") {
      console.warn("VALIDATOR_NODE_REWARD_INDEXER 无 bytecode，将重新部署");
      indexerAddr = null;
    } else {
      console.log("existing ValidatorNodeRewardIndexer:", indexerAddr);
      const indexerRead = new ethers.Contract(
        indexerAddr,
        ["function redeem() view returns (address)", "function setRedeem(address) external"],
        signer
      );
      const idxRedeem = ethers.getAddress(await indexerRead.redeem());
      if (idxRedeem.toLowerCase() !== redeemAddr.toLowerCase()) {
        console.log("indexer.setRedeem →", redeemAddr, "(was", idxRedeem, ")");
        const tx = await indexerRead.setRedeem(redeemAddr);
        const rc = await tx.wait();
        console.log("  tx:", rc?.hash);
      }
    }
  }

  let indexerDeployTx = "";
  if (!indexerAddr) {
    const IndexerFactory = await ethersHH.getContractFactory("ValidatorNodeRewardIndexer");
    const indexer = await IndexerFactory.deploy(initialAdmin, redeemAddr);
    await indexer.waitForDeployment();
    indexerAddr = await indexer.getAddress();
    indexerDeployTx = indexer.deploymentTransaction()?.hash ?? "";
    console.log("ValidatorNodeRewardIndexer deployed:", indexerAddr);
    console.log("  tx:", indexerDeployTx);
    persistRewardIndexer(indexerAddr, indexerDeployTx || undefined);
  }

  if (curIndexer === ethers.ZeroAddress) {
    console.log("setRewardIndexer →", indexerAddr);
    const tx = await redeem.setRewardIndexer(indexerAddr);
    const rc = await tx.wait();
    console.log("  tx:", rc?.hash);
  } else if (curIndexer.toLowerCase() === indexerAddr!.toLowerCase()) {
    console.log("rewardIndexer already set:", curIndexer);
  } else {
    console.warn("rewardIndexer already set to different address:", curIndexer, "(skip setRewardIndexer)");
  }

  // 最终链上读回
  const finalDeposit = ethers.getAddress(await redeem.depositContract());
  const finalIndexer = ethers.getAddress(await redeem.rewardIndexer());
  console.log("\n--- on-chain ---");
  console.log("depositContract:", finalDeposit);
  console.log("rewardIndexer:", finalIndexer);

  if (finalDeposit === ethers.ZeroAddress || finalIndexer === ethers.ZeroAddress) {
    throw new Error("配置未完成：depositContract 或 rewardIndexer 仍为零地址");
  }

  if (!loadExistingRewardIndexer() && indexerAddr) {
    persistRewardIndexer(indexerAddr, indexerDeployTx || undefined);
  }

  console.log("\n下一步:");
  console.log("  npx tsx scripts/updateConetReferences.ts");
  console.log("  npx tsx scripts/verifyValidatorDepositRedeemStackConet.ts ValidatorNodeRewardIndexer  # 若已加入 verify 目标");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
