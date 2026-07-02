/**
 * CoNET Blockscout 验证 conet-USDC UUPS 栈（impl Standard JSON + proxy legacy partial）。
 *
 * 运行:
 *   npm run clean && npm run compile
 *   npx tsx scripts/exportConetUsdcUupsStandardJson.ts
 *   npx tsx scripts/verifyErc20UupsUsdcConet.ts
 */
import * as fs from "fs";
import * as path from "path";
import { AbiCoder, getAddress, Interface } from "ethers";
import { fileURLToPath } from "url";
import {
  CONET_USDC_MINTER,
  CONET_USDC_TOKEN_DECIMALS,
  CONET_USDC_TOKEN_NAME,
  CONET_USDC_TOKEN_SYMBOL,
  CONET_USDC_UUPS_IMPL_PREDICTED,
  CONET_USDC_UUPS_PROXY_PREDICTED,
} from "./erc20UupsDeployConstants.js";
import { buildErc1967ProxyInitCode } from "./utils/erc20UupsCreate2.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const BLOCKSCOUT_API = (process.env.CONET_BLOCKSCOUT_API || "https://mainnet.conet.network/api").replace(/\/$/, "");
const BLOCKSCOUT_UI = (process.env.CONET_BLOCKSCOUT_UI || "https://mainnet.conet.network").replace(/\/$/, "");
const COMPILER_VERSION = "v0.8.35+commit.47b9dedd";
const OZ_PROXY_COMPILER = "v0.8.27+commit.40a35a09";
const IMPL_CONTRACT = "project/src/b-unit/FactoryERC20Upgradeable.sol:FactoryERC20Upgradeable";
const OZ_PROXY_CONTRACT = "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy";

async function getVerified(addr: string): Promise<boolean> {
  const res = await fetch(`${BLOCKSCOUT_UI}/api/v2/smart-contracts/${addr}`);
  if (!res.ok) return false;
  const j = (await res.json()) as { is_verified?: boolean; is_partially_verified?: boolean; source_code?: string };
  return Boolean(j.is_verified || j.is_partially_verified || j.source_code);
}

async function pollVerified(addr: string, label: string, maxMs = 180_000): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < maxMs) {
    if (await getVerified(addr)) {
      console.log(`✅ ${label} verified:`, addr);
      return;
    }
    await new Promise((r) => setTimeout(r, 5000));
  }
  throw new Error(`${label} 验证超时: ${addr}`);
}

async function verifyImpl(impl: string): Promise<void> {
  if (await getVerified(impl)) {
    console.log("skip impl (already verified):", impl);
    return;
  }
  const jsonPath = path.join(root, "deployments/base-FactoryERC20Upgradeable-standard-input-FULL-FORM.json");
  if (!fs.existsSync(jsonPath)) {
    throw new Error(`缺少 ${jsonPath}，请先 npx tsx scripts/exportConetUsdcUupsStandardJson.ts`);
  }
  const standardInput = fs.readFileSync(jsonPath, "utf-8");
  const form = new FormData();
  form.set("compiler_version", COMPILER_VERSION);
  form.set("contract_name", IMPL_CONTRACT);
  form.set("autodetect_constructor_args", "true");
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([standardInput], { type: "application/json" }), "standard-input.json");

  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${impl}/verification/via/standard-input`;
  console.log("POST", url, `(${(standardInput.length / 1024).toFixed(1)} KB)`);
  const res = await fetch(url, { method: "POST", body: form });
  const text = await res.text();
  if (!res.ok) throw new Error(`impl verify HTTP ${res.status}: ${text}`);
  console.log("impl verify submitted:", text.slice(0, 200));
  await pollVerified(impl, "impl");
}

async function verifyProxy(proxy: string, impl: string): Promise<void> {
  if (await getVerified(proxy)) {
    console.log("skip proxy (already verified):", proxy);
    return;
  }
  const iface = new Interface([
    "function initialize(string,string,uint8,address)",
  ]);
  const initData = iface.encodeFunctionData("initialize", [
    CONET_USDC_TOKEN_NAME,
    CONET_USDC_TOKEN_SYMBOL,
    CONET_USDC_TOKEN_DECIMALS,
    CONET_USDC_MINTER,
  ]);
  const constructorArgs = new AbiCoder().encode(["address", "bytes"], [getAddress(impl), initData]).slice(2);

  const ozJson = path.join(root, "deployments/oz-ERC1967Proxy-standard-input.json");
  if (!fs.existsSync(ozJson)) {
    console.warn("缺少 oz-ERC1967Proxy-standard-input.json");
    console.log("proxy constructor args (hex):", constructorArgs);
    return;
  }

  const params = new URLSearchParams({
    module: "contract",
    action: "verifysourcecode",
    contractaddress: proxy,
    codeformat: "solidity-standard-json-input",
    contractname: OZ_PROXY_CONTRACT,
    compilerversion: OZ_PROXY_COMPILER,
    optimizationUsed: "0",
    constructorArguements: constructorArgs,
  });

  const form = new FormData();
  for (const [k, v] of params.entries()) form.append(k, v);
  form.append("sourceCode", fs.readFileSync(ozJson, "utf-8"));

  const res = await fetch(`${BLOCKSCOUT_API}?${params.toString()}`, { method: "POST", body: form });
  const text = await res.text();
  console.log("proxy legacy verify:", text.slice(0, 300));
  await pollVerified(proxy, "proxy");
}

async function main() {
  const impl = getAddress(process.env.CONET_USDC_UUPS_IMPL || CONET_USDC_UUPS_IMPL_PREDICTED);
  const proxy = getAddress(process.env.CONET_USDC_UUPS_PROXY || CONET_USDC_UUPS_PROXY_PREDICTED);
  console.log("impl:", impl);
  console.log("proxy:", proxy);
  await verifyImpl(impl);
  await verifyProxy(proxy, impl);
  console.log(`Token: ${BLOCKSCOUT_UI}/token/${proxy}`);
  console.log(`Code:  ${BLOCKSCOUT_UI}/address/${proxy}#code`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
