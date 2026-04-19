/**
 * 部署 GuardianNodesInfoV6 到 CoNET mainnet
 *
 * 无构造函数参数，部署后 deployer 自动为 admin。
 * 部署后需将 settle_contractAdmin 加入 adminList，并迁移现有节点数据。
 *
 * 运行: npx hardhat run scripts/deployGuardianNodesInfoV6ToConet.ts --network conet
 */

import { network as hreNetwork } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { mergeConetAdminPrivateKeysFromMasterFile } from "./utils/conetMasterAdmins.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function loadMasterSetup(): { settle_contractAdmin: string[] } {
  const pks = mergeConetAdminPrivateKeysFromMasterFile();
  if (!pks.length) {
    throw new Error("~/.master.json 中无有效私钥（settle_contractAdmin / beamio_Admins / admin）");
  }
  return { settle_contractAdmin: pks };
}

async function main() {
  const { ethers } = await hreNetwork.connect();
  const [deployer] = await ethers.getSigners();
  const master = loadMasterSetup();
  const net = await ethers.provider.getNetwork();

  const settleAddresses = master.settle_contractAdmin.map((pk: string) =>
    new ethers.Wallet(pk).address
  );
  if (!settleAddresses.includes(deployer.address)) {
    console.warn("警告: 部署者", deployer.address, "不在 settle_contractAdmin 中。");
  }

  console.log("=".repeat(60));
  console.log("部署 GuardianNodesInfoV6 到 CoNET mainnet");
  console.log("=".repeat(60));
  console.log("部署账户:", deployer.address);
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("余额:", ethers.formatEther(balance), "CNET");
  console.log("ChainId:", net.chainId.toString());

  if (balance === 0n) {
    throw new Error("账户余额为 0，无法部署");
  }

  console.log("\n[1] 部署 GuardianNodesInfoV6...");
  const Factory = await ethers.getContractFactory("src/b-unit/GuardianNodesInfoV6.sol:GuardianNodesInfoV6");
  const contract = await Factory.deploy();
  await contract.waitForDeployment();
  const addr = await contract.getAddress();
  console.log("  GuardianNodesInfoV6:", addr);
  console.log("  部署账户已自动设为 admin");

  // 可选：将 settle_contractAdmin 加入 adminList
  console.log("\n[2] 添加 settle_contractAdmin 到 adminList...");
  for (const addr_ of settleAddresses) {
    if (addr_.toLowerCase() === deployer.address.toLowerCase()) continue;
    try {
      const tx = await contract.changeAddressInAdminlist(addr_, true);
      await tx.wait();
      console.log("  已添加 admin:", addr_);
    } catch (e) {
      console.warn("  添加 admin 失败:", addr_, (e as Error).message);
    }
  }

  // 保存部署结果
  const deployDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deployDir)) fs.mkdirSync(deployDir, { recursive: true });
  const outPath = path.join(deployDir, "conet-GuardianNodesInfoV6.json");
  const result = {
    network: "conet",
    chainId: net.chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      GuardianNodesInfoV6: {
        address: addr,
      },
    },
  };
  fs.writeFileSync(outPath, JSON.stringify(result, null, 2) + "\n", "utf-8");

  console.log("\n部署结果已保存至:", outPath);
  console.log("\n✅ 部署完成!");
  console.log("  GuardianNodesInfoV6 地址:", addr);
  console.log("\n后续步骤:");
  console.log("  1. 若有旧合约节点数据，需通过 addNode 迁移");
  console.log("  2. 更新 ConetTreasury.setGuardianNodesInfoV6(", addr, ")");
  console.log("  3. 更新 AddressPGP 等依赖 GuardianNodesInfoV6 的合约配置");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
