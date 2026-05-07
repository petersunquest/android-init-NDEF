/**
 * 仅部署 BeamioUserCard 依赖的两个链接库（Formatting + Transfer），并写入部署记录与 config。
 *
 * 私钥与部署 BeamioAccount 一致（见 hardhat.config.ts `networks.base.accounts`）：
 * - 优先：环境变量 PRIVATE_KEY（通常由 .env 注入，与 `npm run deploy:base` / deployBeamioAccount 相同）
 * - 若无 Hardhat signer：回退 ~/.master.json 的 settle_contractAdmin[0]（与 createCCSACard 相同）
 *
 * 用法:
 *   npx hardhat run scripts/deployBeamioUserCardLibrariesOnly.ts --network base
 *   npm run deploy:usercard-libraries:base
 *
 * 成功后:
 *   - deployments/{network}-BeamioUserCardLibraries.json
 *   - 更新 config/base-addresses.json 中的 BEAMIO_USER_CARD_FORMATTING_LIB / BEAMIO_USER_CARD_TRANSFER_LIB
 *   - 运行 node scripts/syncBaseAddressesJsonToX402sdkChainAddresses.mjs
 *
 * BaseScan 验证: 使用 deployments/base-BeamioUserCardFormattingLib-standard-input-FULL.json 等（先 npm run export:standard-json:full:usercard-stack 或单独 export）。
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";
import { deployBeamioUserCardLibraries } from "./beamioUserCardLibraries.js";
import { execSync } from "child_process";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");

function getMasterJsonPath(): string {
  const candidates = [
    path.join(homedir(), ".master.json"),
    process.env.HOME ? path.join(process.env.HOME, ".master.json") : "",
    process.env.USERPROFILE ? path.join(process.env.USERPROFILE, ".master.json") : "",
  ].filter(Boolean) as string[];
  return candidates.find((p) => fs.existsSync(p)) ?? candidates[0] ?? path.join(homedir(), ".master.json");
}

function loadAdminFromMaster(): { privateKey: string } | null {
  const f = getMasterJsonPath();
  if (!fs.existsSync(f)) return null;
  try {
    const data = JSON.parse(fs.readFileSync(f, "utf-8"));
    const pks = data?.settle_contractAdmin;
    if (!Array.isArray(pks) || pks.length === 0) return null;
    const pk = String(pks[0]).trim();
    const key = pk.startsWith("0x") ? pk : `0x${pk}`;
    if (key.length < 64) return null;
    return { privateKey: key };
  } catch {
    return null;
  }
}

async function main() {
  const { ethers } = await networkModule.connect();
  let deployer = (await ethers.getSigners())[0];
  if (!deployer) {
    const masterAdmin = loadAdminFromMaster();
    if (!masterAdmin) {
      console.error(
        "无 deployer：请与部署 BeamioAccount 相同方式配置 Base 私钥，任选其一：\n" +
          "  1) .env 中设置 PRIVATE_KEY（Hardhat networks.base.accounts）\n" +
          "  2) 或在 ~/.master.json 配置 settle_contractAdmin[0]\n" +
          "然后执行: npm run deploy:usercard-libraries:base"
      );
      process.exit(1);
    }
    deployer = new ethers.Wallet(masterAdmin.privateKey, ethers.provider);
    console.log("使用 ~/.master.json settle_contractAdmin[0] 作为 deployer（与 createCCSACard 一致）:", deployer.address);
  }
  const net = await ethers.provider.getNetwork();
  const chainSlug =
    net.chainId === 8453n ? "base" : net.chainId === 84532n ? "baseSepolia" : `chain-${net.chainId}`;

  console.log("Deployer:", deployer.address);
  console.log("Network:", net.name, "chainId:", net.chainId.toString());

  const libs = await deployBeamioUserCardLibraries(ethers, deployer);

  console.log("BeamioUserCardFormattingLib:", libs.BeamioUserCardFormattingLib);
  console.log("BeamioUserCardTransferLib:", libs.BeamioUserCardTransferLib);
  if (libs.formattingDeployTxHash) console.log("  Formatting tx:", libs.formattingDeployTxHash);
  if (libs.transferDeployTxHash) console.log("  Transfer tx:", libs.transferDeployTxHash);

  const outPath = path.join(ROOT, "deployments", `${chainSlug}-BeamioUserCardLibraries.json`);
  const record = {
    network: net.name,
    chainId: net.chainId.toString(),
    deployer: deployer.address,
    contracts: {
      beamioUserCardFormattingLib: {
        address: libs.BeamioUserCardFormattingLib,
        txHash: libs.formattingDeployTxHash ?? null,
      },
      beamioUserCardTransferLib: {
        address: libs.BeamioUserCardTransferLib,
        txHash: libs.transferDeployTxHash ?? null,
      },
    },
  };
  fs.writeFileSync(outPath, JSON.stringify(record, null, 2), "utf-8");
  console.log("Wrote:", outPath);

  const baseJsonPath = path.join(ROOT, "config", "base-addresses.json");
  if (net.chainId === 8453n && fs.existsSync(baseJsonPath)) {
    const j = JSON.parse(fs.readFileSync(baseJsonPath, "utf-8")) as Record<string, unknown>;
    j.BEAMIO_USER_CARD_FORMATTING_LIB = libs.BeamioUserCardFormattingLib;
    j.BEAMIO_USER_CARD_TRANSFER_LIB = libs.BeamioUserCardTransferLib;
    fs.writeFileSync(baseJsonPath, JSON.stringify(j, null, 2) + "\n", "utf-8");
    console.log("Updated config/base-addresses.json (Formatting + Transfer lib addresses)");

    try {
      execSync("node scripts/syncBaseAddressesJsonToX402sdkChainAddresses.mjs", {
        cwd: ROOT,
        stdio: "inherit",
      });
    } catch {
      console.warn("syncBaseAddressesJsonToX402sdkChainAddresses.mjs failed; run it manually.");
    }
    try {
      execSync("node scripts/syncBeamioUserCardToX402sdk.mjs", { cwd: ROOT, stdio: "inherit" });
    } catch {
      console.warn("syncBeamioUserCardToX402sdk.mjs failed; run manually after compile.");
    }
  } else if (net.chainId !== 8453n) {
    console.log("Skip base-addresses.json (only auto-patch for Base mainnet 8453).");
  }

  const verifyDir = path.join(ROOT, "deployments");
  const fmtMeta = path.join(verifyDir, `base-BeamioUserCardFormattingLib-basescan-verify-meta.txt`);
  const trMeta = path.join(verifyDir, `base-BeamioUserCardTransferLib-basescan-verify-meta.txt`);
  const metaBody = (contractPath: string, name: string, addr: string) => `${name} BaseScan 验证
================================

Compiler Version: 0.8.33+commit.64118f21
Optimization: Enabled, Runs: 0
viaIR: true, evmVersion: cancun

Contract Name: ${contractPath}:${name}

Deployed address: ${addr}

Standard JSON (FULL, via-IR):
  - deployments/base-${name}-standard-input-FULL.json

生成命令（根目录）:
  npm run clean && npm run compile
  node scripts/exportStandardJsonFromBuildInfo.mjs ${name} --full
`;
  if (net.chainId === 8453n) {
    fs.writeFileSync(
      fmtMeta,
      metaBody(
        "project/src/BeamioUserCard/BeamioUserCardFormattingLib.sol",
        "BeamioUserCardFormattingLib",
        libs.BeamioUserCardFormattingLib
      ),
      "utf-8"
    );
    fs.writeFileSync(
      trMeta,
      metaBody(
        "project/src/BeamioUserCard/BeamioUserCardTransferLib.sol",
        "BeamioUserCardTransferLib",
        libs.BeamioUserCardTransferLib
      ),
      "utf-8"
    );
    console.log("Wrote:", fmtMeta, trMeta);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
