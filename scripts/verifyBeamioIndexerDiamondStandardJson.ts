/**
 * 使用 Standard JSON Input（含 via-IR）验证 BeamioIndexerDiamond
 * Blockscout 的 flattened 方式不支持 via-IR，Standard JSON 支持
 *
 * 运行: npx tsx scripts/verifyBeamioIndexerDiamondStandardJson.ts
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DEPLOY_PATH = path.join(__dirname, "..", "deployments", "conet-IndexerDiamond.json");

// BeamioIndexerDiamond 及其直接/间接依赖（仅此 5 个文件）
const DIAMOND_SOURCES = [
  "project/src/CoNETIndexTaskdiamond/BeamioIndexerDiamond.sol",
  "project/src/CoNETIndexTaskdiamond/libraries/LibDiamond.sol",
  "project/src/CoNETIndexTaskdiamond/interfaces/IDiamondCut.sol",
  "project/src/CoNETIndexTaskdiamond/interfaces/IDiamondLoupe.sol",
  "project/src/CoNETIndexTaskdiamond/interfaces/IERC165.sol",
];

async function main() {
  const deploy = JSON.parse(fs.readFileSync(DEPLOY_PATH, "utf-8"));
  const diamond = deploy.diamond;
  const initialOwner = deploy.deployer;
  const diamondCutFacet = deploy.facets?.DiamondCutFacet;
  if (!diamond || !initialOwner || !diamondCutFacet) {
    throw new Error("deployment 文件缺少 diamond / deployer / DiamondCutFacet");
  }

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

  // 最小 input：只保留 Diamond 需要的 5 个源文件
  const minimalSources: Record<string, { content: string }> = {};
  for (const key of DIAMOND_SOURCES) {
    if (fullInput.sources[key]) {
      minimalSources[key] = fullInput.sources[key];
    }
  }

  const minimalInput = {
    language: fullInput.language,
    sources: minimalSources,
    settings: fullInput.settings,
  };

  const { AbiCoder } = await import("ethers");
  const coder = AbiCoder.defaultAbiCoder();
  const encoded = coder.encode(
    ["address", "address"],
    [initialOwner, diamondCutFacet]
  );
  const constructorArgs =
    encoded.startsWith("0x") ? encoded.slice(2) : encoded;

  const standardJson = JSON.stringify(minimalInput);
  console.log("Standard JSON 大小:", standardJson.length, "bytes");
  console.log("包含 viaIR:", (minimalInput.settings as { viaIR?: boolean }).viaIR);

  // 使用 v2 standard-input API（支持 Standard JSON，含 via-IR）
  const v2Url = `https://mainnet.conet.network/api/v2/smart-contracts/${diamond}/verification/via/standard-input`;
  const formData = new FormData();
  formData.append("compiler_version", "v0.8.33+commit.64118f21");
  formData.append("contract_name", "BeamioIndexerDiamond");
  // files[0] = Standard JSON 输入（含 viaIR 的 compiler input）
  formData.append("files[0]", new Blob([standardJson], { type: "application/json" }), "standard-input.json");
  formData.append("constructor_args", constructorArgs);
  formData.append("autodetect_constructor_args", "false");
  formData.append("license_type", "mit");

  console.log("POST", v2Url);

  const res = await fetch(v2Url, {
    method: "POST",
    body: formData,
  });
  const data = (await res.json().catch(() => ({}))) as { status?: string; result?: string; message?: string };
  const ok =
    res.ok &&
    (data.status === "1" ||
      data.message?.toLowerCase().includes("verification started") ||
      data.message?.toLowerCase().includes("already verified"));
  if (ok) {
    console.log("\n✅ 验证已提交！");
    if (data.result) console.log("GUID:", data.result);
    console.log("查看: https://mainnet.conet.network/address/" + DIAMOND);
  } else {
    console.error("验证失败:", res.status, JSON.stringify(data, null, 2));
    process.exit(1);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
