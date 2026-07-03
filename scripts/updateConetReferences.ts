/**
 * 从 deployments/conet-addresses.json 读取 CoNET 权威地址，同步到各子项目。
 *
 * 新链迁移建议顺序（依赖关系）：
 * 1. 确认 RPC / chainId：hardhat.config.ts `conet`（默认 https://mainnet-rpc1.conet.network、224422）等
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
 * 完整迁移说明见 `scripts/README-conet-contract-migration.md`
 *
 * 运行: npx tsx scripts/updateConetReferences.ts
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");

/** 替换 `const name = '0x...'`（单引号，可选 .toLowerCase()） */
function patchConstSingleQuoted(
  content: string,
  constName: string,
  addr: string | undefined,
  opts?: { toLowerCase?: boolean; toLocaleLowerCase?: boolean }
): string {
  if (!addr) return content;
  if (opts?.toLocaleLowerCase) {
    return content.replace(
      new RegExp(`(const ${constName} = ')0x[a-fA-F0-9]{40}('\\.toLocaleLowerCase\\(\\))`, "g"),
      `$1${addr}$2`
    );
  }
  if (opts?.toLowerCase) {
    return content.replace(
      new RegExp(`(const ${constName} = ')0x[a-fA-F0-9]{40}('\\.toLowerCase\\(\\))`, "g"),
      `$1${addr}$2`
    );
  }
  return content.replace(
    new RegExp(`(const ${constName} = ')0x[a-fA-F0-9]{40}(')`, "g"),
    `$1${addr}$2`
  );
}

function patchFileIfChanged(filePath: string, patcher: (content: string) => string, label: string): void {
  if (!fs.existsSync(filePath)) return;
  const prev = fs.readFileSync(filePath, "utf-8");
  const next = patcher(prev);
  if (next !== prev) {
    fs.writeFileSync(filePath, next);
    console.log(label);
  }
}

function patchConetGB1155PointerInSol(content: string, addr: string): string {
  return content.replace(/ConetGB1155\(0x[a-fA-F0-9]{40}\)/g, `ConetGB1155(${addr})`);
}

/** Dashboard contracts.ts：`CoNET_GB` / `CoNET_GBTotal` 块内 address */
function patchDashboardContractsGbEntry(content: string, entryKey: string, addr: string): string {
  return content.replace(
    new RegExp(`(${entryKey}:\\s*\\{\\s*address:\\s*['"])0x[a-fA-F0-9]{40}(['"])`, "g"),
    `$1${addr}$2`
  );
}

