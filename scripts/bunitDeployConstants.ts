/**
 * BeamioBUnits 跨链 CREATE2 部署常量（initCode 与各链 deployer/salt 一致 → 同址）。
 */
import { id, getAddress } from "ethers";

/** 各链部署后首个 B-Units admin（须写入 constructor，保证 CREATE2 initCode 一致） */
export const BUINT_INITIAL_ADMIN = getAddress(
  "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1"
);

/** CREATE2 salt：v2 = 付费池可 P2P 转账 */
export const BUINT_CREATE2_SALT = id("beamio.bunits.v2");

/** @deprecated v1（transfer 全锁） */
export const BUINT_CREATE2_SALT_V1 = id("beamio.bunits.v1");

/** @deprecated 直连 v2（非 UUPS）；canonical 见 BUINT_UUPS_PROXY_PREDICTED */
export const BUINT_CREATE2_PREDICTED = getAddress(
  "0x4289601782F7a5572fF9409DdbBE4572107CcdA9"
);

export {
  BUINT_UUPS_IMPL_PREDICTED,
  BUINT_UUPS_PROXY_PREDICTED,
} from "./erc20UupsDeployConstants.js";

/** UUPS canonical（跨链 Nick CREATE2 proxy 同址） */
export { BUINT_UUPS_PROXY_PREDICTED as BUINT_CANONICAL_ADDRESS } from "./erc20UupsDeployConstants.js";

/** @deprecated v1（transfer 全锁） */
export const BUINT_CREATE2_PREDICTED_V1 = getAddress(
  "0xa354CC4c414568Dd14F6d63b53013f35483427f0"
);

/**
 * Nick's deterministic CREATE2 factory（ETH / Base 等常见链已部署）。
 * CoNET 若无 Nick factory，需先用 Arachnid 预签名 tx 部署；mainnet-rpc1.conet.network 链上须已具备。
 */
export const NICK_CREATE2_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C";
