/**
 * BeamioOracle / BeamioQuoteHelperV07 跨链 CREATE2 部署常量（initCode + salt 各链一致 → 同址）。
 */
import { id, getAddress } from "ethers";

export { NICK_CREATE2_FACTORY } from "./bunitDeployConstants.js";

/** Oracle owner（constructor 参数，各链一致） */
export const BEAMIO_ORACLE_ADMIN = getAddress(
  "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1"
);

/** QuoteHelper owner（与 Oracle owner 相同，便于运维） */
export const BEAMIO_QUOTE_HELPER_ADMIN = BEAMIO_ORACLE_ADMIN;

export const BEAMIO_ORACLE_CREATE2_SALT = id("beamio.oracle.v1");
export const BEAMIO_QUOTE_HELPER_CREATE2_SALT = id("beamio.quoteHelper.v07.v1");

/**
 * bytecode 变更后须重跑 predictBeamioOracleCreate2.ts 并更新下列预测地址。
 * QuoteHelper initCode 依赖 BEAMIO_ORACLE_PREDICTED + BEAMIO_QUOTE_HELPER_ADMIN。
 */
export const BEAMIO_ORACLE_PREDICTED = getAddress(
  "0x77CB8358c5a37aB7190b0A2C7EaA7fEeDCF11008"
);

export const BEAMIO_QUOTE_HELPER_PREDICTED = getAddress(
  "0xD3f275774831810006d744d32E6b024507C0d374"
);
