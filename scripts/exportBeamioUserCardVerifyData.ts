/**
 * 导出 BeamioUserCard 相关合约在 BaseScan 手动验证所需的 Standard JSON Input 与元数据。
 *
 * 运行:
 *   npx tsx scripts/exportBeamioUserCardVerifyData.ts
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { AbiCoder } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ROOT_DIR = path.join(__dirname, "..");
const FACTORY_DEPLOY_PATH = path.join(__dirname, "..", "deployments", "base-UserCardFactory.json");
const MODULE_DEPLOY_PATH = path.join(__dirname, "..", "deployments", "base-UserCardModules.json");
const OUT_DIR = path.join(__dirname, "..", "deployments");

const COMPILER_VERSION = "0.8.33+commit.64118f21";
const USER_CARD_SOURCE = "project/src/BeamioUserCard/BeamioUserCard.sol";
const FACTORY_SOURCE = "project/src/BeamioUserCard/BeamioUserCardFactoryPaymasterV07.sol";
const MODULE_SOURCES = [
  "project/src/BeamioUserCard/RedeemModule.sol",
  "project/src/BeamioUserCard/IssuedNftModule.sol",
  "project/src/BeamioUserCard/FaucetModule.sol",
  "project/src/BeamioUserCard/GovernanceModule.sol",
  "project/src/BeamioUserCard/MembershipStatsModule.sol",
  "project/src/BeamioUserCard/AdminStatsQueryModule.sol",
];

const VERIFICATION_CARD = {
  address: "0x5f981BBC6c3fD6b30C6ed8068977e86b502D7d42",
  uri: "https://beamio.app/api/metadata/0x",
  currency: 0,
  priceInCurrencyE6: 1_000_000n,
  owner: "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1",
};

type SourceMap = Record<string, { content: string }>;

function toPosix(p: string): string {
  return p.split(path.sep).join(path.posix.sep);
}

function toAbsolutePath(sourceKey: string): string {
  if (!sourceKey.startsWith("project/")) {
    throw new Error(`sourceKey 必须以 project/ 开头，收到: ${sourceKey}`);
  }
  return path.resolve(ROOT_DIR, sourceKey.slice("project/".length));
}

function toSourceKey(absPath: string): string {
  return `project/${toPosix(path.relative(ROOT_DIR, absPath))}`;
}

function resolveImport(absImporter: string, importPath: string): string {
  if (importPath.startsWith("./") || importPath.startsWith("../")) {
    return path.resolve(path.dirname(absImporter), importPath);
  }
  const fromRoot = path.resolve(ROOT_DIR, importPath);
  if (fs.existsSync(fromRoot)) return fromRoot;
  throw new Error(`无法解析 import: ${importPath} (from ${absImporter})`);
}

function collectSources(absEntry: string, sources: SourceMap, visited = new Set<string>()): void {
  const absPath = path.resolve(absEntry);
  if (visited.has(absPath)) return;
  if (!fs.existsSync(absPath)) {
    throw new Error(`源码不存在: ${absPath}`);
  }

  visited.add(absPath);
  const content = fs.readFileSync(absPath, "utf-8");
  sources[toSourceKey(absPath)] = { content };

  const importRegex = /^\s*import\s+(?:[^'"]+from\s+)?["']([^"']+)["'];/gm;
  for (const match of content.matchAll(importRegex)) {
    collectSources(resolveImport(absPath, match[1]), sources, visited);
  }
}

function buildSettings() {
  return {
    metadata: {
      bytecodeHash: "none",
    },
    debug: {
      revertStrings: "strip",
    },
    optimizer: {
      enabled: true,
      runs: 0,
    },
    viaIR: true,
    evmVersion: "cancun",
    remappings: [],
    outputSelection: {
      "*": {
        "": ["ast"],
        "*": ["abi", "evm.bytecode", "evm.deployedBytecode", "evm.methodIdentifiers", "metadata"],
      },
    },
  };
}

function hexArgs(types: string[], values: unknown[]): string {
  return AbiCoder.defaultAbiCoder().encode(types, values).slice(2);
}

function main() {
  if (!fs.existsSync(FACTORY_DEPLOY_PATH)) {
    throw new Error(`未找到部署文件: ${FACTORY_DEPLOY_PATH}`);
  }
  if (!fs.existsSync(MODULE_DEPLOY_PATH)) {
    throw new Error(`未找到部署文件: ${MODULE_DEPLOY_PATH}`);
  }

  const sources: SourceMap = {};
  collectSources(toAbsolutePath(USER_CARD_SOURCE), sources);
  const sourceCount = Object.keys(sources).length;
  const settings = buildSettings();

  const standardJsonInput = {
    language: "Solidity",
    sources,
    settings,
  };

  const factoryDeploy = JSON.parse(fs.readFileSync(FACTORY_DEPLOY_PATH, "utf-8"));
  const moduleDeploy = JSON.parse(fs.readFileSync(MODULE_DEPLOY_PATH, "utf-8"));
  const factory = factoryDeploy.contracts.beamioUserCardFactoryPaymaster;
  const modules = moduleDeploy.modules;

  const factoryConstructorArgs = hexArgs(
    ["address", "address", "address", "address", "address", "address"],
    [factory.usdc, factory.redeemModule, factory.quoteHelper, factory.deployer, factory.aaFactory, factory.owner]
  );

  const verificationCardConstructorArgs = hexArgs(
    ["string", "uint8", "uint256", "address", "address"],
    [
      VERIFICATION_CARD.uri,
      VERIFICATION_CARD.currency,
      VERIFICATION_CARD.priceInCurrencyE6,
      VERIFICATION_CARD.owner,
      factory.address,
    ]
  );

  const standardJsonPath = path.join(OUT_DIR, "base-UserCard-standard-input.json");
  const metaPath = path.join(OUT_DIR, "base-UserCard-verify-meta.txt");
  const factoryArgsPath = path.join(OUT_DIR, "base-UserCardFactory-constructor-args.txt");
  const verifyCardArgsPath = path.join(OUT_DIR, "base-VerificationUserCard-constructor-args.txt");

  fs.writeFileSync(standardJsonPath, JSON.stringify(standardJsonInput, null, 2), "utf-8");
  fs.writeFileSync(factoryArgsPath, factoryConstructorArgs + "\n", "utf-8");
  fs.writeFileSync(verifyCardArgsPath, verificationCardConstructorArgs + "\n", "utf-8");

  const lines = [
    `Compiler Version: ${COMPILER_VERSION}`,
    `Optimization: Enabled`,
    `Runs: 0`,
    `viaIR: ${String(settings.viaIR)}`,
    `Source Count: ${sourceCount}`,
    ``,
    `Standard JSON: ${standardJsonPath}`,
    ``,
    `Factory`,
    `  Address: ${factory.address}`,
    `  Contract Name: ${FACTORY_SOURCE}:BeamioUserCardFactoryPaymasterV07`,
    `  Constructor Arguments Hex: ${factoryConstructorArgs}`,
    ``,
    `Modules`,
    `  Address: ${modules.redeemModule}`,
    `  Contract Name: project/src/BeamioUserCard/RedeemModule.sol:BeamioUserCardRedeemModuleVNext`,
    `  Constructor Arguments Hex: (empty)`,
    ``,
    `  Address: ${modules.issuedNftModule}`,
    `  Contract Name: project/src/BeamioUserCard/IssuedNftModule.sol:BeamioUserCardIssuedNftModuleV1`,
    `  Constructor Arguments Hex: (empty)`,
    ``,
    `  Address: ${modules.faucetModule}`,
    `  Contract Name: project/src/BeamioUserCard/FaucetModule.sol:BeamioUserCardFaucetModuleV1`,
    `  Constructor Arguments Hex: (empty)`,
    ``,
    `  Address: ${modules.governanceModule}`,
    `  Contract Name: project/src/BeamioUserCard/GovernanceModule.sol:BeamioUserCardGovernanceModuleV1`,
    `  Constructor Arguments Hex: (empty)`,
    ``,
    `  Address: ${modules.membershipStatsModule}`,
    `  Contract Name: project/src/BeamioUserCard/MembershipStatsModule.sol:BeamioUserCardMembershipStatsModuleV1`,
    `  Constructor Arguments Hex: (empty)`,
    ``,
    `  Address: ${modules.adminStatsQueryModule}`,
    `  Contract Name: project/src/BeamioUserCard/AdminStatsQueryModule.sol:BeamioUserCardAdminStatsQueryModuleV1`,
    `  Constructor Arguments Hex: (empty)`,
    ``,
    `Verification Card (optional)`,
    `  Address: ${VERIFICATION_CARD.address}`,
    `  Contract Name: ${USER_CARD_SOURCE}:BeamioUserCard`,
    `  Constructor Arguments Hex: ${verificationCardConstructorArgs}`,
    `  Constructor Values:`,
    `    uri=${VERIFICATION_CARD.uri}`,
    `    currency=${VERIFICATION_CARD.currency}`,
    `    priceInCurrencyE6=${VERIFICATION_CARD.priceInCurrencyE6.toString()}`,
    `    owner=${VERIFICATION_CARD.owner}`,
    `    gateway=${factory.address}`,
    ``,
    `Relevant Source Files`,
    `  ${FACTORY_SOURCE}`,
    `  ${USER_CARD_SOURCE}`,
    ...MODULE_SOURCES.map((item) => `  ${item}`),
    ``,
    `Manual BaseScan Tips`,
    `  Code Format: solidity-standard-json-input`,
    `  Use the exact Contract Name above`,
    `  Paste constructor args hex without 0x if BaseScan asks for it separately`,
  ];
  fs.writeFileSync(metaPath, lines.join("\n") + "\n", "utf-8");

  console.log("已导出:");
  console.log("  Standard JSON:", standardJsonPath);
  console.log("  验证元数据:", metaPath);
  console.log("  Factory constructor args:", factoryArgsPath);
  console.log("  Verification card constructor args:", verifyCardArgsPath);
  console.log("\nCompiler Version:", COMPILER_VERSION);
}

main();
