/**
 * CoNET Blockscout Standard JSON 验证 ValidatorDepositRedeem。
 *
 * 运行:
 *   npx tsx scripts/verifyValidatorDepositRedeemConet.ts
 */

import * as fs from "fs";
import * as path from "path";
import { AbiCoder, getAddress } from "ethers";
import { fileURLToPath } from "url";
import {
  BASESCAN_COMPILER_VERSION,
  exportBasescanStandardJsonFromRoot,
} from "./basescanStandardJsonShared.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const BLOCKSCOUT_API = (process.env.CONET_BLOCKSCOUT_API || "https://scan.conet.network/api").replace(/\/$/, "");
const BLOCKSCOUT_UI = (process.env.CONET_BLOCKSCOUT_UI || "https://scan.conet.network").replace(/\/$/, "");
const CONET_RPC = process.env.CONET_RPC_URL || "https://publicrpc.conet.network";
const COMPILER_VERSION = `v${BASESCAN_COMPILER_VERSION}`;
const SOURCE = "project/src/mainnet/ValidatorDepositRedeem.sol";
const CONTRACT_NAME = `${SOURCE}:ValidatorDepositRedeem`;

type DeploymentJson = {
  address?: string;
  initialRedeemAdmin?: string;
  constructorArgs?: { initialRedeemAdmin?: string };
  contracts?: { ValidatorDepositRedeem?: { address?: string; initialRedeemAdmin?: string } };
};

function loadDeployment(): { address: string; initialRedeemAdmin: string } {
  const p = path.join(root, "deployments/conet-ValidatorDepositRedeem.json");
  if (!fs.existsSync(p)) {
    throw new Error("缺少 deployments/conet-ValidatorDepositRedeem.json，请先部署");
  }
  const data = JSON.parse(fs.readFileSync(p, "utf-8")) as DeploymentJson;
  const address = data.contracts?.ValidatorDepositRedeem?.address || data.address;
  const initialRedeemAdmin =
    data.contracts?.ValidatorDepositRedeem?.initialRedeemAdmin ||
    data.constructorArgs?.initialRedeemAdmin ||
    data.initialRedeemAdmin;
  if (!address || !initialRedeemAdmin) {
    throw new Error("部署 JSON 缺少 address / initialRedeemAdmin");
  }
  return { address: getAddress(address), initialRedeemAdmin: getAddress(initialRedeemAdmin) };
}

async function rpcHasCode(address: string): Promise<boolean> {
  const res = await fetch(CONET_RPC, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", method: "eth_getCode", params: [address, "latest"], id: 1 }),
  });
  const data = (await res.json()) as { result?: string };
  return typeof data.result === "string" && data.result.length > 2;
}

async function checkVerified(address: string): Promise<boolean> {
  const res = await fetch(`${BLOCKSCOUT_API}/v2/smart-contracts/${address}`);
  if (!res.ok) return false;
  const data = (await res.json()) as { is_verified?: boolean; source_code?: string | null };
  return Boolean(data.is_verified || data.source_code);
}

async function submitVerify(address: string, initialRedeemAdmin: string, standardJson: string): Promise<void> {
  const constructorArgs = AbiCoder.defaultAbiCoder().encode(["address"], [initialRedeemAdmin]).slice(2);
  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${address}/verification/via/standard-input`;
  const form = new FormData();
  form.set("compiler_version", COMPILER_VERSION);
  form.set("contract_name", CONTRACT_NAME);
  form.set("autodetect_constructor_args", "false");
  form.set("constructor_args", constructorArgs);
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([standardJson], { type: "application/json" }), "standard-input.json");

  console.log("POST ValidatorDepositRedeem @", address);
  console.log("  contract_name:", CONTRACT_NAME);
  console.log("  standard-input bytes:", standardJson.length);
  console.log("  constructor_args:", constructorArgs);

  const res = await fetch(url, { method: "POST", body: form });
  const text = await res.text();
  let out: { message?: string; status?: string; result?: string };
  try {
    out = JSON.parse(text) as { message?: string; status?: string; result?: string };
  } catch {
    console.error(text.slice(0, 2000));
    throw new Error(`非 JSON HTTP ${res.status}`);
  }
  console.log(" ", JSON.stringify(out));
  if (!res.ok || !/verification started|already verified/i.test(out.message ?? "")) {
    throw new Error(`提交失败: ${out.message ?? text.slice(0, 300)}`);
  }
}

async function waitVerified(address: string): Promise<void> {
  for (let i = 0; i < 40; i++) {
    if (await checkVerified(address)) {
      console.log(`✅ 已验证: ${BLOCKSCOUT_UI}/address/${address}#code`);
      return;
    }
    await new Promise((r) => setTimeout(r, 3000));
  }
  throw new Error("验证轮询超时");
}

async function main() {
  const { address, initialRedeemAdmin } = loadDeployment();
  console.log("CoNET Blockscout:", BLOCKSCOUT_UI);
  console.log("RPC:", CONET_RPC);
  console.log("address:", address);
  console.log("initialRedeemAdmin:", initialRedeemAdmin);

  if (!(await rpcHasCode(address))) {
    throw new Error(`链上无 code: ${address}`);
  }
  if (await checkVerified(address)) {
    console.log(`已验证: ${BLOCKSCOUT_UI}/address/${address}#code`);
    return;
  }

  const { standardJson } = exportBasescanStandardJsonFromRoot(root, SOURCE);
  await submitVerify(address, initialRedeemAdmin, JSON.stringify(standardJson));
  await waitVerified(address);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
