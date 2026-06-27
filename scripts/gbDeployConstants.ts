/**
 * ConetGB1155 栈跨链 CREATE2 部署常量（initCode + salt 各链一致 → 同址）。
 * PR-2 部署脚本与 conet/base 同址预测均引用本文件。
 */
import { id, getAddress } from "ethers";

/** 各链 GB 栈 admin / issuer / operator 初始角色持有者 */
export const GB_INITIAL_ADMIN = getAddress(
  "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1"
);

/** UTC 整点 epoch；跨链须相同以保证 hourId 语义一致 */
export const GB_START_TIME = 1779703200n;

/** 与 legacy CoNET 部署 conet-ConetGB1155.json 一致 */
export const GB_START_HOUR_ID = 1n;

export const GB_CREATE2_SALT = id("beamio.conetgb1155.v1");
export const GB_TOTAL_CREATE2_SALT = id("beamio.conetgb_total.v1");
export const GB_USER_TOTAL_CREATE2_SALT = id("beamio.conetgb_user_total.v1");

/** 当前 bytecode（含 EIP-2612/EIP-3009）+ Nick factory 下各链同址预测 */
export const GB_CREATE2_PREDICTED = getAddress(
  "0x3Dc53e528d45225e8F38c391Cc6a72CDec435748"
);
export const GB_TOTAL_CREATE2_PREDICTED = getAddress(
  "0x949ed49faB0e999f685f16e09Cf5EaaF4090F290"
);
export const GB_USER_TOTAL_CREATE2_PREDICTED = getAddress(
  "0x40435307b533c5bd8349368f27BaaDA13678657C"
);

export { NICK_CREATE2_FACTORY } from "./bunitDeployConstants.js";
