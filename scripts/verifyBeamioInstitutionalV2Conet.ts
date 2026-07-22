/**
 * Verify BeamioFactoryInstitutionalV2 + sample Account on CoNET Blockscout (v2 standard-input).
 *   npx tsx scripts/verifyBeamioInstitutionalV2Conet.ts
 */
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { AbiCoder, getAddress } from "ethers";
import {
  BEAMIO_AA_FACTORY_V2_ADMIN,
  BEAMIO_AA_FACTORY_V2_INITIAL_ACCOUNT_LIMIT,
  BEAMIO_AA_FACTORY_V2_PREDICTED,
} from "./aaInstitutionalV2DeployConstants.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");
const API = (process.env.CONET_BLOCKSCOUT_API || "https://mainnet.conet.network/api").replace(/\/$/, "");
const COMPILER = "v0.8.35+commit.47b9dedd";

type Target = {
  label: string;
  address: string;
  contractName: string;
  jsonPath: string;
  constructorArgs?: string;
};

async function isVerified(address: string): Promise<boolean> {
  const res = await fetch(`${API}/v2/smart-contracts/${address}`);
  if (!res.ok) return false;
  const d = (await res.json()) as {
    is_verified?: boolean;
    is_partially_verified?: boolean;
    source_code?: string;
  };
  return Boolean(d.is_verified || d.is_partially_verified || (d.source_code && d.source_code.length > 0));
}

async function submit(t: Target): Promise<void> {
  if (await isVerified(t.address)) {
    console.log(`skip verified ${t.label} ${t.address}`);
    return;
  }
  const form = new FormData();
  form.append("compiler_version", COMPILER);
  form.append("contract_name", t.contractName);
  form.append("license_type", "mit");
  form.append("autodetect_constructor_args", t.constructorArgs ? "false" : "true");
  if (t.constructorArgs) form.append("constructor_args", t.constructorArgs.replace(/^0x/, ""));
  const buf = fs.readFileSync(t.jsonPath);
  form.append("files[0]", new Blob([buf], { type: "application/json" }), path.basename(t.jsonPath));

  const url = `${API}/v2/smart-contracts/${t.address}/verification/via/standard-input`;
  console.log("submit", t.label, url);
  const res = await fetch(url, { method: "POST", body: form });
  const text = await res.text();
  console.log("status", res.status, text.slice(0, 400));

  for (let i = 0; i < 90; i++) {
    await new Promise((r) => setTimeout(r, 4000));
    if (await isVerified(t.address)) {
      console.log("verified", t.label);
      return;
    }
    if (i % 5 === 0) console.log("polling…", t.label, i);
  }
  throw new Error(`verify timeout ${t.label}`);
}

async function main() {
  const factoryJson = path.join(root, "deployments/base-BeamioFactoryInstitutionalV2-standard-input-FULL.json");
  const accountJson = path.join(root, "deployments/base-BeamioAccountInstitutionalV2-standard-input-FULL.json");
  if (!fs.existsSync(factoryJson) || !fs.existsSync(accountJson)) {
    throw new Error("Missing FULL JSON — run exportStandardJsonFromBuildInfo.mjs first");
  }

  const ctor = AbiCoder.defaultAbiCoder()
    .encode(
      ["uint256", "address"],
      [BEAMIO_AA_FACTORY_V2_INITIAL_ACCOUNT_LIMIT, BEAMIO_AA_FACTORY_V2_ADMIN]
    )
    .replace(/^0x/, "");

  const samplePath = path.join(root, "deployments/conet-BeamioAccountInstitutionalV2-sample.json");
  const sample = JSON.parse(fs.readFileSync(samplePath, "utf-8")) as { aa: string };
  const entryPoint = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
  const aaCtor = AbiCoder.defaultAbiCoder().encode(["address"], [entryPoint]).replace(/^0x/, "");

  await submit({
    label: "FactoryV2",
    address: getAddress(BEAMIO_AA_FACTORY_V2_PREDICTED),
    contractName: "project/src/BeamioAccount/BeamioFactoryInstitutionalV2.sol:BeamioFactoryInstitutionalV2",
    jsonPath: factoryJson,
    constructorArgs: ctor,
  });

  await submit({
    label: "AccountV2-sample",
    address: getAddress(sample.aa),
    contractName: "project/src/BeamioAccount/BeamioAccountInstitutionalV2.sol:BeamioAccountInstitutionalV2",
    jsonPath: accountJson,
    constructorArgs: aaCtor,
  });
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
