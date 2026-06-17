/**
 * BaseScan Standard JSON 验证 Beamio AA + Oracle 栈（8453）。
 *
 * 前置:
 *   npm run clean && npm run compile
 *   node scripts/exportBeamioStackBaseScanVerifyBundle.mjs
 *   node scripts/exportBeamioStackBaseScanFormJson.mjs
 *
 * 运行:
 *   BASESCAN_API_KEY=... npx tsx scripts/verifyBeamioStackBaseScan.ts
 *   BASESCAN_API_KEY=... npx tsx scripts/verifyBeamioStackBaseScan.ts BeamioOracle
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const BASESCAN_API = "https://api.etherscan.io/v2/api";
const CHAIN_ID = 8453;
const COMPILER_VERSION = "v0.8.33+commit.64118f21";

type VerifyItem = {
  exportKey: string;
  label: string;
  address: string;
  contractName: string;
  jsonPath: string;
  constructorArgs: string;
};

function loadBundle(): VerifyItem[] {
  const bundlePath = path.join(root, "deployments", "base-BeamioStack-verify-bundle.json");
  if (!fs.existsSync(bundlePath)) {
    throw new Error("缺少 base-BeamioStack-verify-bundle.json；请先 node scripts/exportBeamioStackBaseScanVerifyBundle.mjs");
  }
  const bundle = JSON.parse(fs.readFileSync(bundlePath, "utf-8")) as {
    contracts: Array<{
      exportKey: string;
      label: string;
      address: string;
      contractName: string;
      formJsonRel: string;
      constructorArgs: string;
    }>;
  };
  return bundle.contracts.map((c) => ({
    exportKey: c.exportKey,
    label: c.label,
    address: c.address,
    contractName: c.contractName,
    jsonPath: path.join(root, c.formJsonRel),
    constructorArgs: c.constructorArgs ?? "",
  }));
}

async function waitVerify(guid: string, apiKey: string): Promise<string> {
  for (let i = 0; i < 40; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const url =
      `${BASESCAN_API}?chainid=${CHAIN_ID}&module=contract&action=checkverifystatus` +
      `&guid=${encodeURIComponent(guid)}&apikey=${encodeURIComponent(apiKey)}`;
    const res = await fetch(url);
    const data = (await res.json()) as { status?: string; result?: string };
    const result = String(data.result ?? "");
    if (/pass|already verified/i.test(result)) return result;
    if (/fail/i.test(result)) return result;
  }
  return "Pending (poll timeout)";
}

async function verifyOne(item: VerifyItem, apiKey: string): Promise<void> {
  if (!fs.existsSync(item.jsonPath)) {
    throw new Error(`缺少 ${item.jsonPath}；请先 exportBeamioStackBaseScanFormJson.mjs`);
  }
  const standardJson = fs.readFileSync(item.jsonPath, "utf-8");
  const sizeKb = (fs.statSync(item.jsonPath).size / 1024).toFixed(1);
  console.log(`\n=== ${item.exportKey} @ ${item.address} (${sizeKb} KB) ===`);

  const params = new URLSearchParams({
    chainid: String(CHAIN_ID),
    module: "contract",
    action: "verifysourcecode",
    contractaddress: item.address,
    codeformat: "solidity-standard-json-input",
    contractname: item.contractName,
    compilerversion: COMPILER_VERSION,
    constructorArguements: item.constructorArgs,
    sourceCode: standardJson,
    apikey: apiKey,
  });

  const res = await fetch(BASESCAN_API, { method: "POST", body: params });
  const data = (await res.json()) as { status?: string; message?: string; result?: string };
  if (data.status !== "1") {
    throw new Error(`${item.exportKey} submit failed: ${data.message ?? ""} ${data.result ?? ""}`);
  }
  const guid = String(data.result);
  console.log("submitted guid:", guid);
  const status = await waitVerify(guid, apiKey);
  console.log("result:", status);
}

async function main() {
  const apiKey = process.env.BASESCAN_API_KEY || process.env.ETHERSCAN_API_KEY;
  if (!apiKey) throw new Error("请设置 BASESCAN_API_KEY 或 ETHERSCAN_API_KEY");

  const only = process.env.BASESCAN_VERIFY_ONLY;
  let items = loadBundle();
  if (only) items = items.filter((i) => i.exportKey === only);
  if (items.length === 0) throw new Error("无匹配合约");

  for (const item of items) {
    await verifyOne(item, apiKey);
  }
  console.log("\n✅ Beamio stack BaseScan 验证流程完成");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
