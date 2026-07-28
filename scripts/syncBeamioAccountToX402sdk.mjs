/**
 * 将 BeamioAccount / BeamioFactoryPaymasterV07 的 Hardhat 编译产物同步到 x402sdk：
 * - BeamioAccount：完整 artifact + 纯 ABI（用于本地拼 UserOp initCode / CREATE2 预测与链上 Factory._initCode 对齐）
 * - BeamioFactoryPaymasterV07：完整 artifact（MemberCard 通过 .abi 使用，与 BeamioUserCard 工厂同步方式一致）
 *
 * 源（BeamioContract 仓库）：
 *   - artifacts/src/BeamioAccount/BeamioAccount.sol/BeamioAccount.json
 *   - artifacts/src/BeamioAccount/BeamioFactoryPaymasterV07.sol/BeamioFactoryPaymasterV07.json
 * 目标（x402sdk）：
 *   - src/ABI/BeamioAccountArtifact.json
 *   - src/ABI/BeamioAccount.json
 *   - src/ABI/BeamioAAAccountFactoryPaymaster.json
 *   - scripts/API server/ABI/BeamioAccountArtifact.json
 *   - scripts/API server/ABI/BeamioAAAccountFactoryPaymaster.json
 *
 * 用法（在 BeamioContract 根目录）：
 *   npm run clean && npm run compile
 *   node scripts/syncBeamioAccountToX402sdk.mjs
 *
 * 独立 x402sdk 仓库：X402SDK_ROOT=/path/to/x402sdk node scripts/syncBeamioAccountToX402sdk.mjs
 */
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BEAMIO_CONTRACT_ROOT = path.resolve(__dirname, "..");
const X402SDK_ROOT = process.env.X402SDK_ROOT || path.join(BEAMIO_CONTRACT_ROOT, "src", "x402sdk");

const ACCOUNT_ARTIFACT_PATH = path.join(
  BEAMIO_CONTRACT_ROOT,
  "artifacts/src/BeamioAccount/BeamioAccount.sol/BeamioAccount.json"
);
const AA_FACTORY_ARTIFACT_PATH = path.join(
  BEAMIO_CONTRACT_ROOT,
  "artifacts/src/BeamioAccount/BeamioFactoryPaymasterV07.sol/BeamioFactoryPaymasterV07.json"
);

const OUT = {
  x402AccountArtifact: path.join(X402SDK_ROOT, "src/ABI/BeamioAccountArtifact.json"),
  x402AccountAbi: path.join(X402SDK_ROOT, "src/ABI/BeamioAccount.json"),
  x402AaFactoryArtifact: path.join(X402SDK_ROOT, "src/ABI/BeamioAAAccountFactoryPaymaster.json"),
  scriptsApiAccountArtifact: path.join(X402SDK_ROOT, "scripts/API server/ABI/BeamioAccountArtifact.json"),
  scriptsApiAaFactoryArtifact: path.join(X402SDK_ROOT, "scripts/API server/ABI/BeamioAAAccountFactoryPaymaster.json"),
};

for (const [label, p] of [
  ["BeamioAccount", ACCOUNT_ARTIFACT_PATH],
  ["BeamioFactoryPaymasterV07", AA_FACTORY_ARTIFACT_PATH],
]) {
  if (!fs.existsSync(p)) {
    console.error(`${label} artifact not found:`, p);
    console.error("Run: npm run compile (from BeamioContract root)");
    process.exit(1);
  }
}

const accountArtifact = JSON.parse(fs.readFileSync(ACCOUNT_ARTIFACT_PATH, "utf-8"));
const aaFactoryArtifact = JSON.parse(fs.readFileSync(AA_FACTORY_ARTIFACT_PATH, "utf-8"));

if (!Array.isArray(accountArtifact.abi) || !accountArtifact.bytecode) {
  console.error("Invalid BeamioAccount artifact: need abi[] and bytecode");
  process.exit(1);
}
if (!Array.isArray(aaFactoryArtifact.abi)) {
  console.error("Invalid BeamioFactoryPaymasterV07 artifact: need abi[]");
  process.exit(1);
}

fs.mkdirSync(path.dirname(OUT.x402AccountArtifact), { recursive: true });
fs.writeFileSync(OUT.x402AccountArtifact, JSON.stringify(accountArtifact, null, 2), "utf-8");
fs.writeFileSync(OUT.x402AccountAbi, JSON.stringify(accountArtifact.abi, null, 2), "utf-8");
fs.writeFileSync(OUT.x402AaFactoryArtifact, JSON.stringify(aaFactoryArtifact, null, 2), "utf-8");

const scriptsApiDir = path.dirname(OUT.scriptsApiAccountArtifact);
if (!fs.existsSync(scriptsApiDir)) {
  fs.mkdirSync(scriptsApiDir, { recursive: true });
}
fs.writeFileSync(OUT.scriptsApiAccountArtifact, JSON.stringify(accountArtifact, null, 2), "utf-8");
fs.writeFileSync(OUT.scriptsApiAaFactoryArtifact, JSON.stringify(aaFactoryArtifact, null, 2), "utf-8");

console.log("Synced BeamioAccount + BeamioFactoryPaymasterV07 to x402sdk:");
console.log("  -", OUT.x402AccountArtifact);
console.log("  -", OUT.x402AccountAbi);
console.log("  -", OUT.x402AaFactoryArtifact);
console.log("  -", OUT.scriptsApiAccountArtifact);
console.log("  -", OUT.scriptsApiAaFactoryArtifact);
console.log("\nMemberCard 使用 BeamioAAAccountFactoryPaymaster.json 时请解析 .abi（与 UserCard 工厂一致）。");
console.log("initCode 请使用 src/beamioAccountInitCode.ts 的 buildBeamioAccountInitCode()，与 Factory._initCode() 对齐。");
console.log("AA 工厂地址同步到 chainAddresses：npm run sync:base-aa-to-x402sdk-chain（读取 config/base-addresses.json）。");
