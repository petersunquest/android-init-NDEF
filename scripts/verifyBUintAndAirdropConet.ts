/**
 * 在 CoNET Mainnet Explorer (https://mainnet.conet.network/) 验证 BUint 与 BUnitAirdrop
 *
 * 运行: npx hardhat run scripts/verifyBUintAndAirdropConet.ts --network conet
 *   或: npm run verify:buint-airdrop:conet
 *
 * 通过执行 hardhat verify CLI 完成验证（Hardhat 3 中 run 接口已变更）
 */

import { execSync } from "child_process";
import * as path from "path";
import * as fs from "fs";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DEPLOYMENT = path.join(__dirname, "../deployments/conet-BUintAirdrop.json");

function runVerify(address: string, contract: string, constructorArgs: string[] = []): boolean {
  // 仅验证 Blockscout，避免 Sourcify (chain 224400 不支持) 报错
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
    });
    return true;
  } catch (e) {
    const output = (e as { stdout?: Buffer; stderr?: Buffer })?.stderr?.toString() ?? "";
    if (
      output.includes("Already Verified") ||
      output.includes("already verified") ||
      output.includes("Contract source code already verified")
    ) {
      return true; // 已验证视为成功
    }
    throw e;
  }
}

async function main() {
  const deploy = JSON.parse(fs.readFileSync(DEPLOYMENT, "utf-8"));
  const buintAddr = deploy.contracts?.BUint?.address;
  const airdropAddr = deploy.contracts?.BUnitAirdrop?.address;
  const deployer = deploy.deployer;

  if (!buintAddr || !airdropAddr || !deployer) {
    throw new Error("部署文件缺少 BUint / BUnitAirdrop 地址或 deployer");
  }

  console.log("=".repeat(60));
  console.log("验证 BUint 与 BUnitAirdrop 到 CoNET Explorer");
  console.log("=".repeat(60));
  console.log("BUint:", buintAddr);
  console.log("BUnitAirdrop:", airdropAddr);

  // 1. 验证 BeamioBUnits (BUint) - 无 constructor 参数
  console.log("\n[1/2] 验证 BeamioBUnits...");
  try {
    runVerify(buintAddr, "src/b-unit/BUint.sol:BeamioBUnits");
    console.log("  ✅ BeamioBUnits 验证成功");
  } catch (e) {
    const msg = (e as Error)?.message ?? "";
    if (msg.includes("Already Verified") || msg.includes("already verified")) {
      console.log("  ⏭️ BeamioBUnits 已验证，跳过");
    } else {
      throw e;
    }
  }

  // 2. 验证 BUnitAirdrop - constructor(_bunit, initialOwner)
  console.log("\n[2/2] 验证 BUnitAirdrop...");
  try {
    runVerify(airdropAddr, "src/b-unit/BUnitAirdrop.sol:BUnitAirdrop", [
      buintAddr,
      deployer,
    ]);
    console.log("  ✅ BUnitAirdrop 验证成功");
  } catch (e) {
    const msg = (e as Error)?.message ?? "";
    if (msg.includes("Already Verified") || msg.includes("already verified")) {
      console.log("  ⏭️ BUnitAirdrop 已验证，跳过");
    } else {
      throw e;
    }
  }

  console.log("\n✅ 全部验证完成！");
  console.log("  BUint: https://mainnet.conet.network/address/" + buintAddr);
  console.log("  BUnitAirdrop: https://mainnet.conet.network/address/" + airdropAddr);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
