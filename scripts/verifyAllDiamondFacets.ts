/**
 * 使用 Standard JSON Input 批量验证 BeamioIndexerDiamond 及其所有 facets
 * 运行: npx tsx scripts/verifyAllDiamondFacets.ts
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BUILD_INFO = "solc-0_8_33-a5304f0ba6b2e3b473484c91ac6aa6f3d69c9c92.json";
const COMPILER_VERSION = "v0.8.33+commit.64118f21";
const BASE_URL = "https://mainnet.conet.network";

const DIAMOND = "0x0DBDF27E71f9c89353bC5e4dC27c9C5dAe0cc612";
const DIAMOND_INITIAL_OWNER = "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1";
const DIAMOND_CUT_FACET = "0xf079eA83B3dDBaB64473df13Fa49021BA85E80C4";

// Diamond + Facet 地址（来自 CoNET mainnet loupe.facets()，脚本 getDiamondFacets.ts）
const TARGETS: { name: string; address: string; constructorArgs?: string }[] = [
  { name: "BeamioIndexerDiamond", address: DIAMOND },
  { name: "DiamondCutFacet", address: "0xf079eA83B3dDBaB64473df13Fa49021BA85E80C4" },
  { name: "DiamondLoupeFacet", address: "0x980340A8Eb23117b624b1f037b8a489F54C7b6a5" },
  { name: "OwnershipFacet", address: "0x3EBf14813932E6206c448a58A6ecFf32DC1981B2" },
  { name: "TaskFacet", address: "0x2334225a4C70EF86590B454Cd2e8f01fD23F0Da0" },
  { name: "ActionFacet", address: "0x0D6E32f683998EFc2026dE7E36e124D2A8771272" },
  { name: "CatalogFacet", address: "0x070BcBd163a3a280Ab6106bA62A079f228139379" },
  { name: "StatsFacet", address: "0x37878cDc63f1DFF1223d280198eB07819f76079c" },
  { name: "FeeStatsFacet", address: "0x51796E6413Da09179D431b0F16F47480053de7a5" },
  { name: "BeamioUserCardStatsFacet", address: "0x008b49e4d8B490c508787283b25E3A4A62d826B0" },
  { name: "AdminFacet", address: "0x729149e5B6c9F835cF8f6B3235Adee8813A17144" },
];

async function encodeDiamondConstructor(): Promise<string> {
  const { AbiCoder } = await import("ethers");
  const coder = AbiCoder.defaultAbiCoder();
  const encoded = coder.encode(
    ["address", "address"],
    [DIAMOND_INITIAL_OWNER, DIAMOND_CUT_FACET]
  );
  return encoded.startsWith("0x") ? encoded.slice(2) : encoded;
}

const DIAMOND_INDEXER_SOURCE_PREFIX = "project/src/CoNETIndexTaskdiamond/";

function getDiamondSources(fullInput: { sources: Record<string, { content: string }> }): Record<string, { content: string }> {
  const out: Record<string, { content: string }> = {};
  for (const key of Object.keys(fullInput.sources)) {
    if (key.startsWith(DIAMOND_INDEXER_SOURCE_PREFIX)) {
      out[key] = fullInput.sources[key];
    }
  }
  return out;
}

async function verifyOne(
  address: string,
  contractName: string,
  standardJson: string,
  constructorArgs: string
): Promise<{ ok: boolean; message: string }> {
  const v2Url = `${BASE_URL}/api/v2/smart-contracts/${address}/verification/via/standard-input`;
  const formData = new FormData();
  formData.append("compiler_version", COMPILER_VERSION);
  formData.append("contract_name", contractName);
  formData.append("files[0]", new Blob([standardJson], { type: "application/json" }), "standard-input.json");
  formData.append("constructor_args", constructorArgs);
  formData.append("autodetect_constructor_args", "false");
  formData.append("license_type", "mit");

  const res = await fetch(v2Url, { method: "POST", body: formData });
  const data = (await res.json().catch(() => ({}))) as { status?: string; result?: string; message?: string };

  const ok =
    res.ok &&
    (data.status === "1" ||
      data.message?.toLowerCase().includes("verification started") ||
      data.message?.toLowerCase().includes("already verified"));

  return { ok, message: data.message || JSON.stringify(data) };
}

async function main() {
  const buildInfoPath = path.join(__dirname, "..", "artifacts", "build-info", BUILD_INFO);
  if (!fs.existsSync(buildInfoPath)) {
    throw new Error("build-info 不存在，请先运行: npx hardhat compile");
  }

  const buildInfo = JSON.parse(fs.readFileSync(buildInfoPath, "utf-8"));
  const fullInput = buildInfo.input as {
    language: string;
    sources: Record<string, { content: string }>;
    settings: Record<string, unknown>;
  };

  const minimalSources = getDiamondSources(fullInput);
  const minimalInput = {
    language: fullInput.language,
    sources: minimalSources,
    settings: fullInput.settings,
  };
  const standardJson = JSON.stringify(minimalInput);
  const diamondConstructorArgs = await encodeDiamondConstructor();

  console.log("Standard JSON 大小:", standardJson.length, "bytes");
  console.log("包含 viaIR:", (minimalInput.settings as { viaIR?: boolean }).viaIR);
  console.log("待验证:", TARGETS.length, "(Diamond + facets)");
  console.log("");

  const results: { name: string; address: string; ok: boolean; message: string }[] = [];

  for (const target of TARGETS) {
    process.stdout.write(`${target.name} (${target.address})... `);
    const constructorArgs =
      target.name === "BeamioIndexerDiamond"
        ? diamondConstructorArgs
        : target.constructorArgs ?? "";
    const { ok, message } = await verifyOne(
      target.address,
      target.name,
      standardJson,
      constructorArgs
    );
    results.push({ name: target.name, address: target.address, ok, message });
    console.log(ok ? "✅" : "❌", ok ? "" : message);
  }

  console.log("\n========== 汇总 ==========");
  const okCount = results.filter((r) => r.ok).length;
  const failCount = results.filter((r) => !r.ok).length;
  for (const r of results) {
    const status = r.ok ? "✅" : "❌";
    console.log(`${status} ${r.name} ${r.address}`);
    if (!r.ok) console.log("   ", r.message);
  }
  console.log(`\n成功: ${okCount} / ${results.length}`);
  if (failCount > 0) {
    console.log("失败:", failCount);
    process.exit(1);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
