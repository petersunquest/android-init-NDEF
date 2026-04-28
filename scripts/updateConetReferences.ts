/**
 * 从 deployments/conet-addresses.json 读取 CoNET 权威地址，同步到各子项目。
 *
 * 新链迁移建议顺序（依赖关系）：
 * 1. 确认 RPC / chainId：hardhat.config.ts `conet`（默认 https://rpc1.conet.network、224422）等
 * 2. BUint + BUnitAirdrop：`deployBUintAndAirdropToConet.ts` 或 `deployBUnitAirdropToConet.ts`
 * 3. ConetTreasury + conetUSDC：`deployConetTreasuryToConet.ts` / `createConetTreasuryUSDC.ts`
 * 4. BeamioIndexerDiamond：`deployCoNETIndexerDiamond.ts`，并完成 AdminFacet 与 BUnitAirdrop 登记
 * 5. BeamioOracle + QuoteHelper：`deployConetOracleAndQuoteHelper.ts`
 * 5b. AccountRegistry（社交注册表）：`deployAccountRegistryToConet.ts --network conet`
 * 6. AA + UserCard 全栈：`deployFullAccountAndUserCard.ts --network conet`（需 EXISTING_ORACLE / QUOTE_HELPER 或 conet-FullSystem）
 * 7. BuintRedeemAirdrop、BusinessStartKet(+Redeem)、MerchantPOS、Guardian/AddressPGP 等专项脚本
 * 8. 验证：`verifyConetDeployments.ts`、`verifyCoNETIndexerDiamond.ts`、各合约 verify 脚本
 * 9. 本脚本：`npx tsx scripts/updateConetReferences.ts`
 *
 * 运行: npx tsx scripts/updateConetReferences.ts
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");

/** 替换 `export const Name = '0x...'`（单引号） */
function patchExportConstSingleQuoted(content: string, exportName: string, addr: string | undefined): string {
  if (!addr) return content;
  return content.replace(
    new RegExp(`(export const ${exportName} = ')0x[a-fA-F0-9]{40}(')`, "g"),
    `$1${addr}$2`
  );
}

function patchNumericConst(content: string, exportName: string, n: number): string {
  return content.replace(new RegExp(`(export const ${exportName} = )\\d+`), `$1${n}`);
}

