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
 *
 * 2026-06-29（统一国库）：在 ERC20 投票出金基础上合并 BaseTreasury 全部入金能力
 * （receive ETH、purchaseBUnitWith3009Authorization → BUnitPurchased）并把原生 ETH 出金
 * 并入 voteErc20Transfer（token == address(0)）。bytecode 变更，预测地址改为下列新址。
 * 已在 Base(8453) 部署，deploy tx 0xffd21164afe1c331470a9e92e9d273d8aaf8d176d1c1547f9bc3ca8ad9fe3ffb，
 * block 47991996，initCodeHash 0x63b6cca1e243dee233a9a0186344af7d231dfc83d94c8485f3f4c6a8159ba8fe。
 * 作为唯一国库（BaseTreasury 0x5c64…、旧 ConetTreasury 0xc6e6… / 0x30a9… 均弃用）。
 * CoNET L1(224422) 须用同脚本 --network conet 部署同址后才有 code。
 */
export const CONET_TREASURY_CREATE2_PREDICTED = getAddress(
  "0xa311c8fBE7CafC611603Ee925465A62493B73B30"
);
/** @deprecated 旧 ConetTreasury（无 ERC20 投票出金），已被 CONET_TREASURY_CREATE2_PREDICTED 取代 */
export const CONET_TREASURY_CREATE2_PREDICTED_LEGACY = getAddress(
  "0xc6e615431BC0c0c65E09e04877a08AC927A30242"
);
/** @deprecated 仅加 ERC20 投票出金的中间版（未合并 BaseTreasury 入金），已被统一国库 0xa311… 取代 */
export const CONET_TREASURY_CREATE2_PREDICTED_LEGACY_V2 = getAddress(
  "0x30a9251bC24df235BdCB6F20933f74d6EFc247a8"
);

/** Peer 桥模块 CREATE2 salt（constructor 固定链接 Treasury 同址） */
export const CONET_TREASURY_PEER_CREATE2_SALT = id("beamio.conet_treasury_peer.v1");

/**
 * ⚠️ 下列 Peer / wCNET 地址绑定的是 *旧* treasury 0xc6e6…（Peer constructor immutable treasury）。
 * 统一国库 0xa311… 若需 mint/peer 能力，须用新 treasury 重新预测并部署 Peer 栈（地址会随之改变），
 * 并完成 BUint/GB/wCNET minter 重绑；见 deployConetTreasuryCreate2 + configureConetTreasuryOnConet。
 */
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
