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

  const deploymentPath = path.join(__dirname, "..", "deployments", "conet-ConetTreasury.json");
  if (!fs.existsSync(deploymentPath)) {
    throw new Error("未找到 conet-ConetTreasury.json");
  }
  const deploy = JSON.parse(fs.readFileSync(deploymentPath, "utf-8"));
  const treasuryAddress = deploy.contracts?.ConetTreasury?.address;
  if (!treasuryAddress) {
    throw new Error("部署文件中无 ConetTreasury 地址");
  }

  console.log("=".repeat(60));
  console.log("ConetTreasury 工厂发行 USDC");
  console.log("=".repeat(60));
  console.log("ConetTreasury:", treasuryAddress);
  console.log("Base USDC (baseToken):", BASE_USDC);
  console.log("caller:", signer.address);
  console.log("chainId:", net.chainId.toString(), "\n");

  const treasury = await ethers.getContractAt("ConetTreasury", treasuryAddress);
  const owner = await treasury.owner();
  if (signer.address.toLowerCase() !== owner.toLowerCase()) {
    throw new Error(`调用者 ${signer.address} 非 owner ${owner}，无法创建 ERC20`);
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

  // 更新部署文件
  const outPath = path.join(__dirname, "..", "deployments", "conet-ConetTreasury.json");
  const out = {
    ...deploy,
    contracts: {
      ...deploy.contracts,
      ConetTreasury: {
        ...deploy.contracts.ConetTreasury,
        usdc: tokenAddress,
        usdcBaseToken: BASE_USDC,
      },
    },
  };
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("\nsaved:", outPath);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
