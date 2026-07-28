#!/usr/bin/env node
/**
 * CI / 本地：检查 BeamioUserCard 部署体积，避免逼近 EIP-170（24576 bytes runtime）。
 *   node scripts/checkBeamioUserCardBytecodeSize.mjs
 */
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const artifactPath = path.join(
  __dirname,
  "..",
  "artifacts/src/BeamioUserCard/BeamioUserCard.sol/BeamioUserCard.json"
);
const EIP170 = 24576;
const WARN = 24000;

const a = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
const deployed = (a.deployedBytecode || "").replace(/^0x/, "");
const init = (a.bytecode || "").replace(/^0x/, "");
const runBytes = deployed.length / 2;
const initBytes = init.length / 2;

console.log(`BeamioUserCard runtime (deployed) bytes: ${runBytes} (EIP-170 limit ${EIP170})`);
console.log(`BeamioUserCard creation bytecode bytes: ${initBytes} (EIP-3860 initcode limit 49152)`);

if (runBytes > EIP170) {
  console.error("FATAL: runtime bytecode exceeds EIP-170 contract size limit.");
  process.exit(1);
}
if (runBytes > WARN) {
  console.warn(`WARN: runtime within ${EIP170 - runBytes} bytes of EIP-170; consider optimizer / splitting.`);
}
if (initBytes > 49152) {
  console.error("FATAL: creation bytecode exceeds EIP-3860 initcode limit.");
  process.exit(1);
}
