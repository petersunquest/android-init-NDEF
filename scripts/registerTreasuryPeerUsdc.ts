/**
 * 在 ConetTreasury 登记 Base USDC → CREATE2 包装 ERC20 元数据。
 *
 * 运行: npx hardhat run scripts/registerTreasuryPeerUsdc.ts --network conet
 *
 * 环境变量:
 *   CONET_TREASURY — 覆盖 Treasury 地址
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import {
  BASE_MAINNET_CHAIN_ID,
  BASE_USDC,
} from "./conetTreasuryDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function resolveTreasuryAddress(): string {
  if (process.env.CONET_TREASURY) return process.env.CONET_TREASURY;
  const metaPath = path.join(__dirname, "..", "deployments", "conetTreasury-create2-meta.json");
  if (fs.existsSync(metaPath)) {
    const meta = JSON.parse(fs.readFileSync(metaPath, "utf-8"));
    if (meta.predictedAddress) return meta.predictedAddress;
  }
  const legacy = path.join(__dirname, "..", "deployments", "conet-ConetTreasury.json");
  if (fs.existsSync(legacy)) {
    const d = JSON.parse(fs.readFileSync(legacy, "utf-8"));
    if (d?.contracts?.ConetTreasury?.address) return d.contracts.ConetTreasury.address;
  }
  throw new Error("未找到 ConetTreasury 地址");
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("无签名账户");

  const treasuryAddress = resolveTreasuryAddress();
  const treasury = await ethers.getContractAt("ConetTreasury", treasuryAddress, signer);

  console.log("registerPeerToken Base USDC");
  console.log("Treasury:", treasuryAddress);
  console.log("signer:", signer.address);

  const tx = await treasury.registerPeerToken(
    BASE_MAINNET_CHAIN_ID,
    BASE_USDC,
    "USD Coin",
    "USDC",
    6
  );
  const receipt = await tx.wait();
  console.log("tx:", receipt?.hash);

  const predicted = await treasury.predictWrappedToken(BASE_MAINNET_CHAIN_ID, BASE_USDC);
  console.log("predictWrappedToken:", predicted);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
