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

/** Peer 桥模块 CREATE2 salt（v3：+ StableSwapLib + 本链 USDC swap + GB/B-Unit paidPool） */
export const CONET_TREASURY_PEER_CREATE2_SALT = id("beamio.conet_treasury_peer.v3");

/** @deprecated v2 Peer（无 StableSwapLib / 无本链 swap） */
export const CONET_TREASURY_PEER_CREATE2_SALT_V2 = id("beamio.conet_treasury_peer.v2");

/** @deprecated v1 Peer（无 ERC20 canonical / 无 WrappedLib） */
export const CONET_TREASURY_PEER_CREATE2_SALT_V1 = id("beamio.conet_treasury_peer.v1");

/** ConetTreasuryPeerWrappedLib CREATE2 salt（Peer 链接库，各链须先部署同址） */
export const CONET_TREASURY_PEER_WRAPPED_LIB_CREATE2_SALT = id("beamio.conet_treasury_peer_wrapped_lib.v1");

/** ConetTreasuryPeerStableSwapLib CREATE2 salt（换汇 + stable burn/mint 逻辑库） */
export const CONET_TREASURY_PEER_STABLE_SWAP_LIB_CREATE2_SALT = id(
  "beamio.conet_treasury_peer_stable_swap_lib.v1"
);

/** v2 Peer（ERC20 canonical + WrappedLib）；运行 predictCrossChainAssets.ts 复核 */
export const CONET_TREASURY_PEER_WRAPPED_LIB_CREATE2_PREDICTED = getAddress(
  "0xCED9De89917eB957aF6371a3c9b45af21d68A0Ed"
);

/** v3 Peer（StableSwapLib + 本链 USDC↔GB/B-Unit）；运行 predictCrossChainAssets.ts 复核 */
export const CONET_TREASURY_PEER_STABLE_SWAP_LIB_CREATE2_PREDICTED = getAddress(
  "0xcEC3A86C05b58239B937f17B75b459bD79e3bB95"
);

export const CONET_TREASURY_PEER_CREATE2_PREDICTED = getAddress(
  "0x025eC62F801B2f63d5C5b3eB066bab21B12Bbeb5"
);

/** @deprecated v2 Peer（0x30338D…，无 StableSwapLib / 本链 swap） */
export const CONET_TREASURY_PEER_CREATE2_PREDICTED_V2 = getAddress(
  "0x30338D2933604440d2f31169B37AE07F3EFA2d5b"
);

/** 默认 GB 标价：0.01 USDC / 1 GB → usdc6PerFullGb = 10000（miner 可 setUsdc6PerFullGb 调整） */
export const DEFAULT_USDC6_PER_FULL_GB = 10_000n;

/** v1 Peer（legacy B001/B002，无 ERC20 canonical） */
export const CONET_TREASURY_PEER_CREATE2_PREDICTED_V1 = getAddress(
  "0xCF26c1686aC5E01e37B72017E575511C42cad29f"
);

/** Wrapped wCNET CREATE2（minter = Treasury 同址） */
export const WRAPPED_CONET_CREATE2_PREDICTED = getAddress(
  "0x35bFAD2832E916e54474c4ca9DBd71843C539503"
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

/** CoNET 链 canonical USDC（UUPS proxy；minter = 同址 Treasury 0xa311…；跨链同址） */
export const CONET_USDC = getAddress("0xF9240fd613C00d5C479f1E9f1690130c5Fdc8BC3");

/** @deprecated minter=旧国库 0x6dC6… 的 UUPS CONET-USDC */
export const CONET_USDC_LEGACY_UUPS_V1 = getAddress("0x84e55A7d82aEa1243cB88b20dDde9Ba5cea0E134");

/** @deprecated Treasury 内 FactoryERC20 直连 conet-USDC */
export const CONET_USDC_LEGACY = getAddress("0x2975c85D8Cc8F5d263492E332A6dAa7ad11aDBdC");

/** CoNET / Base 同址 GBToken UUPS proxy（9 decimals；free+paid 可 transfer） */
export const GB_TOKEN_ERC20_CREATE2_PREDICTED = getAddress(
  "0xC3EF02DaE632b4C10abB66e07d92a387c10838D8"
);

/** @deprecated 直连 GB v2（非 UUPS） */
export const GB_TOKEN_ERC20_CREATE2_PREDICTED_LEGACY = getAddress(
  "0xBDa7cC31E791B74a5d51f88383deBe57D2696cef"
);

/** @deprecated v1 GBToken（free+paid 均可 transfer） */
export const GB_TOKEN_ERC20_CREATE2_PREDICTED_V1 = getAddress(
  "0xd0A7BBD309A3E776A696c1495dEA4dcEDc9111b9"
);

/**
 * 原生跨链 trio：CoNET / Base CREATE2 同址；`bridgeNativeAsset` / relayer `peerToken` 均用此地址。
 */
export const NATIVE_CROSS_CHAIN_GB = GB_TOKEN_ERC20_CREATE2_PREDICTED;
export const NATIVE_CROSS_CHAIN_BUINT = getAddress(
  "0x54ac4672cE75EC5ACebaeF1a7aFC6F49E77Ae9Ae"
);

/** @deprecated 直连 B-Unit v2 */
export const NATIVE_CROSS_CHAIN_BUINT_LEGACY = getAddress(
  "0x4289601782F7a5572fF9409DdbBE4572107CcdA9"
);
export const NATIVE_CROSS_CHAIN_WCNET = WRAPPED_CONET_CREATE2_PREDICTED;

/** 与 conetTreasury.sol `_wrappedSalt` 前缀一致 */
export const WRAPPED_ERC20_SALT_PREFIX = "beamio.wrapped.erc20.v1";

export { NICK_CREATE2_FACTORY } from "./bunitDeployConstants.js";