/** 替换 `export const Name = '0x...'`（单引号） */
function patchExportConstSingleQuoted(content: string, exportName: string, addr: string | undefined): string {
  if (!addr) return content;
  const withAddr = content.replace(
    new RegExp(`(export const ${exportName} = ')0x[a-fA-F0-9]{40}(')`, "g"),
    `$1${addr}$2`
  );
  if (withAddr !== content) return withAddr;
  return content.replace(new RegExp(`(export const ${exportName} = )''`), `$1'${addr}'`);
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
  const cardFactory = data.CARD_FACTORY as string | undefined;
  const aaFactory = data.AA_FACTORY as string | undefined;
  const userCardDefault = data.BEAMIO_USER_CARD_DEFAULT as string | undefined;
  const userCardFormattingLib = data.beamioUserCardFormattingLib as string | undefined;
  const userCardTransferLib = data.beamioUserCardTransferLib as string | undefined;
  const userCardFactoryExecuteLib = data.beamioUserCardFactoryExecuteLib as string | undefined;
  const accountRegistry = data.AccountRegistry as string | undefined;
  const guardianNodesInfoV6 = data.GuardianNodesInfoV6 as string | undefined;
  const addressPGP = data.AddressPGP as string | undefined;
  const layerMinusNodeRestartV2 = data.LayerMinusNodeRestart_V2 as string | undefined;
  const conetGB1155 = data.ConetGB1155 as string | undefined;
  const conetGBTotal = data.ConetGB_total as string | undefined;
  const conetGBUserTotal = data.ConetGB_userTotal as string | undefined;
  const epochMiningInfo = data.EpochMiningInfo as string | undefined;
  const validatorDepositRedeem = data.ValidatorDepositRedeem as string | undefined;
  const validatorDepositRedeemDeployBlock =
    typeof data.validatorDepositRedeemDeployBlock === "number"
      ? data.validatorDepositRedeemDeployBlock
      : undefined;
  const validatorDepositContractAdmin = data.validatorDepositContractAdmin as string | undefined;
  const validatorNodeRewardIndexer = data.ValidatorNodeRewardIndexer as string | undefined;
  const validatorReferrerExtension = data.ValidatorDepositRedeemReferrerExtension as string | undefined;

  let validatorDepositRedeemAdmin: string | undefined;
  const redeemDeployPath = path.join(__dirname, "..", "deployments", "conet-ValidatorDepositRedeem.json");
  if (fs.existsSync(redeemDeployPath)) {
    try {
      const rd = JSON.parse(fs.readFileSync(redeemDeployPath, "utf-8")) as {
        initialContractAdmin?: string;
        redeemAdmins?: string[];
      };
      if (!validatorDepositContractAdmin && rd.initialContractAdmin) {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        (data as any).validatorDepositContractAdmin = rd.initialContractAdmin;
      }
      if (Array.isArray(rd.redeemAdmins)) {
        const nodeAdmin = rd.redeemAdmins.find(
          (a) => a.toLowerCase() === "0xe974c5d10cc36738bc2619fc73b075504d5c6d1e"
        );
        if (nodeAdmin) validatorDepositRedeemAdmin = nodeAdmin;
      }
    } catch {
      /* ignore */
    }
  }
  const contractAdmin =
    validatorDepositContractAdmin ?? (data.validatorDepositContractAdmin as string | undefined);

  const legacyAccountRegistry = data.legacyAccountRegistry as string | undefined;
  const legacyArchiveRpc = data.legacyArchiveRpc as string | undefined;

  const rootDir = path.join(__dirname, "..");

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
  console.log("CARD_FACTORY:", cardFactory ?? "(未配置)");
  console.log("BEAMIO_USER_CARD_DEFAULT:", userCardDefault ?? "(未配置)");
  console.log("AccountRegistry:", accountRegistry ?? "(未配置)");
  console.log("GuardianNodesInfoV6:", guardianNodesInfoV6 ?? "(未配置)");
  console.log("AddressPGP:", addressPGP ?? "(未配置)");
  console.log("LayerMinusNodeRestart_V2:", layerMinusNodeRestartV2 ?? "(未配置)");
  console.log("ConetGB1155:", conetGB1155 ?? "(未配置)");
  console.log("ConetGB_total:", conetGBTotal ?? "(未配置)");
  console.log("ConetGB_userTotal:", conetGBUserTotal ?? "(未配置)");
  console.log("EpochMiningInfo:", epochMiningInfo ?? "(未配置)");

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
      path.join(rootDir, "src", "android-NDEF", "app", "src", "main", "java", "com", "beamio", "pos", "BeamioOnboardingApi.kt"),
      "BeamioOnboardingApi.kt"
    );
    patchAr(
      path.join(rootDir, "src", "android-NDEF", "app", "src", "main", "java", "com", "beamio", "pos", "BeamioWalletService.kt"),
      "BeamioWalletService.kt"
    );
    patchAr(
      path.join(rootDir, "src", "CashTrees_iOS", "iOS_NDEF", "iOS_NDEF", "BeamioConstants.swift"),
      "BeamioConstants.swift"
    );
    const conetAddressesKotlin = path.join(
      rootDir,
      "src",
      "android-NDEF",
      "app",
      "src",
      "main",
      "java",
      "com",
      "beamio",
      "pos",
      "BeamioConetAddresses.kt"
    );
    patchAr(conetAddressesKotlin, "BeamioConetAddresses.kt");
  }

  // 0b. Legacy AccountRegistry archive RPC + address (Web restoreWithUserPin)
  if (legacyAccountRegistry && legacyArchiveRpc) {
    const patchLegacyAr = (filePath: string, label: string) => {
      if (!fs.existsSync(filePath)) return;
      let c = fs.readFileSync(filePath, "utf-8");
      const prev = c;
      c = c.replace(
        /const LEGACY_ACCOUNT_REGISTRY_RPC = ['"]https?:\/\/[^'"]+['"]/,
        `const LEGACY_ACCOUNT_REGISTRY_RPC = '${legacyArchiveRpc}'`
      );
      c = c.replace(
        /const LEGACY_ACCOUNT_REGISTRY_ADDRESS = ['"]0x[a-fA-F0-9]{40}['"]/,
        `const LEGACY_ACCOUNT_REGISTRY_ADDRESS = '${legacyAccountRegistry}'`
      );
      if (c !== prev) {
        fs.writeFileSync(filePath, c);
        console.log(`[0b] 已更新 legacy AccountRegistry → ${label}`);
      }
    };
    patchLegacyAr(path.join(rootDir, "src", "SilentPassUI", "src", "services", "beamio.ts"), "SilentPassUI beamio.ts");
    patchLegacyAr(path.join(rootDir, "src", "bizSite", "src", "services", "beamio.ts"), "bizSite beamio.ts");
    patchLegacyAr(path.join(rootDir, "src", "beamio.app", "src", "services", "beamio.ts"), "beamio.app beamio.ts");
    patchLegacyAr(path.join(rootDir, "src", "Alliance", "src", "services", "beamio.ts"), "Alliance beamio.ts");
  }

  // 0c. iOS BeamioConstants + Android BeamioConetAddresses（AddressPGP + legacy registry）
  const iosConstantsPath = path.join(rootDir, "src", "CashTrees_iOS", "iOS_NDEF", "iOS_NDEF", "BeamioConstants.swift");
  if (fs.existsSync(iosConstantsPath)) {
    let c = fs.readFileSync(iosConstantsPath, "utf-8");
    const prev = c;
    if (addressPGP) {
      c = c.replace(
        /static let conetAddressPgpManager = "0x[a-fA-F0-9]{40}"/,
        `static let conetAddressPgpManager = "${addressPGP}"`
      );
    }
    if (legacyArchiveRpc) {
      c = c.replace(
        /static let legacyAccountRegistryRpcUrl = "https?:\/\/[^"]+"/,
        `static let legacyAccountRegistryRpcUrl = "${legacyArchiveRpc}"`
      );
    }
    if (legacyAccountRegistry) {
      c = c.replace(
        /static let legacyAccountRegistryAddress = "0x[a-fA-F0-9]{40}"/,
        `static let legacyAccountRegistryAddress = "${legacyAccountRegistry}"`
      );
    }
    if (c !== prev) {
      fs.writeFileSync(iosConstantsPath, c);
      console.log("[0c] 已更新 iOS BeamioConstants.swift（PGP + legacy AccountRegistry）");
    }
  }

  const androidConetAddressesPath = path.join(
    rootDir,
    "src",
    "android-NDEF",
    "app",
    "src",
    "main",
    "java",
    "com",
    "beamio",
    "pos",
    "BeamioConetAddresses.kt"
  );
  if (fs.existsSync(androidConetAddressesPath)) {
    let c = fs.readFileSync(androidConetAddressesPath, "utf-8");
    const prev = c;
    if (addressPGP) {
      c = c.replace(/const val CONET_PGP_MANAGER = "0x[a-fA-F0-9]{40}"/, `const val CONET_PGP_MANAGER = "${addressPGP}"`);
    }
    if (accountRegistry) {
      c = c.replace(/const val ACCOUNT_REGISTRY = "0x[a-fA-F0-9]{40}"/, `const val ACCOUNT_REGISTRY = "${accountRegistry}"`);
    }
    if (legacyAccountRegistry) {
      c = c.replace(
        /const val LEGACY_ACCOUNT_REGISTRY = "0x[a-fA-F0-9]{40}"/,
        `const val LEGACY_ACCOUNT_REGISTRY = "${legacyAccountRegistry}"`
      );
    }
    if (legacyArchiveRpc) {
      c = c.replace(/const val LEGACY_ARCHIVE_RPC = "https?:\/\/[^"]+"/, `const val LEGACY_ARCHIVE_RPC = "${legacyArchiveRpc}"`);
    }
    if (c !== prev) {
      fs.writeFileSync(androidConetAddressesPath, c);
      console.log("[0c] 已更新 Android BeamioConetAddresses.kt（PGP + AccountRegistry + legacy）");
    }
  }

  const androidPgpMessagingPath = path.join(
    rootDir,
    "src",
    "android-NDEF",
    "app",
    "src",
    "main",
    "java",
    "com",
    "beamio",
    "pos",
    "BeamioConetTerminalMessaging.kt"
  );
  if (addressPGP && fs.existsSync(androidPgpMessagingPath)) {
    patchFileIfChanged(
      androidPgpMessagingPath,
      (c) =>
        c.includes("0xb2aABe52f476356AE638839A786EAE425A0c1b66")
          ? c.replace(/0xb2aABe52f476356AE638839A786EAE425A0c1b66/gi, addressPGP!)
          : c,
      "[0c] 已更新 Android BeamioConetTerminalMessaging.kt 遗留 PGP 硬编码"
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
    if (buint) {
      content = patchExportConstSingleQuoted(content, "CONET_BUINT", buint);
    }
    content = patchExportConstSingleQuoted(content, "CONET_BUINT_REDEEM_AIRDROP", buintRedeem);
    content = patchExportConstSingleQuoted(content, "BEAMIO_INDEXER_DIAMOND", beamioIndexer);
    content = patchExportConstSingleQuoted(content, "MERCHANT_POS_MANAGEMENT_CONET", merchantPos);
    content = patchExportConstSingleQuoted(content, "CONET_BUSINESS_START_KET", bizKet);
    content = patchExportConstSingleQuoted(content, "CONET_BUSINESS_START_KET_REDEEM", bizKetRedeem);
    content = patchExportConstSingleQuoted(content, "CONET_CARD_FACTORY", cardFactory);
    content = patchExportConstSingleQuoted(content, "CONET_AA_FACTORY", aaFactory);
    content = patchExportConstSingleQuoted(content, "CONET_BEAMIO_USER_CARD_DEFAULT", userCardDefault);
    content = patchExportConstSingleQuoted(content, "CONET_USDC", conetUsdc);
    content = patchExportConstSingleQuoted(content, "CONET_GB1155", conetGB1155);
    content = patchExportConstSingleQuoted(content, "CONET_GB_TOTAL", conetGBTotal);
    content = patchExportConstSingleQuoted(content, "CONET_VALIDATOR_DEPOSIT_REDEEM", validatorDepositRedeem);
    if (validatorDepositRedeemDeployBlock != null) {
      content = patchNumericConst(content, "CONET_VALIDATOR_DEPOSIT_REDEEM_DEPLOY_BLOCK", validatorDepositRedeemDeployBlock);
    }
    content = patchExportConstSingleQuoted(content, "CONET_VALIDATOR_DEPOSIT_CONTRACT_ADMIN", contractAdmin);
    content = patchExportConstSingleQuoted(content, "CONET_VALIDATOR_DEPOSIT_REDEEM_ADMIN", validatorDepositRedeemAdmin);
    content = patchExportConstSingleQuoted(content, "CONET_VALIDATOR_NODE_REWARD_INDEXER", validatorNodeRewardIndexer);
    content = patchExportConstSingleQuoted(content, "CONET_VALIDATOR_REFERRER_EXTENSION", validatorReferrerExtension);
    content = patchExportConstSingleQuoted(content, "CONET_BEAMIO_USER_CARD_FORMATTING_LIB", userCardFormattingLib);
    content = patchExportConstSingleQuoted(content, "CONET_BEAMIO_USER_CARD_TRANSFER_LIB", userCardTransferLib);
    content = patchExportConstSingleQuoted(content, "CONET_BEAMIO_USER_CARD_FACTORY_EXECUTE_LIB", userCardFactoryExecuteLib);
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

  // 2. SilentPassUI chainAddresses.ts（完整 CoNET 常量，与 bizSite 对齐）
  const uiChainPath = path.join(__dirname, "..", "src", "SilentPassUI", "src", "config", "chainAddresses.ts");
  if (fs.existsSync(uiChainPath)) {
    let content = fs.readFileSync(uiChainPath, "utf-8");
    if (buint) {
      content = patchExportConstSingleQuoted(content, "CONET_BUINT", buint);
    }
    content = patchExportConstSingleQuoted(content, "BEAMIO_INDEXER_DIAMOND", beamioIndexer);
    content = patchExportConstSingleQuoted(content, "CONET_BUNIT_AIRDROP_ADDRESS", bunitAirdrop);
    content = patchExportConstSingleQuoted(content, "CONET_BUINT_REDEEM_AIRDROP", buintRedeem);
    content = patchExportConstSingleQuoted(content, "CONET_BUSINESS_START_KET", bizKet);
    content = patchExportConstSingleQuoted(content, "CONET_BUSINESS_START_KET_REDEEM", bizKetRedeem);
    content = patchExportConstSingleQuoted(content, "CONET_CARD_FACTORY", cardFactory);
    content = patchExportConstSingleQuoted(content, "CONET_AA_FACTORY", aaFactory);
    content = patchExportConstSingleQuoted(content, "CONET_BEAMIO_USER_CARD_DEFAULT", userCardDefault);
    content = patchExportConstSingleQuoted(content, "CONET_USDC", conetUsdc);
    content = patchExportConstSingleQuoted(content, "CONET_BEAMIO_USER_CARD_FORMATTING_LIB", userCardFormattingLib);
    content = patchExportConstSingleQuoted(content, "CONET_BEAMIO_USER_CARD_TRANSFER_LIB", userCardTransferLib);
    content = patchExportConstSingleQuoted(content, "BEAMIO_ORACLE_CONET", beamioOracle);
    content = patchExportConstSingleQuoted(content, "CONET_GUARDIAN_NODES_INFO_V6", guardianNodesInfoV6);
    content = patchExportConstSingleQuoted(content, "CONET_ADDRESS_PGP", addressPGP);
    content = patchExportConstSingleQuoted(content, "CONET_ACCOUNT_REGISTRY", accountRegistry);
    content = patchExportConstSingleQuoted(content, "CONET_GB1155", conetGB1155);
    content = patchExportConstSingleQuoted(content, "CONET_GB_TOTAL", conetGBTotal);
    content = patchExportConstSingleQuoted(content, "CONET_VALIDATOR_DEPOSIT_REDEEM", validatorDepositRedeem);
    content = patchExportConstSingleQuoted(content, "CONET_VALIDATOR_DEPOSIT_CONTRACT_ADMIN", contractAdmin);
    content = patchExportConstSingleQuoted(content, "CONET_VALIDATOR_DEPOSIT_REDEEM_ADMIN", validatorDepositRedeemAdmin);
    content = patchExportConstSingleQuoted(content, "CONET_VALIDATOR_NODE_REWARD_INDEXER", validatorNodeRewardIndexer);
    content = patchExportConstSingleQuoted(content, "CONET_VALIDATOR_REFERRER_EXTENSION", validatorReferrerExtension);
    content = patchNumericConst(content, "CONET_MAINNET_CHAIN_ID", chainIdNum);
    content = content.replace(/conet:\s*\{[^}]*chainId:\s*\d+/, (block) => block.replace(/chainId:\s*\d+/, `chainId: ${chainIdNum}`));
    fs.writeFileSync(uiChainPath, content);
    console.log("[2] 已更新 SilentPassUI chainAddresses.ts（完整 CoNET 常量）");
  }

  // 2b. SilentPassUI：旧 Indexer fallback → 当前 BEAMIO_INDEXER_DIAMOND
  if (beamioIndexer) {
    const silentPassSrc = path.join(rootDir, "src", "SilentPassUI", "src");
    const walkTs = (dir: string): string[] => {
      if (!fs.existsSync(dir)) return [];
      const out: string[] = [];
      for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, ent.name);
        if (ent.isDirectory()) out.push(...walkTs(p));
        else if (/\.(tsx?|jsx?)$/.test(ent.name)) out.push(p);
      }
      return out;
    };
    const legacyIndexer = "0x0DBDF27E71f9c89353bC5e4dC27c9C5dAe0cc612";
    for (const filePath of walkTs(silentPassSrc)) {
      patchFileIfChanged(
        filePath,
        (c) => (c.includes(legacyIndexer) ? c.replaceAll(legacyIndexer, beamioIndexer) : c),
        `[2b] 已更新 ${path.relative(rootDir, filePath)} Indexer fallback`
      );
    }
  }

  // 2c. SilentPassUI：检测遗留硬编码 beamioConet Cashcode 地址（应使用 utils/deprecatedBeamioConet.ts）
  const legacyBeamioConet = "0xCE8e2Cda88FfE2c99bc88D9471A3CBD08F519FEd";
  const silentPassRoot = path.join(rootDir, "src", "SilentPassUI", "src");
  if (fs.existsSync(silentPassRoot)) {
    const walkTsFiles = (dir: string): string[] => {
      const out: string[] = [];
      for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, ent.name);
        if (ent.isDirectory()) out.push(...walkTsFiles(p));
        else if (/\.(tsx?|jsx?)$/.test(ent.name) && !/deprecatedBeamioConet\.ts$/.test(ent.name)) out.push(p);
      }
      return out;
    };
    for (const filePath of walkTsFiles(silentPassRoot)) {
      const content = fs.readFileSync(filePath, "utf-8");
      if (content.includes(legacyBeamioConet)) {
        console.warn(`[2c] 仍含废弃 beamioConet 地址: ${path.relative(rootDir, filePath)}`);
      }
    }
  }

  // 3. bizSite chainAddresses.ts
  const bizChainPath = path.join(__dirname, "..", "src", "bizSite", "src", "config", "chainAddresses.ts");
  if (fs.existsSync(bizChainPath)) {
    let content = fs.readFileSync(bizChainPath, "utf-8");
    if (buint) {
      content = patchExportConstSingleQuoted(content, "CONET_BUINT", buint);
    }
    content = patchExportConstSingleQuoted(content, "BEAMIO_INDEXER_DIAMOND", beamioIndexer);
    content = patchExportConstSingleQuoted(content, "CONET_BUNIT_AIRDROP_ADDRESS", bunitAirdrop);
    content = patchExportConstSingleQuoted(content, "CONET_BUINT_REDEEM_AIRDROP", buintRedeem);
    content = patchExportConstSingleQuoted(content, "CONET_BUSINESS_START_KET", bizKet);
    content = patchExportConstSingleQuoted(content, "CONET_BUSINESS_START_KET_REDEEM", bizKetRedeem);
    content = patchExportConstSingleQuoted(content, "CONET_CARD_FACTORY", cardFactory);
    content = patchExportConstSingleQuoted(content, "CONET_AA_FACTORY", aaFactory);
    content = patchExportConstSingleQuoted(content, "CONET_BEAMIO_USER_CARD_DEFAULT", userCardDefault);
    content = patchExportConstSingleQuoted(content, "CONET_USDC", conetUsdc);
    content = patchExportConstSingleQuoted(content, "CONET_GB1155", conetGB1155);
    content = patchExportConstSingleQuoted(content, "CONET_GB_TOTAL", conetGBTotal);
    content = patchExportConstSingleQuoted(content, "CONET_VALIDATOR_DEPOSIT_REDEEM", validatorDepositRedeem);
    content = patchExportConstSingleQuoted(content, "CONET_VALIDATOR_DEPOSIT_CONTRACT_ADMIN", contractAdmin);
    content = patchExportConstSingleQuoted(content, "CONET_VALIDATOR_DEPOSIT_REDEEM_ADMIN", validatorDepositRedeemAdmin);
    content = patchExportConstSingleQuoted(content, "CONET_VALIDATOR_NODE_REWARD_INDEXER", validatorNodeRewardIndexer);
    content = patchExportConstSingleQuoted(content, "CONET_VALIDATOR_REFERRER_EXTENSION", validatorReferrerExtension);
    content = patchExportConstSingleQuoted(content, "CONET_BEAMIO_USER_CARD_FORMATTING_LIB", userCardFormattingLib);
    content = patchExportConstSingleQuoted(content, "CONET_BEAMIO_USER_CARD_TRANSFER_LIB", userCardTransferLib);
    content = patchExportConstSingleQuoted(content, "BEAMIO_ORACLE_CONET", beamioOracle);
    content = content.replace(/conet:\s*\{[^}]*chainId:\s*\d+/, (block) => block.replace(/chainId:\s*\d+/, `chainId: ${chainIdNum}`));
    fs.writeFileSync(bizChainPath, content);
    console.log("[3] 已更新 bizSite chainAddresses.ts");
  }

  // 3b. config/contract-addresses.ts（根仓 fallback 与 conet-addresses.json 对齐）
  const rootContractAddrsPath = path.join(__dirname, "..", "config", "contract-addresses.ts");
  if (fs.existsSync(rootContractAddrsPath) && buint) {
    let content = fs.readFileSync(rootContractAddrsPath, "utf-8");
    content = content.replace(
      /export const CONET_BUINT = conet\.BUint \?\? '0x[a-fA-F0-9]{40}'/,
      `export const CONET_BUINT = conet.BUint ?? '${buint}'`
    );
    content = content.replace(
      /export const CONET_BUNIT_AIRDROP_ADDRESS = conet\.BUnitAirdrop \?\? '0x[a-fA-F0-9]{40}'/,
      `export const CONET_BUNIT_AIRDROP_ADDRESS = conet.BUnitAirdrop ?? '${bunitAirdrop}'`
    );
    content = content.replace(
      /export const CONET_BUINT_REDEEM_AIRDROP = conet\.BuintRedeemAirdrop \?\? '0x[a-fA-F0-9]{40}'/,
      `export const CONET_BUINT_REDEEM_AIRDROP = conet.BuintRedeemAirdrop ?? '${buintRedeem}'`
    );
    fs.writeFileSync(rootContractAddrsPath, content);
    console.log("[3b] 已更新 config/contract-addresses.ts");
  }

  // 3c. Alliance chainAddresses.ts（独立子项目 CoNET BUint 常量）
  const allianceChainPath = path.join(__dirname, "..", "src", "Alliance", "src", "config", "chainAddresses.ts");
  if (fs.existsSync(allianceChainPath) && buint) {
    let content = fs.readFileSync(allianceChainPath, "utf-8");
    content = patchExportConstSingleQuoted(content, "CONET_BUINT", buint);
    content = patchExportConstSingleQuoted(content, "CONET_BUNIT_AIRDROP_ADDRESS", bunitAirdrop);
    content = patchExportConstSingleQuoted(content, "CONET_BUINT_REDEEM_AIRDROP", buintRedeem);
    fs.writeFileSync(allianceChainPath, content);
    console.log("[3c] 已更新 Alliance chainAddresses.ts");
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

  // 8c. CoNET-SI Guardian / AddressPGP / LayerMinus + x402sdk Guardian + API server Guardian
  if (guardianNodesInfoV6) {
    const patchGuardian = (content: string) => {
      let c = content;
      c = patchConstSingleQuoted(c, "GuardianNodeInfo_mainnet", guardianNodesInfoV6, { toLowerCase: true });
      c = patchConstSingleQuoted(c, "GuardianNodeInfo_mainnet", guardianNodesInfoV6);
      return c;
    };
    patchFileIfChanged(
      path.join(rootDir, "src", "CoNET-SI", "src", "util", "util.ts"),
      patchGuardian,
      "[8c] 已更新 CoNET-SI util.ts GuardianNodeInfo_mainnet"
    );
    patchFileIfChanged(
      path.join(rootDir, "src", "CoNET-SI", "src", "util", "localNodeCommand.ts"),
      patchGuardian,
      "[8c] 已更新 CoNET-SI localNodeCommand.ts GuardianNodeInfo_mainnet"
    );
    patchFileIfChanged(
      path.join(rootDir, "src", "x402sdk", "src", "util.ts"),
      patchGuardian,
      "[8c] 已更新 x402sdk util.ts GuardianNodeInfo_mainnet"
    );
    patchFileIfChanged(
      path.join(rootDir, "scripts", "API server", "util.ts"),
      patchGuardian,
      "[8c] 已更新 scripts/API server/util.ts GuardianNodeInfo_mainnet"
    );
    patchFileIfChanged(
      path.join(rootDir, "src", "CoNET-SI", "scripts", "check-getAllNodes.mjs"),
      (c) => patchConstSingleQuoted(c, "CONTRACT", guardianNodesInfoV6),
      "[8c] 已更新 CoNET-SI scripts/check-getAllNodes.mjs CONTRACT"
    );
    patchFileIfChanged(
      path.join(rootDir, "src", "CoNET-DL", "src", "util", "layerMinusClientV2.ts"),
      patchGuardian,
      "[8c] 已更新 CoNET-DL layerMinusClientV2.ts GuardianNodeInfo_mainnet"
    );
    patchFileIfChanged(
      path.join(rootDir, "src", "CoNET-DL", "src", "endpoint", "serverV4forMinerTotal.ts"),
      patchGuardian,
      "[8c] 已更新 CoNET-DL serverV4forMinerTotal.ts GuardianNodeInfo_mainnet"
    );
  }
  if (addressPGP) {
    patchFileIfChanged(
      path.join(rootDir, "src", "CoNET-SI", "src", "util", "util.ts"),
      (c) => patchConstSingleQuoted(c, "conet_PGP_address", addressPGP),
      "[8d] 已更新 CoNET-SI util.ts conet_PGP_address"
    );
    patchFileIfChanged(
      path.join(rootDir, "src", "x402sdk", "src", "db.ts"),
      (c) => patchConstSingleQuoted(c, "addressPGP", addressPGP),
      "[8d] 已更新 x402sdk db.ts addressPGP"
    );
  }
  if (layerMinusNodeRestartV2) {
    patchFileIfChanged(
      path.join(rootDir, "src", "CoNET-SI", "src", "util", "localNodeCommand.ts"),
      (c) => patchConstSingleQuoted(c, "nodeRestartEvent_addr", layerMinusNodeRestartV2),
      "[8e] 已更新 CoNET-SI localNodeCommand.ts nodeRestartEvent_addr"
    );
  }

  // 8f. ConetGB1155 / gbTotal / gbUserTotal（CoNET-DL 挖矿统计 + b-unit 子合约指针）
  if (conetGB1155) {
    patchFileIfChanged(
      path.join(rootDir, "src", "CoNET-DL", "src", "endpoint", "serverV4forMinerTotal.ts"),
      (c) => patchConstSingleQuoted(c, "eGB_addr", conetGB1155),
      "[8f] 已更新 CoNET-DL serverV4forMinerTotal.ts eGB_addr"
    );
    for (const rel of ["src/b-unit/gbTotal.sol", "src/b-unit/gbUserTotal.sol"]) {
      patchFileIfChanged(
        path.join(rootDir, rel),
        (c) => patchConetGB1155PointerInSol(c, conetGB1155),
        `[8f] 已更新 ${rel} ConetGB1155 指针`
      );
    }
    const dashboardContractsPath = path.join(rootDir, "src", "Dashboard", "src", "utils", "contracts.ts");
    patchFileIfChanged(
      dashboardContractsPath,
      (c) => patchDashboardContractsGbEntry(c, "CoNET_GB", conetGB1155),
      "[8f] 已更新 Dashboard contracts.ts CoNET_GB"
    );
  }
  if (conetGBTotal) {
    const dashboardContractsPath = path.join(rootDir, "src", "Dashboard", "src", "utils", "contracts.ts");
    patchFileIfChanged(
      dashboardContractsPath,
      (c) => patchDashboardContractsGbEntry(c, "CoNET_GBTotal", conetGBTotal),
      "[8f] 已更新 Dashboard contracts.ts CoNET_GBTotal"
    );
    console.log("[8f] ConetGB_total 部署地址:", conetGBTotal);
  }
  if (conetGBUserTotal) {
    console.log("[8f] ConetGB_userTotal 部署地址:", conetGBUserTotal, "（Dashboard 未引用）");
  }

  // 8g. epoch_mining_info（CoNET-DL / CoNET-SI / Dashboard 挖矿 epoch 统计）
  if (epochMiningInfo) {
    patchFileIfChanged(
      path.join(rootDir, "src", "CoNET-DL", "src", "endpoint", "serverV4forMinerTotal.ts"),
      (c) => patchConstSingleQuoted(c, "epoch_mining_info_mainnet_addr", epochMiningInfo),
      "[8g] 已更新 CoNET-DL serverV4forMinerTotal.ts epoch_mining_info_mainnet_addr"
    );
    patchFileIfChanged(
      path.join(rootDir, "src", "CoNET-SI", "src", "util", "localNodeCommand.ts"),
      (c) =>
        patchConstSingleQuoted(c, "epoch_mining_info_cancun_addr", epochMiningInfo, { toLocaleLowerCase: true }),
      "[8g] 已更新 CoNET-SI localNodeCommand.ts epoch_mining_info_cancun_addr"
    );
    patchFileIfChanged(
      path.join(rootDir, "src", "Dashboard", "src", "services", "passportPurchase.ts"),
      (c) =>
        patchConstSingleQuoted(c, "epoch_mining_info_cancun_addr", epochMiningInfo, { toLocaleLowerCase: true }),
      "[8g] 已更新 Dashboard passportPurchase.ts epoch_mining_info_cancun_addr"
    );
  }

  // 8h. CoNET-DL GuardianOracle.ts（CoNET BeamioOracle 喂价地址）
  if (beamioOracle) {
    patchFileIfChanged(
      path.join(rootDir, "src", "CoNET-DL", "src", "endpoint", "GuardianOracle.ts"),
      (c) => patchConstSingleQuoted(c, "conetBeamioOracleAddr", beamioOracle),
      "[8h] 已更新 CoNET-DL GuardianOracle.ts conetBeamioOracleAddr"
    );
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