function main() {
  if (!fs.existsSync(ADDRESSES_PATH)) {
    throw new Error("未找到 deployments/conet-addresses.json");
  }
  const data = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
  const bunitAirdrop = data.BUnitAirdrop || data.contracts?.BUnitAirdrop?.address;
  const conetTreasury = data.ConetTreasury || data.contracts?.ConetTreasury?.address;
  const conetUsdc = data.conetUsdc;
  const chainIdNum = Number(data.chainId ?? 224422);
  const buint = data.BUint as string | undefined;
  const beamioIndexer = data.BeamioIndexerDiamond as string | undefined;
  const merchantPos = data.MerchantPOSManagement as string | undefined;
  const beamioOracle = data.beamioOracle as string | undefined;
  const buintRedeem = data.BuintRedeemAirdrop as string | undefined;
  const bizKet = data.BusinessStartKet as string | undefined;
  const bizKetRedeem = data.BusinessStartKetRedeem as string | undefined;
  const accountRegistry = data.AccountRegistry as string | undefined;

  if (!bunitAirdrop) {
    throw new Error("conet-addresses.json 缺少 BUnitAirdrop 地址");
  }

  console.log("=".repeat(60));
  console.log("从 conet-addresses.json 同步 CoNET 引用");
  console.log("=".repeat(60));
  console.log("chainId:", chainIdNum);
  console.log("BUint:", buint ?? "(未配置)");
  console.log("BUnitAirdrop:", bunitAirdrop);
  console.log("BeamioIndexerDiamond:", beamioIndexer ?? "(未配置)");
  console.log("MerchantPOSManagement:", merchantPos ?? "(未配置)");
  console.log("beamioOracle:", beamioOracle ?? "(未配置)");
  console.log("ConetTreasury:", conetTreasury ?? "(未配置)");
  console.log("conetUsdc:", conetUsdc ?? "(未配置)");
  console.log("AccountRegistry:", accountRegistry ?? "(未配置)");

  // 0. CoNET AccountRegistry（见 deployments/conet-FullAccountAndUserCard.json 的 contracts.accountRegistry，非 beamioAccount）
  if (accountRegistry) {
    const ar = accountRegistry;
    const patchAr = (filePath: string, label: string) => {
      if (!fs.existsSync(filePath)) return;
      let c = fs.readFileSync(filePath, "utf-8");
      const prev = c;
      c = c.replace(/const beamioConetAccountRegistry = '0x[a-fA-F0-9]{40}'/, `const beamioConetAccountRegistry = '${ar}'`);
      c = c.replace(/const ACCOUNT_REGISTRY = "0x[a-fA-F0-9]{40}"/, `const ACCOUNT_REGISTRY = "${ar}"`);
      c = c.replace(
        /(const beamioAccountContract = \{\s*address: ')0x[a-fA-F0-9]{40}(',)/,
        `$1${ar}$2`
      );
      c = c.replace(/static let beamioAccountRegistryAddress = "0x[a-fA-F0-9]{40}"/, `static let beamioAccountRegistryAddress = "${ar}"`);
      c = c.replace(/private const val ACCOUNT_REGISTRY = "0x[a-fA-F0-9]{40}"/g, `private const val ACCOUNT_REGISTRY = "${ar}"`);
      if (c !== prev) {
        fs.writeFileSync(filePath, c);
        console.log(`[0] 已更新 AccountRegistry → ${label}`);
      }
    };
    const rootDir = path.join(__dirname, "..");
    patchAr(path.join(rootDir, "src", "x402sdk", "src", "util.ts"), "x402sdk util.ts");
    patchAr(path.join(rootDir, "src", "x402sdk", "src", "db.ts"), "x402sdk db.ts");
    patchAr(path.join(rootDir, "scripts", "API server", "util.ts"), "API server util.ts");
    patchAr(path.join(rootDir, "scripts", "addBeamioAdminsToAccountRegistry.ts"), "addBeamioAdminsToAccountRegistry.ts");
    patchAr(path.join(rootDir, "scripts", "diagnoseRestoreWithUserPin.ts"), "diagnoseRestoreWithUserPin.ts");
    patchAr(path.join(rootDir, "scripts", "fetchCardOwnerBeamioTag.ts"), "fetchCardOwnerBeamioTag.ts");
    patchAr(path.join(rootDir, "src", "bizSite", "src", "services", "beamio.ts"), "bizSite beamio.ts");
    patchAr(path.join(rootDir, "src", "SilentPassUI", "src", "services", "beamio.ts"), "SilentPassUI beamio.ts");
    patchAr(path.join(rootDir, "src", "beamio.app", "src", "services", "beamio.ts"), "beamio.app beamio.ts");
    patchAr(path.join(rootDir, "src", "Alliance", "src", "services", "beamio.ts"), "Alliance beamio.ts");
    patchAr(
      path.join(rootDir, "src", "android-NDEF", "app", "src", "main", "java", "com", "beamio", "android_ntag", "BeamioOnboardingApi.kt"),
      "BeamioOnboardingApi.kt"
    );
    patchAr(
      path.join(rootDir, "src", "android-NDEF", "app", "src", "main", "java", "com", "beamio", "android_ntag", "BeamioWalletService.kt"),
      "BeamioWalletService.kt"
    );
    patchAr(
      path.join(rootDir, "src", "CashTrees_iOS", "iOS_NDEF", "iOS_NDEF", "BeamioConstants.swift"),
      "BeamioConstants.swift"
    );
  }

  // 1. x402sdk chainAddresses.ts
  const sdkChainPath = path.join(__dirname, "..", "src", "x402sdk", "src", "chainAddresses.ts");
  if (fs.existsSync(sdkChainPath)) {
    let content = fs.readFileSync(sdkChainPath, "utf-8");
    content = content.replace(
      /CONET_BUNIT_AIRDROP_ADDRESS\s*=\s*['"](0x[a-fA-F0-9]{40})['"]/,
      `CONET_BUNIT_AIRDROP_ADDRESS = '${bunitAirdrop}'`
    );
    content = patchExportConstSingleQuoted(content, "CONET_BUINT_REDEEM_AIRDROP", buintRedeem);
    content = patchExportConstSingleQuoted(content, "BEAMIO_INDEXER_DIAMOND", beamioIndexer);
    content = patchExportConstSingleQuoted(content, "MERCHANT_POS_MANAGEMENT_CONET", merchantPos);
    content = patchExportConstSingleQuoted(content, "CONET_BUSINESS_START_KET", bizKet);
    content = patchExportConstSingleQuoted(content, "CONET_BUSINESS_START_KET_REDEEM", bizKetRedeem);
    content = patchNumericConst(content, "CONET_MAINNET_CHAIN_ID", chainIdNum);
    fs.writeFileSync(sdkChainPath, content);
    console.log("[1] 已更新 src/x402sdk/src/chainAddresses.ts");
  }

  // 1b. x402sdk MemberCard.ts（BUint 代币与 EIP-712 chainId）
  const memberCardPath = path.join(__dirname, "..", "src", "x402sdk", "src", "MemberCard.ts");
  if (fs.existsSync(memberCardPath) && buint) {
    let content = fs.readFileSync(memberCardPath, "utf-8");
    content = content.replace(
      /const CONET_BUINT_TOKEN_ADDRESS = '0x[a-fA-F0-9]{40}'/,
      `const CONET_BUINT_TOKEN_ADDRESS = '${buint}'`
    );
    content = content.replace(/chainId:\s*\d+,\s*\n\s*verifyingContract:\s*CONET_BUNIT_AIRDROP_ADDRESS/, `chainId: ${chainIdNum},\n\tverifyingContract: CONET_BUNIT_AIRDROP_ADDRESS`);
    fs.writeFileSync(memberCardPath, content);
    console.log("[1b] 已更新 src/x402sdk/src/MemberCard.ts（BUint / claim domain chainId）");
  }

  // 2. SilentPassUI chainAddresses
  const uiChainPath = path.join(__dirname, "..", "src", "SilentPassUI", "src", "config", "chainAddresses.ts");
  if (fs.existsSync(uiChainPath)) {
    let content = fs.readFileSync(uiChainPath, "utf-8");
    if (buint) {
      content = patchExportConstSingleQuoted(content, "CONET_BUINT", buint);
    }
    content = patchExportConstSingleQuoted(content, "BEAMIO_INDEXER_DIAMOND", beamioIndexer);
    content = content.replace(/conet:\s*\{[^}]*chainId:\s*\d+/, (block) => block.replace(/chainId:\s*\d+/, `chainId: ${chainIdNum}`));
    fs.writeFileSync(uiChainPath, content);
    console.log("[2] 已更新 SilentPassUI chainAddresses.ts");
  }

  // 3. bizSite chainAddresses.ts
  const bizChainPath = path.join(__dirname, "..", "src", "bizSite", "src", "config", "chainAddresses.ts");
  if (fs.existsSync(bizChainPath)) {
    let content = fs.readFileSync(bizChainPath, "utf-8");
    content = patchExportConstSingleQuoted(content, "BEAMIO_INDEXER_DIAMOND", beamioIndexer);
    content = patchExportConstSingleQuoted(content, "CONET_BUINT_REDEEM_AIRDROP", buintRedeem);
    content = patchExportConstSingleQuoted(content, "CONET_BUSINESS_START_KET", bizKet);
    content = patchExportConstSingleQuoted(content, "CONET_BUSINESS_START_KET_REDEEM", bizKetRedeem);
    content = patchExportConstSingleQuoted(content, "BEAMIO_ORACLE_CONET", beamioOracle);
    content = content.replace(/conet:\s*\{[^}]*chainId:\s*\d+/, (block) => block.replace(/chainId:\s*\d+/, `chainId: ${chainIdNum}`));
    fs.writeFileSync(bizChainPath, content);
    console.log("[3] 已更新 bizSite chainAddresses.ts");
  }

  // 4. src/b-unit/readme.md
  const readmePath = path.join(__dirname, "..", "src", "b-unit", "readme.md");
  if (fs.existsSync(readmePath)) {
    let content = fs.readFileSync(readmePath, "utf-8");
    content = content.replace(
      /\|\s*\*\*ConetTreasury\*\*\s*\|\s*`0x[a-fA-F0-9]{40}`/g,
      conetTreasury ? `| **ConetTreasury** | \`${conetTreasury}\`` : (m: string) => m
    );
    content = content.replace(
      /\|\s*\*\*BUnitAirdrop\*\*\s*\|\s*`0x[a-fA-F0-9]{40}`/g,
      `| **BUnitAirdrop** | \`${bunitAirdrop}\``
    );
    fs.writeFileSync(readmePath, content);
    console.log("[4] 已更新 src/b-unit/readme.md");
  }

  // 5. .cursor/rules/conet-deployments.mdc
  const rulesPath = path.join(__dirname, "..", ".cursor", "rules", "conet-deployments.mdc");
  if (fs.existsSync(rulesPath)) {
    let content = fs.readFileSync(rulesPath, "utf-8");
    if (buint) {
      content = content.replace(
        /\*\*当前 BUint \(CoNET mainnet\)\*\*:\s*`0x[a-fA-F0-9]{40}`/,
        `**当前 BUint (CoNET mainnet)**: \`${buint}\``
      );
    }
    content = content.replace(
      /- \*\*当前 BUnitAirdrop \(CoNET mainnet\)[^`]*`0x[a-fA-F0-9]{40}`/,
      `- **当前 BUnitAirdrop (CoNET mainnet)**: \`${bunitAirdrop}\``
    );
    if (conetTreasury) {
      content = content.replace(
        /ConetTreasury[^`]*`0x[a-fA-F0-9]{40}`/g,
        (m) => (m.includes("ConetTreasury") ? m.replace(/0x[a-fA-F0-9]{40}/, conetTreasury) : m)
      );
    }
    fs.writeFileSync(rulesPath, content);
    console.log("[5] 已更新 .cursor/rules/conet-deployments.mdc");
  }

  // 6. SilentPassUI beamio.ts
  const silentPassBeamioPath = path.join(__dirname, "..", "src", "SilentPassUI", "src", "services", "beamio.ts");
  if (fs.existsSync(silentPassBeamioPath)) {
    let content = fs.readFileSync(silentPassBeamioPath, "utf-8");
    content = content.replace(
      /CONET_BUNIT_AIRDROP_ADDRESS\s*=\s*['"](0x[a-fA-F0-9]{40})['"]/,
      `CONET_BUNIT_AIRDROP_ADDRESS = '${bunitAirdrop}'`
    );
    fs.writeFileSync(silentPassBeamioPath, content);
    console.log("[6] 已更新 SilentPassUI beamio.ts");
  }

  // 7. bizSite beamio.ts
  const bizSiteBeamioPath = path.join(__dirname, "..", "src", "bizSite", "src", "services", "beamio.ts");
  if (fs.existsSync(bizSiteBeamioPath)) {
    let content = fs.readFileSync(bizSiteBeamioPath, "utf-8");
    content = content.replace(
      /CONET_BUNIT_AIRDROP_ADDRESS\s*=\s*['"](0x[a-fA-F0-9]{40})['"]/,
      `CONET_BUNIT_AIRDROP_ADDRESS = '${bunitAirdrop}'`
    );
    content = content.replace(/const CONET_CHAIN_ID = \d+/, `const CONET_CHAIN_ID = ${chainIdNum}`);
    fs.writeFileSync(bizSiteBeamioPath, content);
    console.log("[7] 已更新 bizSite beamio.ts");
  }

  // 8. CoNET-SI server.ts CONET_TREASURY_ADDRESS 默认值 + env.example
  if (conetTreasury) {
    const conetSiServerPath = path.join(__dirname, "..", "src", "CoNET-SI", "src", "endpoint", "server.ts");
    if (fs.existsSync(conetSiServerPath)) {
      let content = fs.readFileSync(conetSiServerPath, "utf-8");
      content = content.replace(
        /CONET_TREASURY_ADDRESS\s*\|\|\s*['"](0x[a-fA-F0-9]{40})['"]/,
        `CONET_TREASURY_ADDRESS || '${conetTreasury}'`
      );
      fs.writeFileSync(conetSiServerPath, content);
      console.log("[8] 已更新 CoNET-SI server.ts CONET_TREASURY_ADDRESS");
    }
    const envExamplePath = path.join(__dirname, "..", "src", "CoNET-SI", "env.example");
    if (fs.existsSync(envExamplePath)) {
      let content = fs.readFileSync(envExamplePath, "utf-8");
      content = content.replace(
        /CONET_TREASURY_ADDRESS=(0x[a-fA-F0-9]{40})/,
        `CONET_TREASURY_ADDRESS=${conetTreasury}`
      );
      fs.writeFileSync(envExamplePath, content);
      console.log("[8b] 已更新 CoNET-SI env.example CONET_TREASURY_ADDRESS");
    }
  }

  // 9. BUnitAirdrop 回退地址（scripts）
  for (const scriptRel of [
    "scripts/consumeBUnitFromUser.ts",
    "scripts/checkPurchaseAndVoteStatus.ts",
    "scripts/checkIndexerBurnRecord.ts",
    "scripts/checkBUnitAirdropBUintAdmin.ts",
    "scripts/queryBUnitAirdropIndexer.ts",
    "scripts/checkBUnitBalance.ts",
  ]) {
    const fullPath = path.join(__dirname, "..", scriptRel);
    if (fs.existsSync(fullPath)) {
      let content = fs.readFileSync(fullPath, "utf-8");
      const prev = content;
      content = content.replace(/return d\.BUnitAirdrop \|\| "0x[a-fA-F0-9]{40}"/, `return d.BUnitAirdrop || "${bunitAirdrop}"`);
      content = content.replace(/const BUNIT_AIRDROP = "0x[a-fA-F0-9]{40}"/, `const BUNIT_AIRDROP = "${bunitAirdrop}"`);
      if (content !== prev) {
        fs.writeFileSync(fullPath, content);
        console.log(`[9] 已更新 ${scriptRel}`);
      }
    }
  }
  const treasuryJsonPath = path.join(__dirname, "..", "deployments", "conet-ConetTreasury.json");
  if (fs.existsSync(treasuryJsonPath)) {
    let content = fs.readFileSync(treasuryJsonPath, "utf-8");
    content = content.replace(/"bUnitAirdrop":\s*"0x[a-fA-F0-9]{40}"/, `"bUnitAirdrop": "${bunitAirdrop}"`);
    fs.writeFileSync(treasuryJsonPath, content);
    console.log("[9b] 已更新 deployments/conet-ConetTreasury.json bUnitAirdrop");
  }

  // 10. deployCardFactoryOnlyWithSettleAdmin / redeployCardFactoryAndUpdateConfig
  for (const scriptName of ["deployCardFactoryOnlyWithSettleAdmin.ts", "redeployCardFactoryAndUpdateConfig.ts"]) {
    const scriptPath = path.join(__dirname, "..", "scripts", scriptName);
    if (fs.existsSync(scriptPath)) {
      let content = fs.readFileSync(scriptPath, "utf-8");
      if (content.includes("CONET_BUNIT_AIRDROP")) {
        content = content.replace(
          /CONET_BUNIT_AIRDROP\s*=\s*["'](0x[a-fA-F0-9]{40})["']/,
          `CONET_BUNIT_AIRDROP = "${bunitAirdrop}"`
        );
        fs.writeFileSync(scriptPath, content);
        console.log(`[10] 已更新 scripts/${scriptName}`);
      }
    }
  }

  // 11. conetUsdc 引用更新
  if (conetUsdc) {
    if (fs.existsSync(rulesPath)) {
      let content = fs.readFileSync(rulesPath, "utf-8");
      content = content.replace(
        /(conet-USDC[^`]*)`0x[a-fA-F0-9]{40}`([^\n]*)/,
        `$1\`${conetUsdc}\`$2`
      );
      fs.writeFileSync(rulesPath, content);
      console.log("[11a] 已更新 .cursor/rules/conet-deployments.mdc conet-USDC");
    }
    if (fs.existsSync(readmePath)) {
      let content = fs.readFileSync(readmePath, "utf-8");
      content = content.replace(
        /\|\s*\*\*USDC\*\*\s*\(FactoryERC20\)\s*\|\s*`0x[a-fA-F0-9]{40}`/,
        `| **USDC** (FactoryERC20) | \`${conetUsdc}\``
      );
      fs.writeFileSync(readmePath, content);
      console.log("[11b] 已更新 src/b-unit/readme.md USDC");
    }
    const consumePath = path.join(__dirname, "..", "scripts", "consumeBUnitFromUser.ts");
    if (fs.existsSync(consumePath)) {
      let content = fs.readFileSync(consumePath, "utf-8");
      content = content.replace(
        /return d\.conetUsdc \|\| "0x[a-fA-F0-9]{40}"/,
        `return d.conetUsdc || "${conetUsdc}"`
      );
      content = content.replace(
        /return "0x[a-fA-F0-9]{40}";(\s*\})/,
        `return "${conetUsdc}";$1`
      );
      fs.writeFileSync(consumePath, content);
      console.log("[11c] 已更新 scripts/consumeBUnitFromUser.ts");
    }
    const linkPath = path.join(__dirname, "..", "scripts", "linkRedeployedBUnitAirdropToConet.ts");
    if (fs.existsSync(linkPath)) {
      let content = fs.readFileSync(linkPath, "utf-8");
      content = content.replace(
        /(CONET_USDC = fs\.existsSync\(ADDRESSES_PATH\)\s*\?\s*JSON\.parse\(fs\.readFileSync\(ADDRESSES_PATH,\s*"utf-8"\)\)\.conetUsdc\s*:\s*)"0x[a-fA-F0-9]{40}"/,
        `$1"${conetUsdc}"`
      );
      fs.writeFileSync(linkPath, content);
      console.log("[11d] 已更新 scripts/linkRedeployedBUnitAirdropToConet.ts");
    }
    const apiUtilPath = path.join(__dirname, "..", "scripts", "API server", "util.ts");
    if (fs.existsSync(apiUtilPath)) {
      let content = fs.readFileSync(apiUtilPath, "utf-8");
      if (content.includes("CONET_USDC_ADDRESS")) {
        content = content.replace(
          /CONET_USDC_ADDRESS\s*=\s*['"](0x[a-fA-F0-9]{40})['"]/,
          `CONET_USDC_ADDRESS = '${conetUsdc}'`
        );
        fs.writeFileSync(apiUtilPath, content);
        console.log("[11e] 已更新 scripts/API server/util.ts CONET_USDC_ADDRESS");
      }
    }
  }

  console.log("\n✅ 引用更新完成");
  console.log("若 chainId 或 RPC 变更，请手工检查 hardhat.config.ts 与各应用中硬编码的 CoNET RPC URL。");
}

main();
