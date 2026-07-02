/**
 * GBToken（9 位 ERC20 GB）跨链 CREATE2 部署常量。
 *
 * 跨链同址三要素（CoNET 224422 / Base 8453 / 其他 L1 一致）：
 *   1. Nick CREATE2 factory（各链同址 0x4e59…）
 *   2. 固定 salt（GBTOKEN_CREATE2_SALT）
 *   3. 完全一致的 initCode = GBToken bytecode + abi.encode(GBTOKEN_INITIAL_ADMIN)
 *      （hardhat.config bytecodeHash=none，确保各链 bytecode 字节一致）
 *
 * 任一项变化都会改变预测地址，须重跑 predictGBTokenCreate2.ts 回填 GBTOKEN_CREATE2_PREDICTED。
 */
import { id, getAddress } from "ethers";

/** 各链部署后首个 admin（写入 constructor，须各链相同以保证 initCode 一致） */
export const GBTOKEN_INITIAL_ADMIN = getAddress(
  "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1"
);

/** CREATE2 salt：v2 = 付费池可 P2P 转账（与 BeamioBUnits 一致） */
export const GBTOKEN_CREATE2_SALT = id("beamio.gb.erc20.v2");

/** @deprecated v1（free+paid 均可 transfer） */
export const GBTOKEN_CREATE2_SALT_V1 = id("beamio.gb.erc20.v1");

/**
 * 当前 bytecode（付费池可 transfer + 双池 + EIP-2612/EIP-3009）下 CREATE2 预测同址。
 * @deprecated 直连 v2（非 UUPS）；canonical 见 GBTOKEN_UUPS_PROXY_PREDICTED
 */
export const GBTOKEN_CREATE2_PREDICTED = getAddress(
  "0xBDa7cC31E791B74a5d51f88383deBe57D2696cef"
);

export {
  GBTOKEN_UUPS_IMPL_PREDICTED,
  GBTOKEN_UUPS_PROXY_PREDICTED,
} from "./erc20UupsDeployConstants.js";

/** UUPS canonical（跨链 Nick CREATE2 proxy 同址） */
export { GBTOKEN_UUPS_PROXY_PREDICTED as GBTOKEN_CANONICAL_ADDRESS } from "./erc20UupsDeployConstants.js";

/** @deprecated v1（free+paid 均可 transfer） */
export const GBTOKEN_CREATE2_PREDICTED_V1 = getAddress(
  "0xd0A7BBD309A3E776A696c1495dEA4dcEDc9111b9"
);

/** 已知部署的链 chainId（用于 relayer/校验脚本枚举） */
export const GBTOKEN_CHAINS = {
  conet: 224422n,
  base: 8453n,
} as const;

export { NICK_CREATE2_FACTORY } from "./bunitDeployConstants.js";
