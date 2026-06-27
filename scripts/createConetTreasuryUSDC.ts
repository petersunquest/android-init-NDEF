/**
 * 通过 ConetTreasury 工厂发行 USDC（CoNET 链上 USDC 代币）
 *
 * 参数：name="USD Coin", symbol="USDC", decimals=6, baseToken=Base 主网 USDC
 *
 * 运行: npx hardhat run scripts/createConetTreasuryUSDC.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();

  // 优先 env，其次 CREATE2 meta（新栈），最后回退旧 conet-ConetTreasury.json。
  function resolveTreasury(): string {
    if (process.env.CONET_TREASURY?.trim()) return ethers.getAddress(process.env.CONET_TREASURY.trim());
    const metaPath = path.join(__dirname, "..", "deployments", "conetTreasury-create2-meta.json");
    if (fs.existsSync(metaPath)) {
      const meta = JSON.parse(fs.readFileSync(metaPath, "utf-8"));
      if (meta.predictedAddress) return ethers.getAddress(meta.predictedAddress);
    }
    const deploymentPath = path.join(__dirname, "..", "deployments", "conet-ConetTreasury.json");
    if (fs.existsSync(deploymentPath)) {
      const deploy = JSON.parse(fs.readFileSync(deploymentPath, "utf-8"));
      const a = deploy.contracts?.ConetTreasury?.address;
      if (a) return ethers.getAddress(a);
    }
    throw new Error("无法解析 ConetTreasury 地址（设 CONET_TREASURY 或先部署 create2 meta）");
  }
  const treasuryAddress = resolveTreasury();

  console.log("=".repeat(60));
  console.log("ConetTreasury 工厂发行 USDC");
  console.log("=".repeat(60));
  console.log("ConetTreasury:", treasuryAddress);
  console.log("Base USDC (baseToken):", BASE_USDC);
  console.log("caller:", signer.address);
  console.log("chainId:", net.chainId.toString(), "\n");

  const treasury = await ethers.getContractAt("ConetTreasury", treasuryAddress);
  const isMiner = await treasury.isMiner(signer.address);
  if (!isMiner) {
    throw new Error(`调用者 ${signer.address} 非 miner，无法创建 ERC20`);
  }

  // 检查是否已存在 USDC
  const tokenCount = await treasury.createdTokenCount();
  const createdTokens = await treasury.getCreatedTokens();
  for (let i = 0; i < tokenCount; i++) {
    const tokenAddr = createdTokens[i];
    const token = await ethers.getContractAt(
      ["function symbol() view returns (string)"],
      tokenAddr
    );
    const sym = await token.symbol();
    if (sym === "USDC") {
      console.log("USDC 已存在，地址:", tokenAddr);
      console.log("baseTokenOf:", await treasury.baseTokenOf(tokenAddr));
      return;
    }
  }

  const tx = await treasury.createERC20(
    "USD Coin",
    "USDC",
    6,
    BASE_USDC
  );
  const receipt = await tx.wait();
  const tokensAfter = await treasury.getCreatedTokens();
  const tokenAddress = tokensAfter[tokensAfter.length - 1];

  console.log("[1] createERC20 交易已确认:", receipt?.hash ?? tx.hash);
  console.log("[2] CoNET USDC 地址:", tokenAddress);
  console.log("    baseToken (Base USDC):", BASE_USDC);

  // 更新权威 conet-addresses.json（仅 CoNET 链）
  if (net.chainId === 224422n) {
    const addrPath = path.join(__dirname, "..", "deployments", "conet-addresses.json");
    if (fs.existsSync(addrPath)) {
      const addr = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, unknown>;
      const prev = typeof addr.conetUsdc === "string" ? (addr.conetUsdc as string) : "";
      const dep = Array.isArray(addr.DEPRECATED_CONET_USDC) ? (addr.DEPRECATED_CONET_USDC as string[]) : [];
      if (prev && prev.toLowerCase() !== tokenAddress.toLowerCase() && !dep.map((x) => x.toLowerCase()).includes(prev.toLowerCase())) {
        dep.push(prev);
      }
      addr.conetUsdc = tokenAddress;
      addr.DEPRECATED_CONET_USDC = dep;
      addr.ConetTreasury = treasuryAddress;
      fs.writeFileSync(addrPath, JSON.stringify(addr, null, 2) + "\n", "utf-8");
      console.log("\nupdated conet-addresses.json conetUsdc + ConetTreasury (+DEPRECATED_CONET_USDC)");
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
