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

const BLOCKSCOUT_API = (process.env.CONET_BLOCKSCOUT_API || "https://mainnet.conet.network/api").replace(/\/$/, "");
const BLOCKSCOUT_UI = (process.env.CONET_BLOCKSCOUT_UI || "https://mainnet.conet.network").replace(/\/$/, "");
const CONET_RPC = process.env.CONET_RPC_URL || "https://publicrpc.conet.network";
const COMPILER_VERSION = `v${BASESCAN_COMPILER_VERSION}`;
const SOURCE = "project/src/mainnet/ValidatorDepositRedeem.sol";
const CONTRACT_NAME = `${SOURCE}:ValidatorDepositRedeem`;

type CtorArgs = {
  initialRedeemAdmin?: string;
  gbToken?: string;
  usdcToken?: string;
  guardianNodes?: string;
  guardianAllocStartId?: string | number;
};

type DeploymentJson = CtorArgs & {
  address?: string;
  constructorArgs?: CtorArgs;
  contracts?: { ValidatorDepositRedeem?: CtorArgs & { address?: string } };
};

type ResolvedDeployment = {
  address: string;
  initialRedeemAdmin: string;
  gbToken: string;
  usdcToken: string;
  guardianNodes: string;
  guardianAllocStartId: bigint;
};

function loadDeployment(): ResolvedDeployment {
  const p = path.join(root, "deployments/conet-ValidatorDepositRedeem.json");
  if (!fs.existsSync(p)) {
    throw new Error("缺少 deployments/conet-ValidatorDepositRedeem.json，请先部署");
  }
  const data = JSON.parse(fs.readFileSync(p, "utf-8")) as DeploymentJson;
  const inner = data.contracts?.ValidatorDepositRedeem;
  const args = data.constructorArgs;
  const pick = (k: keyof CtorArgs): string | number | undefined =>
    (inner?.[k] as string | number | undefined) ??
    (args?.[k] as string | number | undefined) ??
    (data[k] as string | number | undefined);

  const address = inner?.address || data.address;
  const initialRedeemAdmin = pick("initialRedeemAdmin");
  const gbToken = pick("gbToken");
  const usdcToken = pick("usdcToken");
  const guardianNodes = pick("guardianNodes");
  const guardianAllocStartId = pick("guardianAllocStartId");

  if (!address || !initialRedeemAdmin || !gbToken || !usdcToken || !guardianNodes || guardianAllocStartId == null) {
    throw new Error(
      "部署 JSON 缺少 address / initialRedeemAdmin / gbToken / usdcToken / guardianNodes / guardianAllocStartId"
    );
  }
  return {
    address: getAddress(address),
    initialRedeemAdmin: getAddress(String(initialRedeemAdmin)),
    gbToken: getAddress(String(gbToken)),
    usdcToken: getAddress(String(usdcToken)),
    guardianNodes: getAddress(String(guardianNodes)),
    guardianAllocStartId: BigInt(guardianAllocStartId),
  };
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

async function submitVerify(
  address: string,
  ctor: Omit<ResolvedDeployment, "address">,
  standardJson: string
): Promise<void> {
  const constructorArgs = AbiCoder.defaultAbiCoder()
    .encode(
      ["address", "address", "address", "address", "uint256"],
      [ctor.initialRedeemAdmin, ctor.gbToken, ctor.usdcToken, ctor.guardianNodes, ctor.guardianAllocStartId]
    )
    .slice(2);
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
  const { address, ...ctor } = loadDeployment();
  console.log("CoNET Blockscout:", BLOCKSCOUT_UI);
  console.log("RPC:", CONET_RPC);
  console.log("address:", address);
  console.log("ctor:", JSON.stringify({ ...ctor, guardianAllocStartId: ctor.guardianAllocStartId.toString() }));

  if (!(await rpcHasCode(address))) {
    throw new Error(`链上无 code: ${address}`);
  }
  if (await checkVerified(address)) {
    console.log(`已验证: ${BLOCKSCOUT_UI}/address/${address}#code`);
    return;
  }

  const { standardJson } = exportBasescanStandardJsonFromRoot(root, SOURCE);
  await submitVerify(address, ctor, JSON.stringify(standardJson));
  await waitVerified(address);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
