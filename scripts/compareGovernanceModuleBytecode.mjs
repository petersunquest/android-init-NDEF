#!/usr/bin/env node
/**
 * 对比链上 GovernanceModule 与本地 artifact 的 deployedBytecode
 */
import { execSync } from "child_process";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ADDR = "0xc12fBEA081aD0B8143747Fd2935CE6b61734eB41";
const RPC = "https://1rpc.io/base";

const chainHex = execSync(`cast code ${ADDR} --rpc-url ${RPC}`, { encoding: "utf-8" }).trim();
const artifact = JSON.parse(
  fs.readFileSync(path.join(__dirname, "../artifacts/src/BeamioUserCard/GovernanceModule.sol/BeamioUserCardGovernanceModuleV1.json"), "utf-8")
);
const localHex = artifact.deployedBytecode?.object ?? artifact.deployedBytecode;

console.log("Chain bytecode length:", chainHex.length);
console.log("Local bytecode length:", localHex.length);

if (chainHex === localHex) {
  console.log("\n✅ Bytecode MATCH - 链上与本地完全一致");
  process.exit(0);
}

console.log("\n❌ Bytecode MISMATCH");

// Metadata is typically at the end: a164736f6c6343 + version + 00 82 + hash (32 bytes)
// Find first diff
const chainBuf = Buffer.from(chainHex.slice(2), "hex");
const localBuf = Buffer.from(localHex.slice(2), "hex");
const minLen = Math.min(chainBuf.length, localBuf.length);

for (let i = 0; i < minLen; i++) {
  if (chainBuf[i] !== localBuf[i]) {
    console.log(`First diff at byte ${i} (0x${i.toString(16)}): chain=0x${chainBuf[i].toString(16).padStart(2,"0")} local=0x${localBuf[i].toString(16).padStart(2,"0")}`);
    console.log("Context (chain):", chainHex.slice(2 + i * 2 - 20, 2 + i * 2 + 40));
    console.log("Context (local):", localHex.slice(2 + i * 2 - 20, 2 + i * 2 + 40));
    break;
  }
}

// Check metadata suffix (Solidity appends CBOR metadata)
const SOLC_META = "a164736f6c6343"; // 0xa1 0x64 "solc" 0x43
const chainMetaIdx = chainHex.indexOf(SOLC_META);
const localMetaIdx = localHex.indexOf(SOLC_META);
console.log("\nMetadata (solc) prefix:");
console.log("  Chain at:", chainMetaIdx >= 0 ? chainMetaIdx / 2 : "not found");
console.log("  Local at:", localMetaIdx >= 0 ? localMetaIdx / 2 : "not found");

if (chainMetaIdx >= 0 && localMetaIdx >= 0) {
  const chainMeta = chainHex.slice(chainMetaIdx);
  const localMeta = localHex.slice(localMetaIdx);
  console.log("  Chain metadata suffix (last 80 chars):", chainMeta.slice(-80));
  console.log("  Local metadata suffix (last 80 chars):", localMeta.slice(-80));
}
