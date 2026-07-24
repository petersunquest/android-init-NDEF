/**
 * ERC20 UUPS CREATE2 常量（impl + proxy 双 salt → 跨链 canonical 代理同址）。
 */
import { id, getAddress } from "ethers";

export { NICK_CREATE2_FACTORY } from "./bunitDeployConstants.js";
export { BUINT_INITIAL_ADMIN } from "./bunitDeployConstants.js";
export { GBTOKEN_INITIAL_ADMIN } from "./gbTokenDeployConstants.js";
export { CONET_TREASURY_CREATE2_PREDICTED as CONET_TREASURY_ADDRESS } from "./conetTreasuryDeployConstants.js";

/** conet-USDC 链上 name（对齐 GB「CONET GB」；Blockscout 读 name()） */
export const CONET_USDC_TOKEN_NAME = "CONET USDC";
export const CONET_USDC_TOKEN_SYMBOL = "USDC";
export const CONET_USDC_TOKEN_DECIMALS = 6;

/**
 * CONET-USDC minter = 跨链同址 ConetTreasury（CREATE2 `0xa311…`）。
 * 旧 minter `0x6dC6…` 已废弃；改 minter 会改变 proxy CREATE2 地址（initialize 含 minter）。
 */
export const CONET_USDC_MINTER = getAddress(
  "0xa311c8fBE7CafC611603Ee925465A62493B73B30"
);

/** BeamioBUnits implementation CREATE2 salt */
export const BUINT_IMPL_CREATE2_SALT = id("beamio.bunits.impl.v1");
/** BeamioBUnits ERC1967 proxy CREATE2 salt（canonical 地址） */
export const BUINT_PROXY_CREATE2_SALT = id("beamio.bunits.proxy.v1");

/** GBToken implementation */
export const GBTOKEN_IMPL_CREATE2_SALT = id("beamio.gb.erc20.impl.v1");
/** GBToken proxy */
export const GBTOKEN_PROXY_CREATE2_SALT = id("beamio.gb.erc20.proxy.v1");

/** conet-USDC FactoryERC20Upgradeable（v2：minter = 同址 Treasury 0xa311…） */
export const CONET_USDC_IMPL_CREATE2_SALT = id("beamio.conet_usdc.impl.v2");
export const CONET_USDC_PROXY_CREATE2_SALT = id("beamio.conet_usdc.proxy.v2");

/** wCNET：与 CONET-USDC 相同的 UUPS + Nick CREATE2 双阶段部署。 */
export const WCNET_IMPL_CREATE2_SALT = id("beamio.wcnet.impl.v1");
export const WCNET_PROXY_CREATE2_SALT = id("beamio.wcnet.proxy.v1");
export const WCNET_TOKEN_NAME = "Wrapped CoNET";
export const WCNET_TOKEN_SYMBOL = "wCNET";
export const WCNET_TOKEN_DECIMALS = 18;

/** @deprecated 直连部署 v2（非 UUPS） */
export const BUINT_CREATE2_SALT_LEGACY = id("beamio.bunits.v2");
/** @deprecated 直连 GB v2 */
export const GBTOKEN_CREATE2_SALT_LEGACY = id("beamio.gb.erc20.v2");

/** 运行 predictErc20UupsCreate2.ts 回填 — canonical = proxy */
export const BUINT_UUPS_IMPL_PREDICTED = getAddress(
  "0x6a35EA52ddBeACcA2Fd21A7542AC9f2652a30c1D"
);
export const BUINT_UUPS_PROXY_PREDICTED = getAddress(
  "0x54ac4672cE75EC5ACebaeF1a7aFC6F49E77Ae9Ae"
);
export const GBTOKEN_UUPS_IMPL_PREDICTED = getAddress(
  "0x0A089972b49fCB7C661F2C7295803e1cd5FDB4ef"
);
export const GBTOKEN_UUPS_PROXY_PREDICTED = getAddress(
  "0xC3EF02DaE632b4C10abB66e07d92a387c10838D8"
);
/** Legacy Nick CREATE2 UUPS USDC (deprecated; canonical is Treasury createERC20 factory USDC). */
export const CONET_USDC_UUPS_IMPL_PREDICTED = getAddress(
  "0x81880438bF3E7672192771EB1599C15d2014F166"
);
export const CONET_USDC_UUPS_PROXY_PREDICTED = getAddress(
  "0xF9240fd613C00d5C479f1E9f1690130c5Fdc8BC3"
);
/** Canonical CoNET USDC: Treasury.createERC20 factory-registered token. */
export const CONET_USDC_FACTORY = getAddress(
  "0xfD0D7B0706AaB5E4351bcED37bC3C77ed6813907"
);
/** 新版 wCNET UUPS implementation / proxy（两链同址）。 */
export const WCNET_UUPS_IMPL_PREDICTED = getAddress(
  "0x5BD672918E4a2F37109b308f26125690b2861C99"
);
export const WCNET_UUPS_PROXY_PREDICTED = getAddress(
  "0x40B059e13d16B1C1E4dE032B04C5fbE554e0fA21"
);
