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

/** CREATE2 salt：固定字符串，各链相同 */
export const GBTOKEN_CREATE2_SALT = id("beamio.gb.erc20.v1");

/**
 * 当前 bytecode 下 CREATE2 预测同址（各链 Nick factory + 同 initCode）。
 * bytecode / salt / initialAdmin 变更后须重跑 predictGBTokenCreate2.ts 回填。
 *   initCodeHash: 0x42e127096f2fcd3d01ff61da2d988e63b9389d3d95c5fc01b29a1a23f17547fc
 */
export const GBTOKEN_CREATE2_PREDICTED = getAddress(
  "0xbeEbE03943b55e67373796ddc7314fC76f5b5911"
);

/** 已知部署的链 chainId（用于 relayer/校验脚本枚举） */
export const GBTOKEN_CHAINS = {
  conet: 224422n,
  base: 8453n,
} as const;

export { NICK_CREATE2_FACTORY } from "./bunitDeployConstants.js";
