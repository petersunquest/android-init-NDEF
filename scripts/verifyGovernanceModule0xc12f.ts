/**
 * 使用 Standard JSON 通过 BaseScan API 验证 GovernanceModule 0xc12fBEA081aD0B8143747Fd2935CE6b61734eB41
 *
 * 运行: npx tsx scripts/verifyGovernanceModule0xc12f.ts
 * 需设置 BASESCAN_API_KEY 或 ETHERSCAN_API_KEY
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const ADDRESS = "0xc12fBEA081aD0B8143747Fd2935CE6b61734eB41";
const BASESCAN_API = "https://api.basescan.org/api";
const CHAIN_ID = 8453;
const COMPILER_VERSION = "v0.8.33+commit.64118f21";
const CONTRACT_NAME = "project/src/BeamioUserCard/GovernanceModule.sol:BeamioUserCardGovernanceModuleV1";

async function main() {
  const jsonPath = path.join(__dirname, "../deployments/base-GovernanceModule-standard-input.min.json");
  if (!fs.existsSync(jsonPath)) {
    throw new Error(`未找到 Standard JSON: ${jsonPath}\n请先运行:\n  npx tsx scripts/exportMinimalStandardJson.ts --root project/src/BeamioUserCard/GovernanceModule.sol --out deployments/base-GovernanceModule-standard-input.min.json`);
  }

  const standardJson = fs.readFileSync(jsonPath, "utf-8");
  const apiKey = process.env.BASESCAN_API_KEY || process.env.ETHERSCAN_API_KEY;
  if (!apiKey) {
    throw new Error("请设置 BASESCAN_API_KEY 或 ETHERSCAN_API_KEY");
  }

  const params = new URLSearchParams();
  params.append("module", "contract");
  params.append("action", "verifysourcecode");
  params.append("chainid", String(CHAIN_ID));
  params.append("contractaddress", ADDRESS);
  params.append("sourceCode", standardJson);
  params.append("codeformat", "solidity-standard-json-input");
  params.append("contractname", CONTRACT_NAME);
  params.append("compilerversion", COMPILER_VERSION);
  params.append("constructorArguements", "");
  params.append("apikey", apiKey);
  params.append("licenseType", "3");

  console.log("BaseScan 验证 GovernanceModule");
  console.log("  地址:", ADDRESS);
  console.log("  Contract Name:", CONTRACT_NAME);
  console.log("  Compiler:", COMPILER_VERSION);
  console.log("  Standard JSON 大小:", standardJson.length, "bytes");
  console.log("\n提交中...");

  const res = await fetch(BASESCAN_API, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: params.toString(),
  });

  const data = (await res.json().catch(() => ({}))) as { status?: string; result?: string; message?: string };

  if (!res.ok) {
    console.error("API 响应 status:", res.status, res.statusText);
    console.error("API 响应:", JSON.stringify(data, null, 2));
    process.exit(1);
  }

  if (data.status === "1" || data.result?.toLowerCase().includes("guid") || data.message?.toLowerCase().includes("successfully")) {
    console.log("\n✅ 验证已提交！");
    if (data.result) console.log("  GUID:", data.result);
    if (data.message) console.log("  ", data.message);
    console.log("\n  查看: https://basescan.org/address/" + ADDRESS + "#code");
  } else {
    console.error("\n❌ 验证失败:", data.message || data.result || JSON.stringify(data));
    process.exit(1);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
