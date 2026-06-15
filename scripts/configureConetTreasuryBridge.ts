/**
 * ConetTreasury 跨链桥 post-deploy（各链 CREATE2 同址后执行）:
 *   setBUnitAirdrop / setConetGB / GB.grantRole(ISSUER_ROLE, treasury)
 *
 * 环境变量:
 *   CONET_TREASURY — Treasury 地址（默认 deployments/conetTreasury-create2-meta.json）
 *   BUNIT_AIRDROP — 可选；CoNET 等链有 BUnitAirdrop 时设置
 *   CONET_GB — 可选；该链 ConetGB1155 地址
 *   SKIP_GB_ISSUER_GRANT=1 — 跳过 GB ISSUER 授权
 *
 * 运行:
 *   npx hardhat run scripts/configureConetTreasuryBridge.ts --network conet
 *   npx hardhat run scripts/configureConetTreasuryBridge.ts --network base
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function resolveTreasuryAddress(): string {
  if (process.env.CONET_TREASURY) return process.env.CONET_TREASURY;
  const metaPath = path.join(__dirname, "..", "deployments", "conetTreasury-create2-meta.json");
  if (fs.existsSync(metaPath)) {
    const meta = JSON.parse(fs.readFileSync(metaPath, "utf-8"));
    if (meta.predictedAddress) return meta.predictedAddress;
  }
  throw new Error("未找到 ConetTreasury；先 deployConetTreasuryCreate2 或设置 CONET_TREASURY");
}

function resolveFromAddressesJson(key: string): string | undefined {
  const chainId = process.env.CHAIN_ID;
  const candidates = [
    path.join(__dirname, "..", "deployments", "conet-addresses.json"),
    path.join(__dirname, "..", "config", "base-addresses.json"),
  ];
  for (const p of candidates) {
    if (!fs.existsSync(p)) continue;
    const data = JSON.parse(fs.readFileSync(p, "utf-8"));
    if (chainId && String(data.chainId) !== chainId) continue;
    if (data[key]) return data[key];
  }
  return undefined;
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("无签名账户");

  const treasuryAddress = resolveTreasuryAddress();
  const airdropAddress = process.env.BUNIT_AIRDROP || resolveFromAddressesJson("BUnitAirdrop");
  const gbAddress = process.env.CONET_GB || resolveFromAddressesJson("ConetGB1155");

  const treasury = await ethers.getContractAt("ConetTreasury", treasuryAddress, signer);
  const net = await ethers.provider.getNetwork();

  console.log("=".repeat(60));
  console.log("Configure ConetTreasury bridge");
  console.log("=".repeat(60));
  console.log("chainId:", net.chainId.toString());
  console.log("signer:", signer.address);
  console.log("ConetTreasury:", treasuryAddress);

  if (airdropAddress) {
    const current = await treasury.bunitAirdrop();
    if (current.toLowerCase() !== airdropAddress.toLowerCase()) {
      const tx = await treasury.setBUnitAirdrop(airdropAddress);
      await tx.wait();
      console.log("[1] setBUnitAirdrop:", airdropAddress);
    } else {
      console.log("[1] bunitAirdrop 已配置");
    }
  } else {
    console.log("[1] 无 BUNIT_AIRDROP，跳过");
  }

  if (gbAddress) {
    const currentGb = await treasury.conetGB();
    if (currentGb.toLowerCase() !== gbAddress.toLowerCase()) {
      const tx = await treasury.setConetGB(gbAddress);
      await tx.wait();
      console.log("[2] setConetGB:", gbAddress);
    } else {
      console.log("[2] conetGB 已配置");
    }

    if (process.env.SKIP_GB_ISSUER_GRANT !== "1") {
      const issuerRole = ethers.id("ISSUER_ROLE");
      const gb = await ethers.getContractAt(
        ["function hasRole(bytes32,address) view returns (bool)", "function grantRole(bytes32,address) external"],
        gbAddress,
        signer
      );
      const treasuryIsIssuer = await gb.hasRole(issuerRole, treasuryAddress);
      if (!treasuryIsIssuer) {
        const tx = await gb.grantRole(issuerRole, treasuryAddress);
        await tx.wait();
        console.log("[3] ConetGB1155.grantRole(ISSUER_ROLE, treasury) ok");
      } else {
        console.log("[3] Treasury 已是 GB ISSUER");
      }
    }
  } else {
    console.log("[2] 无 CONET_GB，跳过 GB 配置");
  }

  const targets = await treasury.getBridgeTargets();
  console.log("\ngetBridgeTargets():");
  console.log("  bunitAirdrop:", targets[0]);
  console.log("  conetGB:", targets[1]);
  console.log("  factoryTokenCount:", targets[2].toString());

  if (net.chainId === 224422n) {
    console.log("\nCoNET chain: run configureConetTreasuryOnConet for conetUSDC + BUnitAirdrop admin...");
    const { execSync } = await import("child_process");
    execSync(`npx hardhat run scripts/configureConetTreasuryOnConet.ts --network conet`, {
      stdio: "inherit",
      cwd: path.join(__dirname, ".."),
    });
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
