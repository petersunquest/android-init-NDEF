/**
 * B-Unit / CREATE2 最小常量（Peer 部署脚本依赖 NICK factory）。
 */
import { id, getAddress } from "ethers";

/** 各链部署后首个 B-Units admin */
export const BUINT_INITIAL_ADMIN = getAddress(
  "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1"
);

/** CREATE2 salt：v2 = 付费池可 P2P 转账 */
export const BUINT_CREATE2_SALT = id("beamio.bunits.v2");

/**
 * Nick's deterministic CREATE2 factory（ETH / Base / CoNET 等常见链已部署）。
 */
export const NICK_CREATE2_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C";

/** UUPS canonical B-Unit proxy（跨链同址） */
export const BUINT_UUPS_PROXY_PREDICTED = getAddress(
  "0x54ac4672cE75EC5ACebaeF1a7aFC6F49E77Ae9Ae"
);
export const BUINT_CANONICAL_ADDRESS = BUINT_UUPS_PROXY_PREDICTED;
