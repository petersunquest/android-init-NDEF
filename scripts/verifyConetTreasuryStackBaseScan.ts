/**
 * BaseScan Standard JSON 验证 ConetTreasury 栈（8453）。
 *
 * 前置:
 *   npm run clean && npm run compile
 *   node scripts/exportConetTreasuryStackStandardJson.mjs
 *
 * 运行:
 *   BASESCAN_API_KEY=... npx tsx scripts/verifyConetTreasuryStackBaseScan.ts
 *   BASESCAN_API_KEY=... npx tsx scripts/verifyConetTreasuryStackBaseScan.ts ConetTreasury
 *
 * 环境变量:
 *   BASESCAN_API_KEY / ETHERSCAN_API_KEY
 *   BASESCAN_VERIFY_ONLY=ConetTreasury|ConetTreasuryPeer|FactoryERC20|...
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

const BASESCAN_API = "https://api.etherscan.io/v2/api";
const CHAIN_ID = 8453;
const COMPILER_VERSION = "v0.8.33+commit.64118f21";

type VerifyItem = {
  exportKey: string;
  label: string;
  address: string;
  contractName: string;
  metaPath: string;
  jsonPath: string;
};

function loadBundle(): VerifyItem[] {
  const bundlePath = path.join(root, "deployments", "base-ConetTreasuryStack-verify-bundle.json");
  if (!fs.existsSync(bundlePath)) {
    throw new Error("缺少 base-ConetTreasuryStack-verify-bundle.json；请先 node scripts/exportConetTreasuryStackStandardJson.mjs");
  }
  const bundle = JSON.parse(fs.readFileSync(bundlePath, "utf-8")) as {
    contracts: Array<{
      exportKey: string;
      label: string;
      address: string;
      contractName: string;
      jsonRel: string;
      constructorArgs: string;
    }>;
  };
  return bundle.contracts.map((c) => ({
    exportKey: c.exportKey,
    label: c.label,
    address: c.address,
    contractName: c.contractName,
    metaPath: path.join(root, "deployments", `base-${c.exportKey}-basescan-verify-meta.txt`),
    jsonPath: path.join(root, c.jsonRel),
  }));
}

function constructorArgsFromMeta(metaPath: string): string {
  const text = fs.readFileSync(metaPath, "utf-8");
  const m = text.match(/Constructor Args ABI-encoded:\s*(\S+)/);
  if (!m || m[1] === "(none)") return "";
  return m[1].startsWith("0x") ? m[1].slice(2) : m[1];
}

function readJsonSizeKb(jsonPath: string): string {
  const n = fs.statSync(jsonPath).size;
  return (n / 1024).toFixed(1);
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
    throw new Error(`缺少 ${item.jsonPath}`);
  }
  const sizeKb = readJsonSizeKb(item.jsonPath);
  const parsed = JSON.parse(fs.readFileSync(item.jsonPath, "utf-8")) as {
    settings?: { compilationTarget?: unknown };
    sources?: Record<string, unknown>;
  };
  if (parsed.settings?.compilationTarget) {
    throw new Error(
      `${item.jsonPath} 含 settings.compilationTarget — BaseScan 不支持。请 node scripts/exportConetTreasuryStackStandardJson.mjs 重新导出。`
    );
  }
  const sourceCount = Object.keys(parsed.sources ?? {}).length;
  if (Number(sizeKb) < 500) {
    throw new Error(
      `${item.jsonPath} 仅 ${sizeKb} KB / ${sourceCount} sources — via-IR 须 build-info FULL（BeamioUserCard 约 1.2 MB）。` +
        " 请 npm run clean && npm run compile && node scripts/exportConetTreasuryStackStandardJson.mjs"
    );
  }

  const standardJson = fs.readFileSync(item.jsonPath, "utf-8");
  const constructorArgs = constructorArgsFromMeta(item.metaPath);

  const params = new URLSearchParams();
  params.append("chainid", String(CHAIN_ID));
  params.append("module", "contract");
  params.append("action", "verifysourcecode");
  params.append("contractaddress", item.address);
  params.append("sourceCode", standardJson);
  params.append("codeformat", "solidity-standard-json-input");
  params.append("contractname", item.contractName);
  params.append("compilerversion", COMPILER_VERSION);
  params.append("constructorArguements", constructorArgs);
  params.append("apikey", apiKey);

  console.log(`\n--- ${item.label} @ ${item.address} ---`);
  console.log("  contractname:", item.contractName);
  console.log("  standard json:", path.basename(item.jsonPath), `(${sizeKb} KB)`);
  console.log("  constructorArguements:", constructorArgs ? `${constructorArgs.slice(0, 42)}…` : "(none)");

  const res = await fetch(BASESCAN_API, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: params.toString(),
  });
  const data = (await res.json()) as { status?: string; result?: string; message?: string };
  console.log("  submit:", data.message ?? "", data.result ?? "");

  if (data.status !== "1" || !data.result) {
    throw new Error(`${item.label} 提交失败: ${data.message ?? JSON.stringify(data)}`);
  }

  const status = await waitVerify(data.result, apiKey);
  console.log("  result:", status);
  if (!/pass|already verified/i.test(status)) {
    throw new Error(`${item.label} 验证未通过: ${status}`);
  }
  console.log("  ✅ https://basescan.org/address/" + item.address + "#code");
}

async function main() {
  const apiKey = process.env.BASESCAN_API_KEY?.trim() || process.env.ETHERSCAN_API_KEY?.trim();
  if (!apiKey) {
    throw new Error("请设置 BASESCAN_API_KEY 或 ETHERSCAN_API_KEY");
  }

  const only = process.env.BASESCAN_VERIFY_ONLY?.trim() || process.argv[2]?.trim();
  let items = loadBundle();
  if (only) {
    items = items.filter((i) => i.exportKey === only || i.label === only);
    if (items.length === 0) throw new Error(`未知合约: ${only}`);
  }

  console.log("BaseScan ConetTreasury stack verification (chainId 8453)");
  for (const item of items) {
    await verifyOne(item, apiKey);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
