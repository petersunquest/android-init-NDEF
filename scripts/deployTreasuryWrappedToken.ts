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
import { concat, keccak256, solidityPacked } from "ethers";
import { fileURLToPath } from "url";
import {
  BASE_MAINNET_CHAIN_ID,
  BASE_USDC,
  NICK_CREATE2_FACTORY,
  WRAPPED_ERC20_SALT_PREFIX,
} from "./conetTreasuryDeployConstants.js";

function nickCreate2DeployCalldata(salt: string, initCode: string): string {
  return concat([salt, initCode]);
}

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

  try {
    const tx = await treasury.deployWrappedToken(peerChainId, peerToken, { gasLimit: 2_000_000n });
    console.log("deployWrappedToken tx:", tx.hash);
    await tx.wait();
  } catch (e) {
    const codeMid = await ethers.provider.getCode(predicted);
    if (codeMid !== "0x" && codeMid.length > 2) {
      console.log("包装合约已存在（Treasury.deployWrappedToken 可能已部分成功），跳过 Nick deploy");
    } else {
      console.warn("Treasury.deployWrappedToken revert（Nick 无 return data），改 EOA 直 deploy Nick…");
      const [name, symbol, decimals] = await treasury.getPeerTokenMeta(peerChainId, peerToken);
      const factory = await ethers.getContractFactory("FactoryERC20");
      const deployTx = await factory.getDeployTransaction(name, symbol, decimals, treasuryAddress);
      const initCode = deployTx.data;
      if (!initCode) throw new Error("无法生成 FactoryERC20 initCode");
      const salt = keccak256(
        solidityPacked(["string", "uint256", "address"], [WRAPPED_ERC20_SALT_PREFIX, peerChainId, peerToken])
      );
      const deployData = nickCreate2DeployCalldata(salt, initCode);
      const nickTx = await signer.sendTransaction({
        to: NICK_CREATE2_FACTORY,
        data: deployData,
        gasLimit: 2_000_000n,
      });
      console.log("Nick direct deploy tx:", nickTx.hash);
      await nickTx.wait();
      const codeAfter = await ethers.provider.getCode(predicted);
      if (codeAfter === "0x" || codeAfter.length <= 2) {
        throw e;
      }
    }
    try {
      const trackTx = await treasury.deployWrappedToken(peerChainId, peerToken, { gasLimit: 500_000n });
      console.log("Treasury track deployWrappedToken tx:", trackTx.hash);
      await trackTx.wait();
    } catch (trackErr) {
      console.warn("Treasury track 跳过（包装已存在且可能已 tracking）:", (trackErr as Error).message);
    }
  }

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
