/**
 * Verify ConetTreasury and conetUsdc (FactoryERC20) on CoNET Mainnet Explorer.
 *
 * Run: npx hardhat run scripts/verifyConetTreasuryAndUsdc.ts --network conet
 */

import { execSync } from "child_process";
import * as path from "path";
import * as fs from "fs";
import { CONET_TREASURY_INITIAL_MINER } from "./conetTreasuryDeployConstants.js";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const TREASURY_PATH = path.join(__dirname, "..", "deployments", "conet-ConetTreasury.json");

function runVerify(address: string, contract: string, constructorArgs: string[] = []): boolean {
  const args = [
    "npx",
    "hardhat",
    "verify",
    "blockscout",
    "--network",
    "conet",
    "--contract",
    contract,
    address,
    ...constructorArgs,
  ];
  try {
    execSync(args.join(" "), {
      stdio: "inherit",
      cwd: path.join(__dirname, ".."),
      shell: true,
    });
    return true;
  } catch (e) {
    const output = (e as { stdout?: Buffer; stderr?: Buffer })?.stderr?.toString() ?? "";
    if (
      output.includes("Already Verified") ||
      output.includes("already verified") ||
      output.includes("Contract source code already verified")
    ) {
      return true;
    }
    throw e;
  }
}

async function main() {
  if (!fs.existsSync(TREASURY_PATH)) {
    throw new Error("缺少 conet-ConetTreasury.json");
  }

  const treasuryData = JSON.parse(fs.readFileSync(TREASURY_PATH, "utf-8"));
  const treasuryAddr = treasuryData.contracts?.ConetTreasury?.address;
  const conetUsdcAddr = treasuryData.contracts?.ConetTreasury?.conetUsdc;

  if (!treasuryAddr) {
    throw new Error("conet-ConetTreasury.json 缺少 ConetTreasury 地址");
  }
  if (!conetUsdcAddr) {
    throw new Error("conet-ConetTreasury.json 缺少 conetUsdc 地址");
  }

  console.log("=".repeat(60));
  console.log("验证 ConetTreasury 与 conetUsdc 到 CoNET Explorer");
  console.log("=".repeat(60));
  console.log("ConetTreasury:", treasuryAddr);
  console.log("conetUsdc (FactoryERC20):", conetUsdcAddr);

  // 1. 验证 ConetTreasury - constructor(initialMiner)
  console.log("\n[1/2] 验证 ConetTreasury...");
  try {
    runVerify(treasuryAddr, "src/b-unit/conetTreasury.sol:ConetTreasury", [
      CONET_TREASURY_INITIAL_MINER,
    ]);
    console.log("  ✅ ConetTreasury 验证成功");
  } catch (e) {
    const msg = (e as Error)?.message ?? "";
    if (msg.includes("Already Verified") || msg.includes("already verified")) {
      console.log("  ⏭️ ConetTreasury 已验证，跳过");
    } else {
      throw e;
    }
  }

  // 2. 验证 conetUsdc (FactoryERC20) - constructor(name_, symbol_, decimals_, minter_)
  // name="USD Coin", symbol="USDC", decimals=6, minter=ConetTreasury
  console.log("\n[2/2] 验证 conetUsdc (FactoryERC20)...");
  try {
    runVerify(conetUsdcAddr, "src/b-unit/conetTreasury.sol:FactoryERC20", [
      '"USD Coin"',
      '"USDC"',
      "6",
      treasuryAddr,
    ]);
    console.log("  ✅ conetUsdc 验证成功");
  } catch (e) {
    const msg = (e as Error)?.message ?? "";
    if (msg.includes("Already Verified") || msg.includes("already verified")) {
      console.log("  ⏭️ conetUsdc 已验证，跳过");
    } else {
      throw e;
    }
  }

  console.log("\n✅ 全部验证完成！");
  console.log("  ConetTreasury: https://mainnet.conet.network/address/" + treasuryAddr + "#code");
  console.log("  conetUsdc: https://mainnet.conet.network/address/" + conetUsdcAddr + "#code");
  const wrappedPath = path.join(__dirname, "..", "deployments", "conetTreasury-wrapped-base-usdc-meta.json");
  if (fs.existsSync(wrappedPath)) {
    const wrapped = JSON.parse(fs.readFileSync(wrappedPath, "utf-8")).predictedWrapped as string | undefined;
    if (wrapped) {
      console.log("  wrapped Base USDC: https://mainnet.conet.network/address/" + wrapped + "#code");
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
