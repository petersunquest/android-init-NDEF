/**
 * 配置 ConetTreasuryPeer 跨链 canonical 资产（wCNET / BUint / GB peer 注册 + 指针）。
 *
 * 运行（各链 miner 执行）:
 *   npx hardhat run scripts/registerPeerBridgeAssets.ts --network conet
 *   npx hardhat run scripts/registerPeerBridgeAssets.ts --network base
 *
 * 环境变量:
 *   CONET_TREASURY_PEER — Peer 地址（默认 CONET_TREASURY_PEER_CREATE2_PREDICTED）
 *   PEER_CHAIN_IDS — 逗号分隔对端 chainId，默认 CoNET↔Base
 *   BUINT_ADDRESS / GB_ADDRESS — CREATE2 同址（默认由 predict 常量）
 *   SKIP_WCNET=1 / SKIP_BUINT=1 / SKIP_GB=1 — 跳过单项
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import {
  BASE_MAINNET_CHAIN_ID,
  CONET_CHAIN_ID,
  CONET_TREASURY_PEER_CREATE2_PREDICTED,
} from "./conetTreasuryDeployConstants.js";
import { BUINT_CREATE2_PREDICTED } from "./bunitDeployConstants.js";
import { GB_CREATE2_PREDICTED } from "./gbDeployConstants.js";

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

function parsePeerChainIds(localChainId: bigint): bigint[] {
  const raw = process.env.PEER_CHAIN_IDS?.trim();
  if (raw) {
    return raw.split(",").map((s) => BigInt(s.trim()));
  }
  if (localChainId === CONET_CHAIN_ID) return [BASE_MAINNET_CHAIN_ID];
  if (localChainId === BASE_MAINNET_CHAIN_ID) return [CONET_CHAIN_ID];
  throw new Error(`请设置 PEER_CHAIN_IDS（当前 chainId ${localChainId} 无默认对端）`);
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("无签名账户");

  const net = await ethers.provider.getNetwork();
  const peerAddr = resolvePeerAddress(ethers);
  const peerChainIds = parsePeerChainIds(net.chainId);

  const peer = await ethers.getContractAt("ConetTreasuryPeer", peerAddr, signer);

  console.log("=".repeat(60));
  console.log("registerPeerBridgeAssets (ConetTreasuryPeer)");
  console.log("=".repeat(60));
  console.log("chainId:", net.chainId.toString());
  console.log("signer:", signer.address);
  console.log("peer:", peerAddr);
  console.log("peerChainIds:", peerChainIds.map(String).join(", "));

  if (process.env.SKIP_WCNET !== "1" && net.chainId === CONET_CHAIN_ID) {
    console.log("\n→ registerWrappedConetNative()");
    const tx = await peer.registerWrappedConetNative();
    await tx.wait();
    console.log("   wrappedConet:", await peer.wrappedConet());
  }

  const buintAddr = process.env.BUINT_ADDRESS?.trim() || BUINT_CREATE2_PREDICTED;
  if (process.env.SKIP_BUINT !== "1") {
    console.log("\n→ setBUint(", buintAddr, ")");
    const tx = await peer.setBUint(buintAddr);
    await tx.wait();
  }

  const gbAddr = process.env.GB_ADDRESS?.trim() || GB_CREATE2_PREDICTED;
  if (process.env.SKIP_GB !== "1") {
    const gbCode = await ethers.provider.getCode(gbAddr);
    if (gbCode === "0x" || gbCode.length <= 2) {
      console.warn("\n→ 跳过 setConetGB：", gbAddr, "链上无 code（先 deployGBStackCreate2.ts）");
    } else {
      console.log("\n→ setConetGB(", gbAddr, ")");
      const tx = await peer.setConetGB(gbAddr);
      await tx.wait();
    }
  }

  const ids = peerChainIds.map((id) => id.toString());
  console.log("\n→ registerPeerBridgeAssets([", ids.join(", "), "])");
  const txReg = await peer.registerPeerBridgeAssets(ids);
  await txReg.wait();

  for (const pid of peerChainIds) {
    const buintToken = await peer.BUINT_PEER_TOKEN();
    const gbToken = await peer.GB_PEER_TOKEN();
    const buintOk = await peer.isPeerTokenRegistered(pid, buintToken);
    const gbOk = await peer.isPeerTokenRegistered(pid, gbToken);
    console.log(`   peer ${pid}: BUint registered=${buintOk}, GB registered=${gbOk}`);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
