/**
 * ConetTreasury 跨链 CREATE2 部署常量（initCode + salt 各链一致 → 同址）。
 */
import { id, getAddress } from "ethers";

/** CoNET 224422 权威 RPC（重 genesis 后；Hardhat `--network conet` 默认） */
export const CONET_MAINNET_RPC_URL = "https://mainnet-rpc1.conet.network";

/** 各链部署后首个 miner（须写入 constructor，保证 CREATE2 initCode 一致） */
export const CONET_TREASURY_INITIAL_MINER = getAddress(
  "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1"
);

/** CREATE2 salt：固定字符串，各链相同 */
export const CONET_TREASURY_CREATE2_SALT = id("beamio.conet_treasury.v1");

/**
 * 当前 bytecode 下 CREATE2 预测同址（各链 Nick factory + 同 initCode）。
 * bytecode 变更后须重跑 predictCrossChainAssets.ts / predictConetTreasuryCreate2Address.ts。
 */
export const CONET_TREASURY_CREATE2_PREDICTED = getAddress(
  "0xc6e615431BC0c0c65E09e04877a08AC927A30242"
);

/** Peer 桥模块 CREATE2 salt（constructor 固定链接 Treasury 同址） */
export const CONET_TREASURY_PEER_CREATE2_SALT = id("beamio.conet_treasury_peer.v1");

/** 须与 CONET_TREASURY_CREATE2_PREDICTED 一致后再预测；见 predictCrossChainAssets.ts */
export const CONET_TREASURY_PEER_CREATE2_PREDICTED = getAddress(
  "0xCF26c1686aC5E01e37B72017E575511C42cad29f"
);

/** Wrapped wCNET CREATE2（minter = Treasury 同址） */
export const WRAPPED_CONET_CREATE2_PREDICTED = getAddress(
  "0x429FBf063d6deAbA08a8Ca2566c9b6797ea9Eb39"
);

/** 与 conetTreasury.sol BUINT_PEER_TOKEN 一致（跨链 voteMintFromPeerDeposit 键） */
export const BUINT_PEER_TOKEN = getAddress(
  "0x000000000000000000000000000000000000B001"
);

/** 与 conetTreasury.sol GB_PEER_TOKEN 一致 */
export const GB_PEER_TOKEN = getAddress(
  "0x000000000000000000000000000000000000B002"
);

/** Base 主网 chainId（peer deposit → CoNET wrapped mint） */
export const BASE_MAINNET_CHAIN_ID = 8453n;

/** CoNET 主网 chainId（Wrapped CoNET peer 键） */
export const CONET_CHAIN_ID = 224422n;

/** peer 注册表：CoNET 原生资产占位（与 conetTreasury.sol NATIVE_PEER_TOKEN 一致） */
export const NATIVE_PEER_TOKEN = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";

/** Wrapped CoNET 元数据（各链 registerWrappedConetNative 默认） */
export const WRAPPED_CONET_NAME = "Wrapped CoNET";
export const WRAPPED_CONET_SYMBOL = "wCNET";
export const WRAPPED_CONET_DECIMALS = 18;

/** Base 主网 USDC */
export const BASE_USDC = getAddress("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913");

/** 与 conetTreasury.sol `_wrappedSalt` 前缀一致 */
export const WRAPPED_ERC20_SALT_PREFIX = "beamio.wrapped.erc20.v1";

export { NICK_CREATE2_FACTORY } from "./bunitDeployConstants.js";
