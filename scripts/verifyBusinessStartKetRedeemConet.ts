/**
 * CoNET Explorer 验证 BusinessStartKetRedeem
 *
 * 运行: npx hardhat run scripts/verifyBusinessStartKetRedeemConet.ts --network conet
 */

import { execSync } from "child_process";
import * as path from "path";
import * as fs from "fs";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const DEPLOY_PATH = path.join(__dirname, "../deployments/conet-BusinessStartKetRedeem.json");

function runVerify(address: string, constructorArgs: string[]): void {
  const args = [
    "npx",
    "hardhat",
    "verify",
    "blockscout",
    "--network",
    "conet",
    "--contract",
    "src/b-unit/BusinessStartKetRedeem.sol:BusinessStartKetRedeem",
    address,
    ...constructorArgs,
  ];
  try {
    execSync(args.join(" "), { stdio: "inherit", cwd: path.join(__dirname, "..") });
  } catch (e) {
    const output = (e as { stderr?: Buffer })?.stderr?.toString() ?? String(e);
    if (
      output.includes("Already Verified") ||
      output.includes("already verified") ||
      output.includes("Contract source code already verified")
    ) {
      console.log("Already verified, skip.");
      return;
    }
    throw e;
  }
}

async function main(): Promise<void> {
  if (!fs.existsSync(DEPLOY_PATH)) {
    throw new Error("缺少 deployments/conet-BusinessStartKetRedeem.json");
  }
  const data = JSON.parse(fs.readFileSync(DEPLOY_PATH, "utf-8"));
  const address = data.contracts?.BusinessStartKetRedeem?.address as string | undefined;
  const ca = data.constructorArgs as { ket?: string; buint?: string; initialRedeemAdmin?: string } | undefined;
  const ket = ca?.ket ?? data.contracts?.BusinessStartKetRedeem?.ket;
  const buint = ca?.buint ?? data.contracts?.BusinessStartKetRedeem?.buint;
  const initAdmin = ca?.initialRedeemAdmin;
  if (!address) throw new Error("缺少 contracts.BusinessStartKetRedeem.address");
  if (!ket || !buint || !initAdmin) throw new Error("constructorArgs 缺少 ket / buint / initialRedeemAdmin");

  console.log("=".repeat(60));
  console.log("Verify BusinessStartKetRedeem on CoNET Explorer");
  console.log("=".repeat(60));
  console.log("address:", address);

  const ck = (a: string) => ethers.getAddress(a);
  runVerify(address, [ck(ket), ck(buint), ck(initAdmin)]);
  console.log("Done.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
