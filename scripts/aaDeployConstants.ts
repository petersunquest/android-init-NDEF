/**
 * BeamioFactoryPaymasterV07 跨链 CREATE2 部署常量（initCode + salt 各链一致 → 同址）。
 */
import { id, getAddress } from "ethers";

export { NICK_CREATE2_FACTORY } from "./bunitDeployConstants.js";

/** 各链 Factory constructor admin（须写入 constructor，保证 CREATE2 initCode 一致） */
export const BEAMIO_AA_FACTORY_ADMIN = getAddress(
  "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1"
);

/** 每 EOA 允许创建的 AA 数量上限（constructor 参数，各链一致） */
export const BEAMIO_AA_FACTORY_INITIAL_ACCOUNT_LIMIT = 100;

/** CREATE2 salt：固定字符串，各链相同 */
export const BEAMIO_AA_FACTORY_CREATE2_SALT = id("beamio.aa.factory.v1");

/**
 * 当前 bytecode 下 CREATE2 预测同址（各链 Nick factory + 同 initCode）。
 * bytecode 变更后须重跑 predictBeamioAAStackCreate2.ts 并更新此常量。
 */
export const BEAMIO_AA_FACTORY_PREDICTED = getAddress(
  "0xe58F457Cd5674516400013E8d338054be556A730"
);

/** 固定测试 EOA：用于 predict 脚本输出跨链 AA 地址样例 */
export const BEAMIO_AA_PREDICT_SAMPLE_EOA = getAddress(
  "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1"
);

/** admin EOA index=0 的 CREATE2 BeamioAccount（与 factory.getAddress 一致） */
export const BEAMIO_AA_PREDICT_SAMPLE_ACCOUNT = getAddress(
  "0xaAE26581B0126cDEE36602413FFc94c4436F310C"
);
