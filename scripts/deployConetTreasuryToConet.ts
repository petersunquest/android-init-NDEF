/**
 * 部署 ConetTreasury 到 CoNET mainnet
 *
 * 1. 部署 ConetTreasury（initialOwner = deployer, guardianNodesInfoV6 = 0xCd68C3FFFE403f9F26081807c77aB29a4DF6940D）
 * 2. BUnitAirdrop.addAdmin(conetTreasuryAddress) 使 ConetTreasury 可调用 mintForUsdcPurchase
 * 3. ConetTreasury.setBUnitAirdrop(bunitAirdropAddress)
 *
 * minerCount 自动从 GuardianNodesInfoV6.getUniqueOwnerCount() 获取，无需手动设置。
 *
 * 运行: npx hardhat run scripts/deployConetTreasuryToConet.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const MASTER_PATH = path.join(homedir(), ".master.json");

function loadMasterSetup(): { settle_contractAdmin: string[] } {
  if (!fs.existsSync(MASTER_PATH)) throw new Error("未找到 ~/.master.json");
  const data = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  if (!data?.settle_contractAdmin?.length) throw new Error("~/.master.json 中 settle_contractAdmin 为空");
  return {
    settle_contractAdmin: data.settle_contractAdmin.map((pk: string) =>
      pk.startsWith("0x") ? pk : `0x${pk}`
    ),
  };
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const master = loadMasterSetup();

  const settleAddresses = master.settle_contractAdmin.map((pk: string) =>
    new ethers.Wallet(pk).address
  );
  if (!settleAddresses.includes(deployer.address)) {
    console.warn(
      "警告: 部署者",
      deployer.address,
      "不在 settle_contractAdmin 中。"
    );
  }

  console.log("=".repeat(60));
  console.log("Deploy ConetTreasury on CoNET mainnet");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("chainId:", net.chainId.toString());
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("balance:", ethers.formatEther(balance), "CNET\n");

  // 1. Deploy ConetTreasury（miner 鉴定使用 GuardianNodesInfoV6）
  const GUARDIAN_NODES_V6 = process.env.GUARDIAN_NODES || "0xCd68C3FFFE403f9F26081807c77aB29a4DF6940D";
  const ConetTreasuryFactory = await ethers.getContractFactory("ConetTreasury");
  const treasury = await ConetTreasuryFactory.deploy(deployer.address, GUARDIAN_NODES_V6);
  await treasury.waitForDeployment();
  const treasuryAddress = await treasury.getAddress();
  console.log("[1] ConetTreasury deployed:", treasuryAddress);

  // 2. BUnitAirdrop.addAdmin(conetTreasury) - 使 ConetTreasury 可调用 mintForUsdcPurchase
  const airdropPath = path.join(__dirname, "..", "deployments", "conet-BUintAirdrop.json");
  if (!fs.existsSync(airdropPath)) {
    console.warn("[2] 未找到 conet-BUintAirdrop.json，跳过 BUnitAirdrop.addAdmin");
  } else {
    const airdropData = JSON.parse(fs.readFileSync(airdropPath, "utf-8"));
    const airdropAddress = airdropData?.contracts?.BUnitAirdrop?.address;
    if (airdropAddress) {
      const airdrop = await ethers.getContractAt("BUnitAirdrop", airdropAddress);
      const txAddAdmin = await airdrop.addAdmin(treasuryAddress);
      await txAddAdmin.wait();
      console.log("[2] BUnitAirdrop.addAdmin(ConetTreasury) ok");

      // 3. ConetTreasury.setBUnitAirdrop
      const txSet = await treasury.setBUnitAirdrop(airdropAddress);
      await txSet.wait();
      console.log("[3] ConetTreasury.setBUnitAirdrop ok");
    } else {
      console.warn("[2] conet-BUintAirdrop.json 中无 BUnitAirdrop 地址，跳过");
    }
  }

  // minerCount 自动从 GuardianNodesInfoV6.getUniqueOwnerCount() 获取
  let minerCount = "0";
  try {
    const GuardianNodesABI = ["function getUniqueOwnerCount() view returns (uint256)"];
    const guardian = await ethers.getContractAt(GuardianNodesABI, GUARDIAN_NODES_V6);
    minerCount = (await guardian.getUniqueOwnerCount()).toString();
    console.log("[4] GuardianNodesInfoV6.getUniqueOwnerCount() =", minerCount);
    console.log("    ConetTreasury.requiredVotes() =", (await treasury.requiredVotes()).toString());
  } catch (e) {
    console.warn("[4] GuardianNodesInfoV6.getUniqueOwnerCount() 调用失败，跳过:", (e as Error).message);
  }

  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      ConetTreasury: {
        address: treasuryAddress,
        owner: deployer.address,
        guardianNodesInfoV6: GUARDIAN_NODES_V6,
        minerCount,
        bUnitAirdrop: (() => {
          const airdropPath = path.join(__dirname, "..", "deployments", "conet-BUintAirdrop.json");
          if (!fs.existsSync(airdropPath)) return undefined;
          const d = JSON.parse(fs.readFileSync(airdropPath, "utf-8"));
          return d?.contracts?.BUnitAirdrop?.address;
        })(),
      },
    },
  };

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });
  const outPath = path.join(deploymentsDir, "conet-ConetTreasury.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("\nsaved:", outPath);
  console.log("\nConetTreasury 地址:", treasuryAddress);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
