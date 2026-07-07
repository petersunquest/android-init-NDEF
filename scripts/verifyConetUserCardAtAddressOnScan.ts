/**
 * 在 CoNET Blockscout 验证指定地址的 BeamioUserCard（及未验证的 linked libraries）。
 *
 * 运行:
 *   CONET_USER_CARD_ADDRESS=0x... npx tsx scripts/verifyConetUserCardAtAddressOnScan.ts
 */

import { AbiCoder, getAddress } from "ethers";
import {
  BASESCAN_COMPILER_VERSION,
  exportBasescanStandardJsonFromRoot,
} from "./basescanStandardJsonShared.js";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const BLOCKSCOUT_API = (process.env.CONET_BLOCKSCOUT_API || "https://mainnet.conet.network/api").replace(/\/$/, "");
const BLOCKSCOUT_UI = (process.env.CONET_BLOCKSCOUT_UI || "https://mainnet.conet.network").replace(/\/$/, "");
const COMPILER = `v${process.env.CONET_SOLC_VERSION || BASESCAN_COMPILER_VERSION}`;

type Target = {
  label: string;
  address: string;
  contractName: string;
  rootSource: string;
  constructorTypes?: string[];
  constructorValues?: unknown[];
  libraryLinks?: Record<string, Record<string, string>>;
};

function loadConetLibAddresses(): Record<string, string> {
  const addr = JSON.parse(
    fs.readFileSync(path.join(root, "deployments/conet-addresses.json"), "utf-8")
  ) as Record<string, string>;
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(addr)) {
    if (!key.startsWith("beamioUserCard") || !key.endsWith("Lib")) continue;
    out[key] = getAddress(value);
  }
  return out;
}

function buildTargets(userCard: string): Target[] {
  const card = getAddress(userCard);
  const libs = loadConetLibAddresses();
  const libLinks = {
    "project/src/BeamioUserCard/BeamioUserCardAdminGatewayLib.sol": {
      BeamioUserCardAdminGatewayLib: libs.beamioUserCardAdminGatewayLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardFaucetGatewayLib.sol": {
      BeamioUserCardFaucetGatewayLib: libs.beamioUserCardFaucetGatewayLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardFormattingLib.sol": {
      BeamioUserCardFormattingLib: libs.beamioUserCardFormattingLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardGatewayMintLib.sol": {
      BeamioUserCardGatewayMintLib: libs.beamioUserCardGatewayMintLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardGovernanceLib.sol": {
      BeamioUserCardGovernanceLib: libs.beamioUserCardGovernanceLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardIssuedNftGatewayLib.sol": {
      BeamioUserCardIssuedNftGatewayLib: libs.beamioUserCardIssuedNftGatewayLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardModuleRouterLib.sol": {
      BeamioUserCardModuleRouterLib: libs.beamioUserCardModuleRouterLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardRedeemGatewayLib.sol": {
      BeamioUserCardRedeemGatewayLib: libs.beamioUserCardRedeemGatewayLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardReferrerLib.sol": {
      BeamioUserCardReferrerLib: libs.beamioUserCardReferrerLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardTransferLib.sol": {
      BeamioUserCardTransferLib: libs.beamioUserCardTransferLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardUpdateLib.sol": {
      BeamioUserCardUpdateLib: libs.beamioUserCardUpdateLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardViewsLib.sol": {
      BeamioUserCardViewsLib: libs.beamioUserCardViewsLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardMembershipGateLib.sol": {
      BeamioUserCardMembershipGateLib: libs.beamioUserCardMembershipGateLib,
    },
  };

  return [
    {
      label: "BeamioUserCardFormattingLib",
      address: libs.beamioUserCardFormattingLib,
      contractName: "BeamioUserCardFormattingLib",
      rootSource: "project/src/BeamioUserCard/BeamioUserCardFormattingLib.sol",
    },
    {
      label: "BeamioUserCardTransferLib",
      address: libs.beamioUserCardTransferLib,
      contractName: "BeamioUserCardTransferLib",
      rootSource: "project/src/BeamioUserCard/BeamioUserCardTransferLib.sol",
    },
    {
      label: "BeamioUserCard",
      address: card,
      contractName: "project/src/BeamioUserCard/BeamioUserCard.sol:BeamioUserCard",
      rootSource: "project/src/BeamioUserCard/BeamioUserCard.sol",
      libraryLinks: libLinks,
      constructorTypes: ["string", "uint8", "uint256", "address", "address", "uint8", "bool", "string"],
      constructorValues: [
        process.env.CONET_USER_CARD_URI || "https://beamio.app/api/metadata/0x",
        Number(process.env.CONET_USER_CARD_CURRENCY ?? "0"),
        BigInt(process.env.CONET_USER_CARD_PRICE_E6 ?? "1000000"),
        getAddress(process.env.CONET_USER_CARD_OWNER || "0x811FEf9B7327BF4Abdae7adF2688346456aB842C"),
        getAddress(process.env.CONET_USER_CARD_GATEWAY || "0xfA52a0CcC96C19cF4b6Ea864615F6d52BD0774FB"),
        Number(process.env.CONET_USER_CARD_UPGRADE_TYPE ?? "0"),
        process.env.CONET_USER_CARD_WHITELIST === "true",
        process.env.CONET_USER_CARD_CONTRACT_NAME || "Beamio User Card",
      ],
    },
  ];
}

