/**
 * Verify BeamioAgentReferrerRegistry on CoNET Blockscout.
 *
 * Impl: v2 standard-input (FULL JSON).
 * Proxy: legacy verifysourcecode with OZ ERC1967Proxy (partial OK).
 *
 *   npm run compile
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioAgentReferrerRegistry --full
 *   npx tsx scripts/verifyBeamioAgentReferrerRegistryConet.ts
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { Interface, AbiCoder } from "ethers";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");
const API_V2 = "https://mainnet.conet.network/api/v2";
const API_LEGACY = "https://mainnet.conet.network/api";
const OUT = path.join(ROOT, "deployments", "conet-BeamioAgentReferrerRegistry.json");

async function checkVerified(addr: string): Promise<{ verified: boolean; partial: boolean; len: number }> {
  const res = await fetch(`${API_V2}/smart-contracts/${addr}`);
  if (!res.ok) return { verified: false, partial: false, len: 0 };
  const d = (await res.json()) as {
    is_verified?: boolean;
    is_partially_verified?: boolean;
    source_code?: string;
  };
  return {
    verified: Boolean(d.is_verified),
    partial: Boolean(d.is_partially_verified),
    len: (d.source_code || "").length,
  };
}

async function submitStandardInput(
  addr: string,
  jsonPath: string,
  contractName: string,
  compilerVersion: string,
): Promise<void> {
  if (!fs.existsSync(jsonPath)) {
    console.warn("missing JSON:", jsonPath);
    return;
  }
  const form = new FormData();
  form.append("compiler_version", compilerVersion);
  form.append("contract_name", contractName);
  form.append("autodetect_constructor_args", "true");
  form.append("license_type", "mit");
  const blob = new Blob([fs.readFileSync(jsonPath)], { type: "application/json" });
  form.append("files[0]", blob, path.basename(jsonPath));

  const url = `${API_V2}/smart-contracts/${addr}/verification/via/standard-input`;
  const res = await fetch(url, { method: "POST", body: form });
  const text = await res.text();
  console.log("submit impl", addr, res.status, text.slice(0, 400));
}

function buildProxyConstructorArgs(impl: string, initialAdmin: string): string {
  // OZ ERC1967Proxy constructor(address implementation, bytes _data)
  const initIface = new Interface(["function initialize(address initialAdmin)"]);
  const initData = initIface.encodeFunctionData("initialize", [initialAdmin]);
  const coder = AbiCoder.defaultAbiCoder();
  return coder.encode(["address", "bytes"], [impl, initData]).slice(2);
}

type ProxySubmitTarget = {
  jsonRel: string;
  contractName: string;
  label: string;
};

async function submitProxyLegacyOnce(
  proxy: string,
  constructorArgs: string,
  target: ProxySubmitTarget,
): Promise<boolean> {
  const proxyJson = path.join(ROOT, "deployments", target.jsonRel);
  if (!fs.existsSync(proxyJson)) {
    console.warn(`Proxy FULL JSON missing (${target.label}): ${proxyJson}`);
    return false;
  }
  const params = new URLSearchParams();
  params.append("module", "contract");
  params.append("action", "verifysourcecode");
  params.append("contractaddress", proxy);
  params.append("codeformat", "solidity-standard-json-input");
  params.append("sourceCode", fs.readFileSync(proxyJson, "utf-8"));
  params.append("contractname", target.contractName);
  params.append("compilerversion", "v0.8.35+commit.47b9dedd");
  params.append("constructorArguements", constructorArgs); // Blockscout typo field name
  params.append("licenseType", "3"); // MIT

  // Blockscout expects module/action as query params (body alone → 400).
  const url = `${API_LEGACY}?module=contract&action=verifysourcecode`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: params,
  });
  const text = await res.text();
  console.log(`submit proxy legacy (${target.label})`, proxy, res.status, text.slice(0, 400));
  return res.ok || /already verified/i.test(text);
}

async function submitProxyLegacy(
  proxy: string,
  impl: string,
  initializeArgs: { initialAdmin: string },
): Promise<void> {
  const constructorArgs = buildProxyConstructorArgs(impl, initializeArgs.initialAdmin);
  console.warn("constructorArguments (hex no 0x) len:", constructorArgs.length);

  // Prefer the deploy-time wrapper name; fall back to bytecode-identical DLE twin
  // (Blockscout already associates verified twin DLEERC1967Proxy).
  const targets: ProxySubmitTarget[] = [
    {
      label: "BeamioAgentReferrerRegistryProxy",
      jsonRel: "base-BeamioAgentReferrerRegistryProxy-standard-input-FULL.json",
      contractName:
        "project/src/mainnet/BeamioAgentReferrerRegistryProxy.sol:BeamioAgentReferrerRegistryProxy",
    },
    {
      label: "DLEERC1967Proxy",
      jsonRel: "base-DLEERC1967Proxy-standard-input-FULL.json",
      contractName: "project/src/dle/DLEERC1967Proxy.sol:DLEERC1967Proxy",
    },
  ];

  let anyOk = false;
  for (const target of targets) {
    const ok = await submitProxyLegacyOnce(proxy, constructorArgs, target);
    anyOk = anyOk || ok;
    // Also try v2 standard-input (full match possible with bytecodeHash:none).
    const jsonPath = path.join(ROOT, "deployments", target.jsonRel);
    if (fs.existsSync(jsonPath)) {
      const form = new FormData();
      form.append("compiler_version", "v0.8.35+commit.47b9dedd");
      form.append("contract_name", target.contractName);
      form.append("autodetect_constructor_args", "false");
      form.append("constructor_args", constructorArgs);
      form.append("license_type", "mit");
      form.append(
        "files[0]",
        new Blob([fs.readFileSync(jsonPath)], { type: "application/json" }),
        path.basename(jsonPath),
      );
      const v2Url = `${API_V2}/smart-contracts/${proxy}/verification/via/standard-input`;
      const v2Res = await fetch(v2Url, { method: "POST", body: form });
      const v2Text = await v2Res.text();
      console.log(`submit proxy v2 (${target.label})`, proxy, v2Res.status, v2Text.slice(0, 400));
      anyOk = anyOk || v2Res.ok || /already verified/i.test(v2Text);
    }
  }
  if (!anyOk) {
    console.warn("All proxy submit attempts failed or JSON missing — export Proxy + DLE FULL first.");
  }
}

async function main() {
  if (!fs.existsSync(OUT)) {
    throw new Error(`Missing ${OUT} — deploy first`);
  }
  const dash = JSON.parse(fs.readFileSync(OUT, "utf-8")) as {
    proxy: string;
    implementation: string;
    initializeArgs?: { initialAdmin: string };
  };
  const PROXY = dash.proxy;
  const IMPL = dash.implementation;
  const initialAdmin = dash.initializeArgs?.initialAdmin;
  if (!initialAdmin) throw new Error("initializeArgs.initialAdmin missing in deploy JSON");

  const rpc = process.env.CONET_RPC_URL || "https://rpc1.conet.network";
  const codeRes = await fetch(rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "eth_getCode",
      params: [IMPL, "latest"],
    }),
  });
  const codeJson = (await codeRes.json()) as { result?: string };
  const code = codeJson.result || "0x";
  const tail = code.slice(-24);
  console.log("impl bytecode tail:", tail);
  let compilerVersion = "v0.8.35+commit.47b9dedd";
  if (tail.includes("000821")) compilerVersion = "v0.8.33+commit.64118f21";
  console.log("compilerVersion:", compilerVersion);

  for (const [label, addr] of [
    ["AgentReferrerImpl", IMPL],
    ["AgentReferrerProxy", PROXY],
  ] as const) {
    const st = await checkVerified(addr);
    console.log(label, addr, st);
  }

  const implJson = path.join(
    ROOT,
    "deployments",
    "base-BeamioAgentReferrerRegistry-standard-input-FULL.json",
  );

  const implBefore = await checkVerified(IMPL);
  if (!(implBefore.verified || implBefore.partial || implBefore.len > 0)) {
    if (fs.existsSync(implJson)) {
      await submitStandardInput(
        IMPL,
        implJson,
        "project/src/mainnet/BeamioAgentReferrerRegistry.sol:BeamioAgentReferrerRegistry",
        compilerVersion,
      );
    } else {
      console.warn(
        "Run: node scripts/exportStandardJsonFromBuildInfo.mjs BeamioAgentReferrerRegistry --full",
      );
    }
  } else {
    console.log("impl already verified — skip submit");
  }

  const proxyBefore = await checkVerified(PROXY);
  // Require is_verified / is_partially_verified — source_code len alone can be a
  // stub (e.g. name-only DLEERC1967Proxy) and must not skip real submit.
  if (!(proxyBefore.verified || proxyBefore.partial)) {
    await submitProxyLegacy(PROXY, IMPL, { initialAdmin });
  } else {
    console.log("proxy already verified — skip submit");
  }

  const pollMax = Number(process.env.CONET_VERIFY_POLL_MAX || "90");
  let implSt = implBefore;
  let proxySt = proxyBefore;
  for (let i = 0; i < pollMax; i++) {
    await new Promise((r) => setTimeout(r, 4000));
    implSt = await checkVerified(IMPL);
    proxySt = await checkVerified(PROXY);
    console.log(`poll #${i + 1}`, { impl: implSt, proxy: proxySt });
    // Impl: verified/partial OR substantial source (real module verify).
    // Proxy: ONLY is_verified / is_partially_verified — stub twin source_len must not pass.
    const implOk = implSt.verified || implSt.partial || implSt.len > 200;
    const proxyOk = proxySt.verified || proxySt.partial;
    if (implOk && proxyOk) break;
  }

  console.log("final impl", implSt);
  console.log("final proxy", proxySt);

  const prev = JSON.parse(fs.readFileSync(OUT, "utf-8"));
  prev.verification = {
    implementation:
      implSt.verified
        ? "verified (Blockscout v2)"
        : implSt.partial
          ? "partial verified (Blockscout v2)"
          : "pending / blocked",
    proxy:
      proxySt.verified
        ? "verified (Blockscout)"
        : proxySt.partial
          ? "partial verified (Blockscout)"
          : "pending — need is_verified or is_partially_verified",
    proxyExplorer: `https://mainnet.conet.network/address/${PROXY}`,
    implExplorer: `https://mainnet.conet.network/address/${IMPL}`,
  };
  fs.writeFileSync(OUT, JSON.stringify(prev, null, 2) + "\n");

  const implOk = implSt.verified || implSt.partial || implSt.len > 200;
  const proxyOk = proxySt.verified || proxySt.partial;
  if (!implOk) {
    console.error("DEPLOYED but IMPL verification not confirmed");
    process.exitCode = 1;
  }
  if (!proxyOk) {
    console.error(
      "DEPLOYED but PROXY verification not confirmed (is_verified / is_partially_verified required)",
    );
    process.exitCode = 1;
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
