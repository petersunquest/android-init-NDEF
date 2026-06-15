/**
 * 部署（或命中已存在的）CREATE2 包装 FactoryERC20。
 *
 * 运行:
 *   npx hardhat run scripts/deployTreasuryWrappedToken.ts --network conet
 *
 * 环境变量: CONET_TREASURY, PEER_CHAIN_ID, PEER_TOKEN（默认同 registerTreasuryPeerUsdc）
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { BASE_MAINNET_CHAIN_ID, BASE_USDC } from "./conetTreasuryDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function resolveTreasuryAddress(): string {
  if (process.env.CONET_TREASURY) return process.env.CONET_TREASURY;
  const metaPath = path.join(__dirname, "..", "deployments", "conetTreasury-create2-meta.json");
  if (fs.existsSync(metaPath)) {
    const meta = JSON.parse(fs.readFileSync(metaPath, "utf-8"));
    if (meta.predictedAddress) return meta.predictedAddress;
  }
  throw new Error("未找到 ConetTreasury 地址");
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("无签名账户");

  const peerChainId = BigInt(process.env.PEER_CHAIN_ID || BASE_MAINNET_CHAIN_ID.toString());
  const peerToken = process.env.PEER_TOKEN || BASE_USDC;
  const treasuryAddress = resolveTreasuryAddress();
  const treasury = await ethers.getContractAt("ConetTreasury", treasuryAddress, signer);

  const predicted = await treasury.predictWrappedToken(peerChainId, peerToken);
  console.log("predictWrappedToken:", predicted);

  const codeBefore = await ethers.provider.getCode(predicted);
  if (codeBefore !== "0x" && codeBefore.length > 2) {
    console.log("✅ 包装合约已存在，跳过 deployWrappedToken");
    return;
  }

  const tx = await treasury.deployWrappedToken(peerChainId, peerToken);
  console.log("deployWrappedToken tx:", tx.hash);
  await tx.wait();

  const wrapped = await treasury.predictWrappedToken(peerChainId, peerToken);
  const token = await ethers.getContractAt(
    ["function name() view returns (string)", "function symbol() view returns (string)", "function decimals() view returns (uint8)", "function minter() view returns (address)"],
    wrapped
  );
  console.log("✅ wrapped:", wrapped);
  console.log("   name:", await token.name());
  console.log("   symbol:", await token.symbol());
  console.log("   decimals:", await token.decimals());
  console.log("   minter:", await token.minter());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
