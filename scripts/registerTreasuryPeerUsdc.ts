/**
 * 在 ConetTreasuryPeer 登记 Base USDC → CoNET conet-USDC 的 **ERC20 canonical peer**（不再 CREATE2 包装副本）。
 *
 * 运行: npx hardhat run scripts/registerTreasuryPeerUsdc.ts --network conet
 *
 * 环境变量:
 *   CONET_TREASURY_PEER — Peer 地址
 *   CONET_USDC — 本链 USDC（默认 conet-USDC）
 *   BASE_USDC — 对端 Base USDC
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import {
  BASE_MAINNET_CHAIN_ID,
  BASE_USDC,
  CONET_TREASURY_PEER_CREATE2_PREDICTED,
  CONET_USDC,
} from "./conetTreasuryDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function resolvePeerAddress(ethers: { getAddress: (a: string) => string }): string {
  if (process.env.CONET_TREASURY_PEER?.trim()) {
    return ethers.getAddress(process.env.CONET_TREASURY_PEER.trim());
  }
  const metaPath = path.join(__dirname, "..", "deployments", "conetTreasuryPeer-create2-meta.json");
  if (fs.existsSync(metaPath)) {
    const meta = JSON.parse(fs.readFileSync(metaPath, "utf-8"));
    if (meta.predictedAddress) return ethers.getAddress(meta.predictedAddress);
  }
  return CONET_TREASURY_PEER_CREATE2_PREDICTED;
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("无签名账户");

  const peerAddress = resolvePeerAddress(ethers);
  const peer = await ethers.getContractAt("ConetTreasuryPeer", peerAddress, signer);
  const usdcLocal = ethers.getAddress(process.env.CONET_USDC?.trim() || CONET_USDC);
  const peerUsdc = ethers.getAddress(process.env.BASE_USDC?.trim() || BASE_USDC);

  console.log("registerCanonicalErc20Peer Base USDC → conet-USDC");
  console.log("Peer:", peerAddress);
  console.log("signer:", signer.address);
  console.log("peerChainId:", BASE_MAINNET_CHAIN_ID.toString());
  console.log("peerToken (Base USDC):", peerUsdc);
  console.log("localToken (conet-USDC):", usdcLocal);

  const currentUsdc = await peer.usdcErc20();
  if (currentUsdc.toLowerCase() !== usdcLocal.toLowerCase()) {
    const txSet = await peer.setUsdcErc20(usdcLocal);
    await txSet.wait();
    console.log("setUsdcErc20 ok");
  }

  const kindUsdc = await peer.CANONICAL_USDC_ERC20();
  const tx = await peer.registerCanonicalErc20Peer(
    BASE_MAINNET_CHAIN_ID,
    peerUsdc,
    kindUsdc,
    "USD Coin",
    "USDC",
    6
  );
  const receipt = await tx.wait();
  console.log("tx:", receipt?.hash);
  const kind = await peer.canonicalErc20Kind(BASE_MAINNET_CHAIN_ID, peerUsdc);
  console.log("canonicalErc20Kind (USDC):", kind.toString());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
