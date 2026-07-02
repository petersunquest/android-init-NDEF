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

/** 当前 CoNET 已部署 ConetTreasury（mintFactoryToken 调用方）；见 deployments/conet-addresses.json */
export const CONET_USDC_MINTER = getAddress(
  "0x6dC686831A497c2a9d0a2ff5A000E3Bb40a2E795"
);

/** BeamioBUnits implementation CREATE2 salt */
export const BUINT_IMPL_CREATE2_SALT = id("beamio.bunits.impl.v1");
/** BeamioBUnits ERC1967 proxy CREATE2 salt（canonical 地址） */
export const BUINT_PROXY_CREATE2_SALT = id("beamio.bunits.proxy.v1");

/** GBToken implementation */
export const GBTOKEN_IMPL_CREATE2_SALT = id("beamio.gb.erc20.impl.v1");
/** GBToken proxy */
export const GBTOKEN_PROXY_CREATE2_SALT = id("beamio.gb.erc20.proxy.v1");

/** conet-USDC FactoryERC20Upgradeable */
export const CONET_USDC_IMPL_CREATE2_SALT = id("beamio.conet_usdc.impl.v1");
export const CONET_USDC_PROXY_CREATE2_SALT = id("beamio.conet_usdc.proxy.v1");

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
export const CONET_USDC_UUPS_IMPL_PREDICTED = getAddress(
  "0xc68322E4822f7ECAd168a3E95BB00E7cA00688a3"
);
export const CONET_USDC_UUPS_PROXY_PREDICTED = getAddress(
  "0x84e55A7d82aEa1243cB88b20dDde9Ba5cea0E134"
);
