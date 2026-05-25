/**
 * 部署 AddressPGP 到 CoNET mainnet
 * 需传入 GuardianNodesInfoV6 地址（0x6d7a526BFD03E90ea8D19eDB986577395a139872，见 deployments/conet-GuardianNodesInfoV6.json）
 *
 * 运行: npx hardhat run scripts/deployAddressPGPToConet.ts --network conet
 * 或: GUARDIAN_NODES=0x... npx hardhat run scripts/deployAddressPGPToConet.ts --network conet
 */

import { network as hreNetwork } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const GUARDIAN_NODES_INFO_V6 =
  process.env.GUARDIAN_NODES ||
  (() => {
    const p = path.join(__dirname, "..", "deployments", "conet-GuardianNodesInfoV6.json");
    if (fs.existsSync(p)) {
      const j = JSON.parse(fs.readFileSync(p, "utf-8")) as {
        GuardianNodesInfoV6?: string;
        contracts?: { GuardianNodesInfoV6?: { address?: string } };
      };
      const fromContracts = j.contracts?.GuardianNodesInfoV6?.address;
      if (fromContracts) return fromContracts;
      if (j.GuardianNodesInfoV6) return j.GuardianNodesInfoV6;
    }
    const addrPath = path.join(__dirname, "..", "deployments", "conet-addresses.json");
    if (fs.existsSync(addrPath)) {
      const j = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as { GuardianNodesInfoV6?: string };
      if (j.GuardianNodesInfoV6) return j.GuardianNodesInfoV6;
    }
    throw new Error("GuardianNodesInfoV6 未配置：先 deployGuardianNodesInfoV6ToConet 或设置 GUARDIAN_NODES");
  })();

async function main() {
  const { ethers } = await hreNetwork.connect();
  const [deployer] = await ethers.getSigners();

  console.log("=".repeat(60));
  console.log("部署 AddressPGP 到 CoNET mainnet");
  console.log("=".repeat(60));
  console.log("GuardianNodesInfoV6:", GUARDIAN_NODES_INFO_V6);
  console.log("部署账户:", deployer.address);
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("余额:", ethers.formatEther(balance), "ETH");
  const net = await ethers.provider.getNetwork();
  console.log("网络:", net.name, "ChainId:", net.chainId.toString());

  if (balance === 0n) {
    throw new Error("账户余额为 0，无法部署");
  }

  console.log("\n[1] 部署 AddressPGP...");
  const AddressPGP = await ethers.getContractFactory("src/mainnet/AddressPGP.sol:AddressPGP");
  const contract = await AddressPGP.deploy(GUARDIAN_NODES_INFO_V6);
  await contract.waitForDeployment();
  const addr = await contract.getAddress();
  console.log("  AddressPGP:", addr);
  console.log("  部署账户已自动设为 admin");

  // 保存部署结果
  const deployDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deployDir)) fs.mkdirSync(deployDir, { recursive: true });
  const outPath = path.join(deployDir, "conet-AddressPGP.json");
  const result = {
    network: "conet",
    chainId: net.chainId.toString(),
    deployer: deployer.address,
    guardianNodesInfoV6: GUARDIAN_NODES_INFO_V6,
    timestamp: new Date().toISOString(),
    AddressPGP: addr,
  };
  fs.writeFileSync(outPath, JSON.stringify(result, null, 2));
  const conetAddrPath = path.join(deployDir, "conet-addresses.json");
  if (fs.existsSync(conetAddrPath)) {
    const ca = JSON.parse(fs.readFileSync(conetAddrPath, "utf-8")) as Record<string, unknown>;
    ca.AddressPGP = addr;
    fs.writeFileSync(conetAddrPath, JSON.stringify(ca, null, 2), "utf-8");
    console.log("updated conet-addresses.json AddressPGP:", addr);
  }
  console.log("\n部署结果已保存至:", outPath);
  console.log("\n✅ 部署完成!");
  console.log("  AddressPGP 地址:", addr);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
