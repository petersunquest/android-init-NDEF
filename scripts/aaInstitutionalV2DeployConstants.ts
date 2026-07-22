/**
 * BeamioFactoryInstitutionalV2 跨链 CREATE2 常量（V2 机构 AA 轨）。
 * 与 V1 `aaDeployConstants.ts` 分离 — 见 beamio-aa-account-dev.mdc
 */
import { id, getAddress } from "ethers";

export { NICK_CREATE2_FACTORY } from "./bunitDeployConstants.js";

export const BEAMIO_AA_FACTORY_V2_ADMIN = getAddress(
  "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1"
);

export const BEAMIO_AA_FACTORY_V2_INITIAL_ACCOUNT_LIMIT = 100;

/** CREATE2 salt — must differ from V1 `beamio.aa.factory.v1` */
export const BEAMIO_AA_FACTORY_V2_CREATE2_SALT = id("beamio.aa.factory.v2");

/**
 * Current bytecode CREATE2 prediction (Nick + salt v2).
 * Update when Factory/AccountInstitutionalV2 bytecode changes — re-run deploy script DRY_RUN.
 */
export const BEAMIO_AA_FACTORY_V2_PREDICTED = getAddress(
  "0x02F00061ae54d76C3308EA24D2B3d0a24df60fAd"
);
