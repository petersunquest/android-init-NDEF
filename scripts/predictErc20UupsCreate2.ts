/**
 * 预测 B-Unit / GB / conet-USDC 的 UUPS impl + proxy CREATE2 同址。
 * 运行: npx hardhat run scripts/predictErc20UupsCreate2.ts
 */
import { network as networkModule } from "hardhat";
import { Interface, getAddress } from "ethers";
import {
  BUINT_IMPL_CREATE2_SALT,
  BUINT_PROXY_CREATE2_SALT,
  BUINT_INITIAL_ADMIN,
  GBTOKEN_IMPL_CREATE2_SALT,
  GBTOKEN_PROXY_CREATE2_SALT,
  GBTOKEN_INITIAL_ADMIN,
  CONET_USDC_IMPL_CREATE2_SALT,
  CONET_USDC_PROXY_CREATE2_SALT,
  CONET_USDC_MINTER,
  CONET_USDC_TOKEN_NAME,
  CONET_USDC_TOKEN_SYMBOL,
  CONET_USDC_TOKEN_DECIMALS,
  NICK_CREATE2_FACTORY,
} from "./erc20UupsDeployConstants.js";
import { predictErc20UupsStack } from "./utils/erc20UupsCreate2.js";

async function main() {
  const { ethers } = await networkModule.connect();
  const nick = getAddress(NICK_CREATE2_FACTORY);

  const buint = await predictErc20UupsStack({
    ethers,
    nickFactory: nick,
    implSalt: BUINT_IMPL_CREATE2_SALT,
    proxySalt: BUINT_PROXY_CREATE2_SALT,
    contractName: "BeamioBUnits",
    encodeInitialize: (iface: Interface) =>
      iface.encodeFunctionData("initialize", [BUINT_INITIAL_ADMIN]),
  });

  const gb = await predictErc20UupsStack({
    ethers,
    nickFactory: nick,
    implSalt: GBTOKEN_IMPL_CREATE2_SALT,
    proxySalt: GBTOKEN_PROXY_CREATE2_SALT,
    contractName: "GBToken",
    encodeInitialize: (iface: Interface) =>
      iface.encodeFunctionData("initialize", [GBTOKEN_INITIAL_ADMIN]),
  });

  const usdc = await predictErc20UupsStack({
    ethers,
    nickFactory: nick,
    implSalt: CONET_USDC_IMPL_CREATE2_SALT,
    proxySalt: CONET_USDC_PROXY_CREATE2_SALT,
    contractName: "FactoryERC20Upgradeable",
    encodeInitialize: (iface: Interface) =>
      iface.encodeFunctionData("initialize", [
        CONET_USDC_TOKEN_NAME,
        CONET_USDC_TOKEN_SYMBOL,
        CONET_USDC_TOKEN_DECIMALS,
        CONET_USDC_MINTER,
      ]),
  });

  console.log("ERC20 UUPS CREATE2 predicted (canonical = PROXY):");
  console.log("\nBeamioBUnits:");
  console.log("  impl: ", buint.impl);
  console.log("  proxy:", buint.proxy);
  console.log("\nGBToken:");
  console.log("  impl: ", gb.impl);
  console.log("  proxy:", gb.proxy);
  console.log("\nconet-USDC (FactoryERC20Upgradeable):");
  console.log("  impl: ", usdc.impl);
  console.log("  proxy:", usdc.proxy);
  console.log("\n→ 回填 scripts/erc20UupsDeployConstants.ts 中 *_UUPS_PROXY_PREDICTED");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
