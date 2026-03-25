/**
 * 将 BeamioContract 本地 Hardhat 编译产物同步到 x402sdk 项目：
 * - BeamioUserCard（artifact + ABI）
 * - BeamioUserCardFactoryPaymasterV07（artifact）
 *
 * 源：
 *   - artifacts/src/BeamioUserCard/BeamioUserCard.sol/BeamioUserCard.json
 *   - artifacts/src/BeamioUserCard/BeamioUserCardFactoryPaymasterV07.sol/BeamioUserCardFactoryPaymasterV07.json
 * 目标（x402sdk 项目内，相对其根目录）：
 *   - src/ABI/BeamioUserCardArtifact.json
 *   - src/ABI/BeamioUserCard.json
 *   - src/ABI/BeamioUserCardFactoryPaymaster.json
 *   - scripts/API server/ABI/BeamioUserCardArtifact.json
 *   - scripts/API server/ABI/BeamioUserCardFactoryPaymaster.json
 *
 * 用法（在 BeamioContract 仓库根目录）：
 *   1. 先编译：npm run compile
 *   2. 同步到 本仓库内 x402sdk：node scripts/syncBeamioUserCardToX402sdk.mjs
 *   3. 若 x402sdk 为独立仓库，指定根目录：X402SDK_ROOT=/path/to/x402sdk node scripts/syncBeamioUserCardToX402sdk.mjs
 *   4. 若需远程/服务器使用最新 ABI：在 x402sdk 仓库内 add/commit 上述文件并 push，否则 pull 端只会看到你提交过的 .ts 变更，不会包含 ABI 更新。
 */
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BEAMIO_CONTRACT_ROOT = path.resolve(__dirname, "..");

// x402sdk 项目根目录：未设置时为本仓库内的 src/x402sdk（与 BeamioContract 同目录）；设置后为独立仓库路径
const X402SDK_ROOT = process.env.X402SDK_ROOT || path.join(BEAMIO_CONTRACT_ROOT, "src", "x402sdk");

const USER_CARD_ARTIFACT_PATH = path.join(
  BEAMIO_CONTRACT_ROOT,
  "artifacts/src/BeamioUserCard/BeamioUserCard.sol/BeamioUserCard.json"
);
const FACTORY_ARTIFACT_PATH = path.join(
  BEAMIO_CONTRACT_ROOT,
  "artifacts/src/BeamioUserCard/BeamioUserCardFactoryPaymasterV07.sol/BeamioUserCardFactoryPaymasterV07.json"
);

const OUT = {
  x402Artifact: path.join(X402SDK_ROOT, "src/ABI/BeamioUserCardArtifact.json"),
  x402Abi: path.join(X402SDK_ROOT, "src/ABI/BeamioUserCard.json"),
  x402FactoryArtifact: path.join(X402SDK_ROOT, "src/ABI/BeamioUserCardFactoryPaymaster.json"),
  scriptsApiArtifact: path.join(X402SDK_ROOT, "scripts/API server/ABI/BeamioUserCardArtifact.json"),
  scriptsApiFactoryArtifact: path.join(X402SDK_ROOT, "scripts/API server/ABI/BeamioUserCardFactoryPaymaster.json"),
};

if (!fs.existsSync(USER_CARD_ARTIFACT_PATH)) {
  console.error("BeamioUserCard artifact not found:", USER_CARD_ARTIFACT_PATH);
  console.error("Run: npx hardhat compile");
  process.exit(1);
}

if (!fs.existsSync(FACTORY_ARTIFACT_PATH)) {
  console.error("BeamioUserCardFactoryPaymasterV07 artifact not found:", FACTORY_ARTIFACT_PATH);
  console.error("Run: npx hardhat compile");
  process.exit(1);
}

const userCardArtifact = JSON.parse(fs.readFileSync(USER_CARD_ARTIFACT_PATH, "utf-8"));
const factoryArtifact = JSON.parse(fs.readFileSync(FACTORY_ARTIFACT_PATH, "utf-8"));
if (!Array.isArray(userCardArtifact.abi)) {
  console.error("Invalid BeamioUserCard artifact: missing or non-array abi");
  process.exit(1);
}
if (!Array.isArray(factoryArtifact.abi)) {
  console.error("Invalid BeamioUserCardFactoryPaymasterV07 artifact: missing or non-array abi");
  process.exit(1);
}

// 完整 artifact 写入 x402sdk 与 scripts/API server
fs.mkdirSync(path.dirname(OUT.x402Artifact), { recursive: true });
fs.writeFileSync(OUT.x402Artifact, JSON.stringify(userCardArtifact, null, 2), "utf-8");
fs.writeFileSync(OUT.x402FactoryArtifact, JSON.stringify(factoryArtifact, null, 2), "utf-8");

const scriptsApiDir = path.dirname(OUT.scriptsApiArtifact);
if (!fs.existsSync(scriptsApiDir)) {
  fs.mkdirSync(scriptsApiDir, { recursive: true });
}
fs.writeFileSync(OUT.scriptsApiArtifact, JSON.stringify(userCardArtifact, null, 2), "utf-8");
fs.writeFileSync(OUT.scriptsApiFactoryArtifact, JSON.stringify(factoryArtifact, null, 2), "utf-8");

// 仅 ABI 数组写入 BeamioUserCard.json（MemberCard 等直接 import 用作 ABI）
fs.writeFileSync(OUT.x402Abi, JSON.stringify(userCardArtifact.abi, null, 2), "utf-8");

// Base 上已部署的工厂 bytecode 可能与当前 Hardhat 本地 artifact 的 jump table 不一致（例如旧 artifact 含已移除的 selector）。
// scripts/API server/ABI 中的副本已与链上 0xfB5E… 对齐；同步后用其覆盖 Factory 完整 JSON，避免独立仓库/x402sdk 仍带过时 bytecode 误导调试。
const API_SERVER_FACTORY = path.join(
  BEAMIO_CONTRACT_ROOT,
  "scripts/API server/ABI/BeamioUserCardFactoryPaymaster.json"
);
if (fs.existsSync(API_SERVER_FACTORY)) {
  const canonical = fs.readFileSync(API_SERVER_FACTORY, "utf-8");
  fs.writeFileSync(OUT.x402FactoryArtifact, canonical, "utf-8");
  fs.writeFileSync(OUT.scriptsApiFactoryArtifact, canonical, "utf-8");
  console.log("Factory Paymaster: overwrote with chain-canonical JSON from scripts/API server/ABI/");
}

console.log("Synced BeamioUserCard + BeamioUserCardFactoryPaymasterV07 from Hardhat build to:");
console.log("  -", OUT.x402Artifact);
console.log("  -", OUT.x402Abi);
console.log("  -", OUT.x402FactoryArtifact);
console.log("  -", OUT.scriptsApiArtifact);
console.log("  -", OUT.scriptsApiFactoryArtifact);
console.log("\n若需推送到远程（服务器 git pull 能拿到 ABI）：在 x402sdk 目录执行");
console.log("  git add src/ABI/BeamioUserCardArtifact.json src/ABI/BeamioUserCard.json src/ABI/BeamioUserCardFactoryPaymaster.json 'scripts/API server/ABI/BeamioUserCardArtifact.json' 'scripts/API server/ABI/BeamioUserCardFactoryPaymaster.json'");
console.log("  git commit -m 'chore: sync BeamioUserCard and factory ABI/artifact' && git push");
