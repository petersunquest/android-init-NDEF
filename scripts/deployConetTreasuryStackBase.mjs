#!/usr/bin/env node
/**
 * Base (8453) 一键部署 ConetTreasury 栈 + 导出验证 JSON。
 *
 * 私钥来源（按优先级）:
 *   DEPLOYER_PRIVATE_KEY / MINER_PRIVATE_KEY 环境变量
 *   ~/.master.json（settle_contractAdmin + beamio_Admins + admin）
 *
 * 用法:
 *   node scripts/deployConetTreasuryStackBase.mjs
 *   DRY_RUN=1 node scripts/deployConetTreasuryStackBase.mjs
 *   SKIP_EXPORT=1 node scripts/deployConetTreasuryStackBase.mjs
 */

import { execSync } from "child_process";
import fs from "fs";
import path from "path";
import { Wallet } from "ethers";
import { fileURLToPath } from "url";
import { homedir } from "os";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const DEPLOYER_PREF = [
  "0x66BAb8A64764e659Fa7FF41D19aDFbb7b956CED2",
  "0x24103Ea5eA17aBFfDA8b2904acCA679C798b3695",
  "0x678F3570F9173373bB75e7544fcF383153aDAF4C",
];
const MINER = "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1";

function loadMasterKeys() {
  const setupPath = path.join(homedir(), ".master.json");
  if (!fs.existsSync(setupPath)) return [];
  const master = JSON.parse(fs.readFileSync(setupPath, "utf-8"));
  const raw = [
    ...(master?.settle_contractAdmin ?? []),
    ...(master?.beamio_Admins ?? []),
    ...(master?.admin ?? []),
  ].filter((k) => typeof k === "string" && k.length > 0);
  return [...new Set(raw.map((k) => (k.startsWith("0x") ? k : `0x${k}`)))];
}

function keyForAddress(keys, target) {
  const want = target.toLowerCase();
  for (const pk of keys) {
    if (new Wallet(pk).address.toLowerCase() === want) return pk;
  }
  return null;
}

function runHardhat(script, pk, extraEnv = {}) {
  const env = {
    ...process.env,
    PRIVATE_KEY: pk,
    HARDHAT_NETWORK: "base",
    ...extraEnv,
  };
  execSync(`npx hardhat run scripts/${script} --network base`, {
    cwd: root,
    stdio: "inherit",
    env,
  });
}

function main() {
  const dryRun = process.env.DRY_RUN === "1";
  const masterKeys = loadMasterKeys();

  const deployerPk =
    process.env.DEPLOYER_PRIVATE_KEY?.trim() ||
    keyForAddress(masterKeys, DEPLOYER_PREF[0]) ||
    keyForAddress(masterKeys, DEPLOYER_PREF[1]) ||
    keyForAddress(masterKeys, DEPLOYER_PREF[2]) ||
    masterKeys[0];
  const minerPk =
    process.env.MINER_PRIVATE_KEY?.trim() || keyForAddress(masterKeys, MINER) || deployerPk;

  if (!deployerPk) {
    console.error("无可用私钥：请设置 DEPLOYER_PRIVATE_KEY 或 ~/.master.json");
    process.exit(1);
  }

  console.log("Base ConetTreasury stack deploy");
  console.log("deployer:", new Wallet(deployerPk).address);
  console.log("miner:   ", new Wallet(minerPk).address);
  console.log("DRY_RUN:", dryRun);

  const deployEnv = dryRun ? { DRY_RUN: "1" } : {};

  console.log("\n[1/7] Treasury + Peer CREATE2 (SKIP_LINK)");
  runHardhat("deployConetTreasuryStackCreate2.ts", deployerPk, {
    ...deployEnv,
    SKIP_LINK: "1",
  });

  console.log("\n[2/7] BeamioBUnits CREATE2");
  runHardhat("deployBUintCreate2.ts", deployerPk, deployEnv);

  console.log("\n[3/7] ConetGB stack CREATE2");
  runHardhat("deployGBStackCreate2.ts", deployerPk, deployEnv);

  if (dryRun) {
    console.log("\nDRY_RUN — skip miner txs + export");
    return;
  }

  console.log("\n[4/7] Treasury.setPeerModule(Peer)");
  runHardhat("deployConetTreasuryStackCreate2.ts", minerPk, {
    SKIP_TREASURY: "1",
    SKIP_PEER: "1",
  });

  console.log("\n[5/7] configureConetTreasuryPeerBridge");
  runHardhat("configureConetTreasuryPeerBridge.ts", minerPk);

  console.log("\n[6/7] registerPeerBridgeAssets (peer 224422)");
  runHardhat("registerPeerBridgeAssets.ts", minerPk);

  console.log("\n[7/7] registerWrappedConetNative");
  runHardhat("registerWrappedConetNative.ts", minerPk);

  if (process.env.SKIP_EXPORT !== "1") {
    console.log("\n[export] Standard JSON + verify meta");
    execSync("node scripts/exportConetTreasuryStackStandardJson.mjs", {
      cwd: root,
      stdio: "inherit",
    });
  }

  console.log("\nDone. BaseScan: https://basescan.org — use deployments/base-*-standard-input-FULL.json");
}

main();
