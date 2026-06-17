/**
 * 各链登记并部署 Wrapped CoNET（peer: CONET_CHAIN_ID + NATIVE_PEER_TOKEN）。
 * 调用 ConetTreasuryPeer.registerWrappedConetNative（非 Treasury）。
 *
 * 运行:
 *   npx hardhat run scripts/registerWrappedConetNative.ts --network conet
 *   npx hardhat run scripts/registerWrappedConetNative.ts --network base
 *
 * CoNET 链额外启用 depositNative / withdrawNative / burnWrappedConetForBridge。
 * Relayer 编程见 scripts/conetTreasury-relayer-validator.md
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import {
  CONET_CHAIN_ID,
  CONET_TREASURY_PEER_CREATE2_PREDICTED,
  NATIVE_PEER_TOKEN,
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
  const net = await ethers.provider.getNetwork();

  console.log("registerWrappedConetNative (Peer)");
  console.log("chainId:", net.chainId.toString());
  console.log("Peer:", peerAddress);
  console.log("peer key:", CONET_CHAIN_ID.toString(), NATIVE_PEER_TOKEN);

  const tx = await peer.registerWrappedConetNative();
  console.log("tx:", tx.hash);
  await tx.wait();

  const wrapped = await peer.wrappedConet();
  const predicted = await peer.predictWrappedConetNative();
  console.log("predictWrappedConetNative:", predicted);
  console.log("wrappedConet cache:", wrapped);

  const metaPath = path.join(__dirname, "..", "deployments", "conetTreasury-wrapped-conet-meta.json");
  let meta: Record<string, unknown> = {};
  if (fs.existsSync(metaPath)) meta = JSON.parse(fs.readFileSync(metaPath, "utf-8"));
  meta.peerModule = peerAddress;
  meta.peerChainId = CONET_CHAIN_ID.toString();
  meta.nativePeerToken = NATIVE_PEER_TOKEN;
  meta.deployments = {
    ...(typeof meta.deployments === "object" && meta.deployments !== null
      ? (meta.deployments as Record<string, string>)
      : {}),
    [net.chainId.toString()]: predicted,
  };
  meta.updatedAt = new Date().toISOString();
  fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2) + "\n", "utf-8");
  console.log("saved:", metaPath);

  if (net.chainId === CONET_CHAIN_ID) {
    const addrPath = path.join(__dirname, "..", "deployments", "conet-addresses.json");
    if (fs.existsSync(addrPath)) {
      const addr = JSON.parse(fs.readFileSync(addrPath, "utf-8"));
      addr.wrappedConet = predicted;
      addr.ConetTreasuryPeer = peerAddress;
      fs.writeFileSync(addrPath, JSON.stringify(addr, null, 2) + "\n", "utf-8");
      console.log("updated conet-addresses.json wrappedConet + ConetTreasuryPeer");
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
