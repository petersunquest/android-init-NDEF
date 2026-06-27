/**
 * CoNET Blockscout Standard JSON 验证 ValidatorDepositRedeem 全栈。
 *
 * 运行:
 *   npx tsx scripts/verifyValidatorDepositRedeemStackConet.ts
 *   npx tsx scripts/verifyValidatorDepositRedeemStackConet.ts ValidatorDepositRedeemReferrerExtension
 *
 * Explorer 默认 https://mainnet.conet.network（可用 CONET_BLOCKSCOUT_UI / CONET_BLOCKSCOUT_API 覆盖）。
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

const STATS_LIB_SOURCE = "project/src/mainnet/ValidatorDepositRedeemStatsLib.sol";

type DeploymentJson = {
  contracts?: {
    ValidatorDepositRedeemStatsLib?: { address?: string };
    ValidatorDepositRedeem?: {
      address?: string;
      initialRedeemAdmin?: string;
      gbToken?: string;
      usdcToken?: string;
      guardianNodes?: string;
      guardianAllocStartId?: string | number;
      statsLib?: string;
    };
    ValidatorDepositRedeemReferrerExtension?: { address?: string; admin?: string };
    ValidatorDepositRedeemTransferMarket?: { address?: string; redeemHost?: string };
    ValidatorNodeRewardIndexer?: { address?: string; admin?: string; redeem?: string };
  };
  libraryLinks?: { ValidatorDepositRedeemStatsLib?: string };
  initialRedeemAdmin?: string;
  gbToken?: string;
  usdcToken?: string;
  guardianNodes?: string;
  guardianAllocStartId?: string | number;
  statsLib?: string;
  referrerExtension?: string;
  transferMarket?: string;
  rewardIndexer?: string;
  depositContract?: string;
  constructorArgs?: {
    initialRedeemAdmin?: string;
    gbToken?: string;
    usdcToken?: string;
    guardianNodes?: string;
    guardianAllocStartId?: string | number;
  };
};

type VerifyTarget = {
  key: string;
  address: string;
  rootSource: string;
  contractName: string;
  constructorTypes?: string[];
  constructorValues?: unknown[];
  libraryLinks?: Record<string, Record<string, string>>;
};

function loadDeployment(): DeploymentJson {
  const p = path.join(root, "deployments/conet-ValidatorDepositRedeem.json");
  if (!fs.existsSync(p)) throw new Error("缺少 deployments/conet-ValidatorDepositRedeem.json，请先部署");
  return JSON.parse(fs.readFileSync(p, "utf-8")) as DeploymentJson;
}

function loadTargets(data: DeploymentJson): VerifyTarget[] {
  const inner = data.contracts ?? {};
  const statsLib =
    inner.ValidatorDepositRedeemStatsLib?.address ||
    data.statsLib ||
    data.libraryLinks?.ValidatorDepositRedeemStatsLib;
  const redeem = inner.ValidatorDepositRedeem;
  const ext = inner.ValidatorDepositRedeemReferrerExtension;
  const market = inner.ValidatorDepositRedeemTransferMarket;
  const rewardIdx = inner.ValidatorNodeRewardIndexer;

  const ca = data.constructorArgs ?? {};
  const initialRedeemAdmin = redeem?.initialRedeemAdmin ?? ca.initialRedeemAdmin ?? data.initialRedeemAdmin;
  const gbToken = redeem?.gbToken ?? ca.gbToken ?? data.gbToken;
  const usdcToken = redeem?.usdcToken ?? ca.usdcToken ?? data.usdcToken;
  const guardianNodes = redeem?.guardianNodes ?? ca.guardianNodes ?? data.guardianNodes;
  const guardianAllocStartId = redeem?.guardianAllocStartId ?? ca.guardianAllocStartId ?? data.guardianAllocStartId;
  const rewardIndexerAddr =
    rewardIdx?.address ?? data.rewardIndexer ?? (data as { ValidatorNodeRewardIndexer?: string }).ValidatorNodeRewardIndexer;

  if (!statsLib || !redeem?.address || !ext?.address || !market?.address) {
    throw new Error("部署 JSON 缺少 StatsLib / Redeem / ReferrerExtension / TransferMarket 地址");
  }
  if (!initialRedeemAdmin || !gbToken || !usdcToken || !guardianNodes || guardianAllocStartId == null) {
    throw new Error("部署 JSON 缺少 Redeem constructorArgs");
  }

  const admin = getAddress(String(initialRedeemAdmin));
  const statsLibAddr = getAddress(String(statsLib));
  const redeemAddr = getAddress(redeem.address);
  const extAddr = getAddress(ext.address);
  const marketAddr = getAddress(market.address);

  const targets: VerifyTarget[] = [
    {
      key: "ValidatorDepositRedeemStatsLib",
      address: statsLibAddr,
      rootSource: STATS_LIB_SOURCE,
      contractName: `${STATS_LIB_SOURCE}:ValidatorDepositRedeemStatsLib`,
    },
    {
      key: "ValidatorDepositRedeem",
      address: redeemAddr,
      rootSource: "project/src/mainnet/ValidatorDepositRedeem.sol",
      contractName: "project/src/mainnet/ValidatorDepositRedeem.sol:ValidatorDepositRedeem",
      constructorTypes: ["address", "address", "address", "address", "uint256"],
      constructorValues: [
        admin,
        getAddress(String(gbToken)),
        getAddress(String(usdcToken)),
        getAddress(String(guardianNodes)),
        BigInt(guardianAllocStartId),
      ],
      libraryLinks: {
        [STATS_LIB_SOURCE]: {
          ValidatorDepositRedeemStatsLib: statsLibAddr,
        },
      },
    },
    {
      key: "ValidatorDepositRedeemReferrerExtension",
      address: extAddr,
      rootSource: "project/src/mainnet/ValidatorDepositRedeemReferrerExtension.sol",
      contractName: "project/src/mainnet/ValidatorDepositRedeemReferrerExtension.sol:ValidatorDepositRedeemReferrerExtension",
      constructorTypes: ["address"],
      constructorValues: [admin],
    },
    {
      key: "ValidatorDepositRedeemTransferMarket",
      address: marketAddr,
      rootSource: "project/src/mainnet/ValidatorDepositRedeemTransferMarket.sol",
      contractName: "project/src/mainnet/ValidatorDepositRedeemTransferMarket.sol:ValidatorDepositRedeemTransferMarket",
      constructorTypes: ["address"],
      constructorValues: [redeemAddr],
    },
    ...(rewardIndexerAddr
      ? (() => {
          try {
            const idxAddr = getAddress(String(rewardIndexerAddr));
            return [
              {
                key: "ValidatorNodeRewardIndexer",
                address: idxAddr,
                rootSource: "project/src/mainnet/ValidatorNodeRewardIndexer.sol",
                contractName: "project/src/mainnet/ValidatorNodeRewardIndexer.sol:ValidatorNodeRewardIndexer",
                constructorTypes: ["address", "address"],
                constructorValues: [admin, redeemAddr],
              } satisfies VerifyTarget,
            ];
          } catch {
            return [];
          }
        })()
      : []),
  ];
  return targets;
}

function constructorArgsHex(target: VerifyTarget): string {
  if (!target.constructorTypes?.length) return "";
  return AbiCoder.defaultAbiCoder()
    .encode(target.constructorTypes, target.constructorValues ?? [])
    .slice(2);
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

async function submitVerify(target: VerifyTarget, standardJson: string): Promise<void> {
  const ctor = constructorArgsHex(target);
  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${target.address}/verification/via/standard-input`;
  const form = new FormData();
  form.set("compiler_version", COMPILER_VERSION);
  form.set("contract_name", target.contractName);
  form.set("autodetect_constructor_args", "false");
  form.set("constructor_args", ctor);
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([standardJson], { type: "application/json" }), "standard-input.json");

  console.log(`\nPOST ${target.key} @ ${target.address}`);
  console.log("  contract_name:", target.contractName);
  console.log("  standard-input bytes:", standardJson.length);
  if (ctor) console.log("  constructor_args:", ctor);

  const res = await fetch(url, { method: "POST", body: form });
  const text = await res.text();
  let out: { message?: string };
  try {
    out = JSON.parse(text) as { message?: string };
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
  throw new Error(`验证轮询超时: ${address}`);
}

async function verifyTarget(target: VerifyTarget): Promise<void> {
  if (!(await rpcHasCode(target.address))) {
    throw new Error(`链上无 code: ${target.address}`);
  }
  if (await checkVerified(target.address)) {
    console.log(`已验证: ${BLOCKSCOUT_UI}/address/${target.address}#code`);
    return;
  }

  const { standardJson } = exportBasescanStandardJsonFromRoot(root, target.rootSource);
  if (target.libraryLinks) {
    (standardJson.settings as Record<string, unknown>).libraries = target.libraryLinks;
  }
  await submitVerify(target, JSON.stringify(standardJson));
  await waitVerified(target.address);
}

async function main() {
  const filter = process.argv[2]?.trim();
  const data = loadDeployment();
  let targets = loadTargets(data);
  if (filter) {
    targets = targets.filter((t) => t.key === filter);
    if (!targets.length) throw new Error(`未知合约 key: ${filter}`);
  }

  console.log("CoNET Blockscout:", BLOCKSCOUT_UI);
  console.log("RPC:", CONET_RPC);
  for (const t of targets) {
    await verifyTarget(t);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
