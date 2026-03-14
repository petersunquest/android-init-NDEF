/**
 * 使用 Standard JSON Input 批量验证 BeamioIndexerDiamond 及其所有 facets
 * 运行: npx tsx scripts/verifyAllDiamondFacets.ts
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const COMPILER_VERSION = "v0.8.33+commit.64118f21";
const BASE_URL = "https://mainnet.conet.network";

const DEPLOY_PATH = path.join(__dirname, "..", "deployments", "conet-IndexerDiamond.json");

function getTargetsFromDeployment(): { name: string; address: string; constructorArgs?: string }[] {
  if (!fs.existsSync(DEPLOY_PATH)) {
    throw new Error(`deployment 文件不存在: ${DEPLOY_PATH}`);
  }
  const deploy = JSON.parse(fs.readFileSync(DEPLOY_PATH, "utf-8"));
  const facets = deploy.facets || {};
  const diamond = deploy.diamond;
  return [
    { name: "BeamioIndexerDiamond", address: diamond },
    { name: "DiamondCutFacet", address: facets.DiamondCutFacet },
    { name: "DiamondLoupeFacet", address: facets.DiamondLoupeFacet },
    { name: "OwnershipFacet", address: facets.OwnershipFacet },
    { name: "TaskFacet", address: facets.TaskFacet },
    { name: "ActionFacet", address: facets.ActionFacet },
    { name: "CatalogFacet", address: facets.CatalogFacet },
    { name: "StatsFacet", address: facets.StatsFacet },
    { name: "FeeStatsFacet", address: facets.FeeStatsFacet },
    { name: "BeamioUserCardStatsFacet", address: facets.BeamioUserCardStatsFacet },
    { name: "AdminFacet", address: facets.AdminFacet },
  ].filter((t) => t.address);
}

async function encodeDiamondConstructor(): Promise<string> {
  const deploy = JSON.parse(fs.readFileSync(DEPLOY_PATH, "utf-8"));
  const initialOwner = deploy.deployer;
  const diamondCutFacet = deploy.facets?.DiamondCutFacet;
  if (!initialOwner || !diamondCutFacet) {
    throw new Error("deployment 文件缺少 deployer 或 DiamondCutFacet");
  }
  const { AbiCoder } = await import("ethers");
  const coder = AbiCoder.defaultAbiCoder();
  const encoded = coder.encode(
    ["address", "address"],
    [initialOwner, diamondCutFacet]
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
  const buildInfoDir = path.join(__dirname, "..", "artifacts", "build-info");
  const buildInfoFile = fs.readdirSync(buildInfoDir).find((name) => name.endsWith(".json") && !name.endsWith(".output.json"));
  if (!buildInfoFile) throw new Error("build-info 不存在，请先运行: npx hardhat compile");
  const buildInfoPath = path.join(buildInfoDir, buildInfoFile);

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
  const TARGETS = getTargetsFromDeployment();
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
