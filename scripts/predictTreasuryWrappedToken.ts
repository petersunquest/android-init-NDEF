/**
 * 预测 CREATE2 包装 FactoryERC20 地址（须与链上 registerPeerToken 元数据一致）。
 *
 * 环境变量:
 *   CONET_TREASURY — Treasury 地址（默认 conetTreasury-create2-meta.json predictedAddress）
 *   PEER_CHAIN_ID — 默认 8453 (Base)
 *   PEER_TOKEN — 默认 Base USDC
 *   WRAPPED_NAME / WRAPPED_SYMBOL / WRAPPED_DECIMALS — 默认 USD Coin / USDC / 6
 *
 * 运行: npx hardhat run scripts/predictTreasuryWrappedToken.ts
 */

import { network as networkModule } from "hardhat";
import { id, solidityPacked, keccak256, getAddress } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import {
  BASE_MAINNET_CHAIN_ID,
  BASE_USDC,
  NICK_CREATE2_FACTORY,
  WRAPPED_ERC20_SALT_PREFIX,
} from "./conetTreasuryDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function resolveTreasuryAddress(): string {
  if (process.env.CONET_TREASURY) return getAddress(process.env.CONET_TREASURY);
  const metaPath = path.join(__dirname, "..", "deployments", "conetTreasury-create2-meta.json");
  if (fs.existsSync(metaPath)) {
    const meta = JSON.parse(fs.readFileSync(metaPath, "utf-8"));
    if (meta.predictedAddress) return getAddress(meta.predictedAddress);
  }
  throw new Error("设置 CONET_TREASURY 或先运行 predictConetTreasuryCreate2Address.ts");
}

async function main() {
  const { ethers } = await networkModule.connect();
  const treasuryAddress = resolveTreasuryAddress();

  const peerChainId = BigInt(process.env.PEER_CHAIN_ID || BASE_MAINNET_CHAIN_ID.toString());
  const peerToken = getAddress(process.env.PEER_TOKEN || BASE_USDC);
  const name = process.env.WRAPPED_NAME || "USD Coin";
  const symbol = process.env.WRAPPED_SYMBOL || "USDC";
  const decimals = Number(process.env.WRAPPED_DECIMALS || "6");

  const factory = await ethers.getContractFactory("FactoryERC20");
  const deployTx = await factory.getDeployTransaction(name, symbol, decimals, treasuryAddress);
  const initCode = deployTx.data;
  if (!initCode) throw new Error("无法生成 FactoryERC20 initCode");

  const salt = keccak256(
    solidityPacked(["string", "uint256", "address"], [WRAPPED_ERC20_SALT_PREFIX, peerChainId, peerToken])
  );
  const initCodeHash = keccak256(initCode);
  const predicted = getAddress(
    "0x" +
      keccak256(solidityPacked(["bytes1", "address", "bytes32", "bytes32"], ["0xff", NICK_CREATE2_FACTORY, salt, initCodeHash])).slice(-40)
  );

  console.log("Wrapped FactoryERC20 CREATE2 prediction");
  console.log("treasury (minter):", treasuryAddress);
  console.log("peerChainId:", peerChainId.toString());
  console.log("peerToken:", peerToken);
  console.log("name / symbol / decimals:", name, symbol, decimals);
  console.log("nickFactory:", NICK_CREATE2_FACTORY);
  console.log("salt:", salt);
  console.log("initCodeHash:", initCodeHash);
  console.log("predictedWrapped:", predicted);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
