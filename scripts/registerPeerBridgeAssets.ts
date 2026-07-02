/**
 * 配置 ConetTreasuryPeer 跨链资产（原生 trio + 稳定币互换 USDC/GB/B-Unit）。
 *
 * 默认 USE_NATIVE_CANONICAL=1：
 *   - registerPeerNativeBridgeAssets（GB / B-Unit / wCNET 同址）
 *   - registerPeerStableSwapAssets（对端链 GB / B-Unit / USDC）
 *
 * 环境变量：
 *   USDC6_PER_FULL_GB — GB 标价（USDC6 每 1 整 GB）；例 0.01 USDC/GB → 10000
 *   SKIP_STABLE_SWAP=1 — 跳过稳定币互换登记
 *
 * 运行:
 *   npx hardhat run scripts/registerPeerBridgeAssets.ts --network conet
 *   npx hardhat run scripts/registerPeerBridgeAssets.ts --network base
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import {
  BASE_MAINNET_CHAIN_ID,
  BASE_USDC,
  CONET_CHAIN_ID,
  CONET_TREASURY_PEER_CREATE2_PREDICTED,
  CONET_USDC,
  NATIVE_CROSS_CHAIN_BUINT,
  NATIVE_CROSS_CHAIN_GB,
  NATIVE_CROSS_CHAIN_WCNET,
} from "./conetTreasuryDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/** 默认 0.01 USDC / 1 GB → usdc6PerFullGb = 10000 */
const DEFAULT_USDC6_PER_FULL_GB = 10_000n;

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

function parsePeerChainIds(localChainId: bigint): bigint[] {
  const raw = process.env.PEER_CHAIN_IDS?.trim();
  if (raw) {
    return raw.split(",").map((s) => BigInt(s.trim()));
  }
  if (localChainId === CONET_CHAIN_ID) return [BASE_MAINNET_CHAIN_ID];
  if (localChainId === BASE_MAINNET_CHAIN_ID) return [CONET_CHAIN_ID];
  throw new Error(`请设置 PEER_CHAIN_IDS（当前 chainId ${localChainId} 无默认对端）`);
}

function resolveWcnetAddress(ethers: { getAddress: (a: string) => string }): string {
  return ethers.getAddress(process.env.WCNET_ADDRESS?.trim() || NATIVE_CROSS_CHAIN_WCNET);
}

/** 本链 canonical USDC */
function resolveLocalUsdc(ethers: { getAddress: (a: string) => string }, chainId: bigint): string {
  if (chainId === CONET_CHAIN_ID) {
    return ethers.getAddress(process.env.CONET_USDC?.trim() || CONET_USDC);
  }
  if (chainId === BASE_MAINNET_CHAIN_ID) {
    return ethers.getAddress(process.env.BASE_USDC?.trim() || BASE_USDC);
  }
  throw new Error(`未配置 chainId ${chainId} 的 local USDC`);
}

/** 对端链 USDC（peer 登记用） */
function resolvePeerUsdc(ethers: { getAddress: (a: string) => string }, localChainId: bigint): string {
  if (localChainId === CONET_CHAIN_ID) {
    return ethers.getAddress(process.env.BASE_USDC?.trim() || BASE_USDC);
  }
  if (localChainId === BASE_MAINNET_CHAIN_ID) {
    return ethers.getAddress(process.env.CONET_USDC?.trim() || CONET_USDC);
  }
  throw new Error(`未配置 chainId ${localChainId} 的 peer USDC`);
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("无签名账户");

  const net = await ethers.provider.getNetwork();
  const peerAddr = resolvePeerAddress(ethers);
  const peerChainIds = parsePeerChainIds(net.chainId);
  const useNative = process.env.USE_NATIVE_CANONICAL !== "0";

  const peer = await ethers.getContractAt("ConetTreasuryPeer", peerAddr, signer);

  console.log("=".repeat(60));
  console.log("registerPeerBridgeAssets (ConetTreasuryPeer)");
  console.log("=".repeat(60));
  console.log("chainId:", net.chainId.toString());
  console.log("signer:", signer.address);
  console.log("peer:", peerAddr);
  console.log("peerChainIds:", peerChainIds.map(String).join(", "));

  const gbToken = ethers.getAddress(process.env.GB_TOKEN_ERC20?.trim() || NATIVE_CROSS_CHAIN_GB);
  const buintToken = ethers.getAddress(process.env.BUINT_ADDRESS?.trim() || NATIVE_CROSS_CHAIN_BUINT);
  const localUsdc = resolveLocalUsdc(ethers, net.chainId);
  const peerUsdc = resolvePeerUsdc(ethers, net.chainId);

  if (process.env.SKIP_POINTERS !== "1") {
    console.log("\n→ setBUint / setGbTokenErc20 / setUsdcErc20");
    await (await peer.setBUint(buintToken)).wait();
    await (await peer.setGbTokenErc20(gbToken)).wait();
    await (await peer.setUsdcErc20(localUsdc)).wait();
    console.log("   local USDC:", localUsdc);

    const rateRaw = process.env.USDC6_PER_FULL_GB?.trim();
    const rate = rateRaw ? BigInt(rateRaw) : DEFAULT_USDC6_PER_FULL_GB;
    console.log("→ setUsdc6PerFullGb(", rate.toString(), ")");
    await (await peer.setUsdc6PerFullGb(rate)).wait();
  }

  if (process.env.SKIP_WCNET !== "1") {
    console.log("\n→ registerWrappedConetNative()");
    await (await peer.registerWrappedConetNative()).wait();
    console.log("   wrappedConet:", await peer.wrappedConet());
  }

  const wcnetToken = resolveWcnetAddress(ethers);
  const ids = peerChainIds.map((id) => id.toString());

  if (useNative) {
    console.log("\n→ registerPeerNativeBridgeAssets");
    await (await peer.registerPeerNativeBridgeAssets(ids, gbToken, buintToken, wcnetToken)).wait();

    if (process.env.SKIP_STABLE_SWAP !== "1") {
      console.log("\n→ registerPeerStableSwapAssets（USDC/GB/B-Unit 互换 peer）");
      console.log("   peer GB:  ", gbToken);
      console.log("   peer BUnit:", buintToken);
      console.log("   peer USDC:", peerUsdc);
      await (await peer.registerPeerStableSwapAssets(ids, gbToken, buintToken, peerUsdc)).wait();
    }
  } else {
    console.log("\n→ registerPeerBridgeAssets legacy");
    await (await peer.registerPeerBridgeAssets(ids)).wait();
  }

  console.log("\n跨链入口:");
  console.log("  同资产: bridgeNativeAsset(1|2|3, amount, destChainId, recipient)");
  console.log("  兑换:   bridgeStableSwap(burnKind, amount, destChainId, recipient, creditKind)");
  console.log("          burnKind/creditKind: 1=GB, 2=USDC, 3=B-Unit");
  console.log("  预览:   quoteStableSwap(burnKind, amount, creditKind)");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
