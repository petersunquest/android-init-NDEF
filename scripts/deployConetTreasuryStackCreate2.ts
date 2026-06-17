/**
 * 一键 CREATE2 部署 ConetTreasury 栈：Treasury → Peer → Treasury.setPeerModule(Peer)。
 *
 * 运行:
 *   npx hardhat run scripts/deployConetTreasuryStackCreate2.ts --network conet
 *
 * 环境变量:
 *   DRY_RUN=1 — 只跑 predict / 跳过发交易
 *   SKIP_TREASURY=1 / SKIP_PEER=1 / SKIP_LINK=1
 */

import { execSync } from "child_process";
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import {
  CONET_TREASURY_CREATE2_PREDICTED,
  CONET_TREASURY_PEER_CREATE2_PREDICTED,
} from "./conetTreasuryDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

function resolveHardhatNetwork(): string {
  const idx = process.argv.indexOf("--network");
  if (idx >= 0 && process.argv[idx + 1]) return process.argv[idx + 1];
  return process.env.HARDHAT_NETWORK || "conet";
}

async function main() {
  const { ethers } = await networkModule.connect();
  const net = await ethers.provider.getNetwork();
  const dryRun = process.env.DRY_RUN === "1";
  const hardhatNetwork = resolveHardhatNetwork();

  function runScript(rel: string, extraEnv: Record<string, string> = {}) {
    const env = { ...process.env, HARDHAT_NETWORK: hardhatNetwork, ...extraEnv };
    execSync(`npx hardhat run scripts/${rel} --network ${hardhatNetwork}`, {
      stdio: "inherit",
      cwd: root,
      env,
    });
  }

  console.log("=".repeat(60));
  console.log("ConetTreasury stack CREATE2");
  console.log("=".repeat(60));
  console.log("chainId:", net.chainId.toString());
  console.log("predicted Treasury:", CONET_TREASURY_CREATE2_PREDICTED);
  console.log("predicted Peer:    ", CONET_TREASURY_PEER_CREATE2_PREDICTED);

  if (process.env.SKIP_TREASURY !== "1") {
    console.log("\n[1/3] deployConetTreasuryCreate2");
    runScript("deployConetTreasuryCreate2.ts", dryRun ? { DRY_RUN: "1" } : {});
  }

  const treasuryMeta = path.join(root, "deployments", "conetTreasury-create2-meta.json");
  const treasuryAddr = fs.existsSync(treasuryMeta)
    ? JSON.parse(fs.readFileSync(treasuryMeta, "utf-8")).predictedAddress
    : CONET_TREASURY_CREATE2_PREDICTED;

  if (process.env.SKIP_PEER !== "1") {
    console.log("\n[2/3] deployConetTreasuryPeerCreate2");
    runScript("deployConetTreasuryPeerCreate2.ts", {
      CONET_TREASURY: treasuryAddr,
      ...(dryRun ? { DRY_RUN: "1" } : {}),
    });
  }

  if (dryRun || process.env.SKIP_LINK === "1") {
    console.log("\n跳过 setPeerModule（DRY_RUN 或 SKIP_LINK=1）");
    return;
  }

  const peerMeta = path.join(root, "deployments", "conetTreasuryPeer-create2-meta.json");
  const peerAddr = fs.existsSync(peerMeta)
    ? JSON.parse(fs.readFileSync(peerMeta, "utf-8")).predictedAddress
    : CONET_TREASURY_PEER_CREATE2_PREDICTED;

  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("无签名账户");

  const treasury = await ethers.getContractAt("ConetTreasury", treasuryAddr, signer);
  const currentPeer = await treasury.peerModule();
  if (currentPeer.toLowerCase() === peerAddr.toLowerCase()) {
    console.log("\n[3/3] peerModule 已链接:", peerAddr);
  } else {
    console.log("\n[3/3] setPeerModule(", peerAddr, ")");
    const tx = await treasury.setPeerModule(peerAddr);
    await tx.wait();
    console.log("   peerModule:", await treasury.peerModule());
  }

  console.log("\n下一步:");
  console.log("  configureConetTreasuryPeerBridge.ts — Peer 上 setBUint/setConetGB + 角色授权");
  console.log("  registerPeerBridgeAssets.ts — 登记 wCNET/BUint/GB peer 键");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
