/**
 * 在 CoNET Explorer (Blockscout API) 验证 BusinessStartKet
 *
 * 运行: npx hardhat run scripts/verifyBusinessStartKetConet.ts --network conet
 *
 * 读取 deployments/conet-BusinessStartKet.json 中的 address + constructorArgs。
 */

import { execSync } from "child_process";
import * as path from "path";
import * as fs from "fs";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DEPLOY_PATH = path.join(__dirname, "../deployments/conet-BusinessStartKet.json");

function runVerify(address: string, constructorArgs: string[]): void {
  const args = [
    "npx",
    "hardhat",
    "verify",
    "blockscout",
    "--network",
    "conet",
    "--contract",
    "src/b-unit/businessStartKet.sol:BusinessStartKet",
    address,
    ...constructorArgs,
  ];
  try {
    execSync(args.join(" "), {
      stdio: "inherit",
      cwd: path.join(__dirname, ".."),
    });
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
    throw new Error("缺少 deployments/conet-BusinessStartKet.json，请先部署");
  }
  const data = JSON.parse(fs.readFileSync(DEPLOY_PATH, "utf-8"));
  const address = data.contracts?.BusinessStartKet?.address as string | undefined;
  const ca = data.constructorArgs as { uri?: string; name?: string; symbol?: string } | undefined;
  if (!address) throw new Error("conet-BusinessStartKet.json 缺少 contracts.BusinessStartKet.address");
  const uri = ca?.uri ?? data.contracts?.BusinessStartKet?.uri;
  const name = ca?.name ?? data.contracts?.BusinessStartKet?.name;
  const symbol = ca?.symbol ?? data.contracts?.BusinessStartKet?.symbol;
  if (typeof uri !== "string" || typeof name !== "string" || typeof symbol !== "string") {
    throw new Error("constructorArgs 或 contracts.BusinessStartKet 缺少 uri/name/symbol");
  }

  console.log("=".repeat(60));
  console.log("Verify BusinessStartKet on CoNET Explorer");
  console.log("=".repeat(60));
  console.log("address:", address);

  const quoted = (s: string) => JSON.stringify(s);

  runVerify(address, [quoted(uri), quoted(name), quoted(symbol)]);
  console.log("Done.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
