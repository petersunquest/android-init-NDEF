/**
 * ConetTreasury 跨链 CREATE2 部署常量（initCode + salt 各链一致 → 同址）。
 */
import { id, getAddress } from "ethers";

/** 各链部署后首个 miner（须写入 constructor，保证 CREATE2 initCode 一致） */
export const CONET_TREASURY_INITIAL_MINER = getAddress(
  "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1"
);

/** CREATE2 salt：固定字符串，各链相同 */
export const CONET_TREASURY_CREATE2_SALT = id("beamio.conet_treasury.v1");

/** Base 主网 chainId（peer deposit → CoNET wrapped mint） */
export const BASE_MAINNET_CHAIN_ID = 8453n;

/** Base 主网 USDC */
export const BASE_USDC = getAddress("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913");

/** 与 conetTreasury.sol `_wrappedSalt` 前缀一致 */
export const WRAPPED_ERC20_SALT_PREFIX = "beamio.wrapped.erc20.v1";

export { NICK_CREATE2_FACTORY } from "./bunitDeployConstants.js";
