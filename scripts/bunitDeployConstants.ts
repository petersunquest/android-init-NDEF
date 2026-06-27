/**
 * BeamioBUnits 跨链 CREATE2 部署常量（initCode 与各链 deployer/salt 一致 → 同址）。
 */
import { id, getAddress } from "ethers";

/** 各链部署后首个 B-Units admin（须写入 constructor，保证 CREATE2 initCode 一致） */
export const BUINT_INITIAL_ADMIN = getAddress(
  "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1"
);

/** CREATE2 salt：固定字符串，各链相同 */
export const BUINT_CREATE2_SALT = id("beamio.bunits.v1");

/** 当前 bytecode（含 EIP-2612/EIP-3009）+ Nick factory 下各链同址预测 */
export const BUINT_CREATE2_PREDICTED = getAddress(
  "0xa354CC4c414568Dd14F6d63b53013f35483427f0"
);

/**
 * Nick's deterministic CREATE2 factory（ETH / Base 等常见链已部署）。
 * CoNET 若无 Nick factory，需先用 Arachnid 预签名 tx 部署；mainnet-rpc1.conet.network 链上须已具备。
 */
export const NICK_CREATE2_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C";
