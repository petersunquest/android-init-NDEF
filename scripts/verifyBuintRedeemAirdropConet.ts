/**
 * CoNET Blockscout Standard JSON 验证 BuintRedeemAirdrop（推荐 SUBSET，避免 413）
 *
 * 先: npm run export:buint-redeem-airdrop:conet:standard-json
 * 运行: npx tsx scripts/verifyBuintRedeemAirdropConet.ts
 */

import * as fs from "fs";
import * as path from "path";
import { AbiCoder } from "ethers";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BASE_URL = "https://mainnet.conet.network";
const COMPILER_VERSION = "v0.8.33+commit.64118f21";
const CONTRACT_NAME = "project/src/b-unit/BuintRedeemAirdrop.sol:BuintRedeemAirdrop";

const deployPath = path.join(__dirname, "../deployments/conet-BuintRedeemAirdrop.json");
const subsetPath = path.join(__dirname, "../deployments/conet-BuintRedeemAirdrop-standard-input-SUBSET.json");

async function main() {
  const deploy = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
  const address = deploy.contracts?.BuintRedeemAirdrop?.address as string;
  const buint = deploy.contracts?.BuintRedeemAirdrop?.buint as string;
  const initialRedeemAdmin = deploy.initialRedeemAdmin as string;
  if (!address || !buint || !initialRedeemAdmin) {
    throw new Error("conet-BuintRedeemAirdrop.json 缺少 address / buint / initialRedeemAdmin");
  }
  if (!fs.existsSync(subsetPath)) {
    throw new Error("缺少 standard-input-SUBSET.json，请先 npm run export:buint-redeem-airdrop:conet:standard-json");
  }

  const minimalInput = JSON.parse(fs.readFileSync(subsetPath, "utf-8"));
  const standardJson = JSON.stringify(minimalInput);
  console.log("合约地址:", address);
  console.log("Standard JSON 字节:", standardJson.length);

  const coder = AbiCoder.defaultAbiCoder();
  const encoded = coder.encode(["address", "address"], [buint, initialRedeemAdmin]);
  const constructorArgsHex = encoded.startsWith("0x") ? encoded.slice(2) : encoded;
  console.log("constructor_args (no 0x):", constructorArgsHex);

  const v2Url = `${BASE_URL}/api/v2/smart-contracts/${address}/verification/via/standard-input`;
  const formData = new FormData();
  formData.append("compiler_version", COMPILER_VERSION);
  formData.append("contract_name", CONTRACT_NAME);
  formData.append("files[0]", new Blob([standardJson], { type: "application/json" }), "standard-input.json");
  formData.append("constructor_args", constructorArgsHex);
  formData.append("autodetect_constructor_args", "false");
  formData.append("license_type", "mit");

  const res = await fetch(v2Url, { method: "POST", body: formData });
  const data = (await res.json().catch(() => ({}))) as { status?: string; message?: string; result?: string };

  console.log("HTTP:", res.status, res.statusText);
  console.log("Body:", JSON.stringify(data, null, 2));

  const ok =
    res.ok &&
    (data.status === "1" ||
      (data.message?.toLowerCase().includes("verification started") ?? false) ||
      (data.message?.toLowerCase().includes("already verified") ?? false));

  if (!ok) {
    process.exit(1);
  }
  console.log("\n✅ Blockscout 已接受验证请求:", BASE_URL);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