async function checkVerified(address: string): Promise<boolean> {
  const res = await fetch(`${BLOCKSCOUT_API}/v2/smart-contracts/${address}`);
  if (!res.ok) return false;
  const data = (await res.json()) as {
    is_verified?: boolean;
    is_partially_verified?: boolean;
    source_code?: string | null;
  };
  return Boolean(data.is_verified || data.is_partially_verified || data.source_code);
}

async function submit(target: Target): Promise<void> {
  let standardJson: { language: string; sources: unknown; settings: Record<string, unknown> };
  let sourceCount: number;
  const buildinfoRel = process.env.CONET_VERIFY_BUILDINFO_JSON;
  if (buildinfoRel && target.label === "BeamioUserCard") {
    const buildinfoPath = path.isAbsolute(buildinfoRel) ? buildinfoRel : path.join(root, buildinfoRel);
    standardJson = JSON.parse(fs.readFileSync(buildinfoPath, "utf-8"));
    sourceCount = Object.keys((standardJson as { sources: Record<string, unknown> }).sources).length;
  } else {
    const exported = exportBasescanStandardJsonFromRoot(root, target.rootSource);
    standardJson = exported.standardJson;
    sourceCount = exported.sourceCount;
    if (target.libraryLinks) {
      standardJson.settings.libraries = target.libraryLinks;
    }
  }
  const json = JSON.stringify(standardJson);
  const ctor =
    target.constructorTypes?.length
      ? AbiCoder.defaultAbiCoder()
          .encode(target.constructorTypes, target.constructorValues ?? [])
          .slice(2)
      : "";

  console.log(`\nPOST ${target.label} @ ${target.address} (sources=${sourceCount}, json=${json.length})`);

  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${target.address}/verification/via/standard-input`;
  const form = new FormData();
  form.set("compiler_version", COMPILER);
  form.set("contract_name", target.contractName);
  form.set("autodetect_constructor_args", ctor ? "false" : "true");
  if (ctor) form.set("constructor_args", ctor);
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([json], { type: "application/json" }), "standard-input.json");

  const res = await fetch(url, { method: "POST", body: form });
  const data = (await res.json().catch(() => ({}))) as { message?: string };
  console.log(" ", JSON.stringify(data));
  if (!res.ok || !/verification started|already verified/i.test(data.message ?? "")) {
    throw new Error(`${target.label} 提交失败: ${data.message ?? res.status}`);
  }
}

async function waitVerified(address: string, label: string): Promise<boolean> {
  const max = Number(process.env.CONET_VERIFY_POLL_MAX || "90");
  for (let i = 0; i < max; i++) {
    if (await checkVerified(address)) {
      console.log(`  ✅ ${label}: ${BLOCKSCOUT_UI}/address/${address}#code`);
      return true;
    }
    await new Promise((r) => setTimeout(r, 3000));
  }
  console.warn(`  ⚠️ ${label} 轮询超时`);
  return false;
}

async function main() {
  const userCard = process.env.CONET_USER_CARD_ADDRESS;
  if (!userCard) {
    throw new Error("请设置 CONET_USER_CARD_ADDRESS");
  }

  const only = (process.env.CONET_VERIFY_ONLY || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);

  console.log("CoNET UserCard verify @", getAddress(userCard));
  console.log("API:", BLOCKSCOUT_API);
  console.log("Compiler:", COMPILER);

  for (const t of buildTargets(userCard)) {
    if (only.length > 0 && !only.includes(t.label)) {
      console.log(`⏭️ ${t.label} (CONET_VERIFY_ONLY)`);
      continue;
    }
    if (await checkVerified(t.address)) {
      console.log(`⏭️ ${t.label} 已验证`);
      continue;
    }
    await submit(t);
    await waitVerified(t.address, t.label);
  }
  console.log("\n✅ 完成");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
