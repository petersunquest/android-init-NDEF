/**
 * Nick CREATE2 部署 ERC20 UUPS 栈（impl → proxy）。
 *
 * 运行:
 *   npx hardhat run scripts/deployErc20UupsCreate2.ts --network conet
 *   TOKEN=buint|gb|usdc npx hardhat run scripts/deployErc20UupsCreate2.ts --network base
 *
 * 环境变量:
 *   TOKEN — buint | gb | usdc（默认 buint）
 *   DRY_RUN=1 — 只预测地址
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
import {
  nickCreate2DeployCalldata,
  predictCreate2,
  predictErc20UupsStack,
} from "./utils/erc20UupsCreate2.js";

type TokenKey = "buint" | "gb" | "usdc";

async function deployNick(
  ethers: Awaited<ReturnType<typeof networkModule.connect>>["ethers"],
  deployer: { sendTransaction: (tx: object) => Promise<{ hash: string; wait: () => Promise<unknown> }>; estimateGas: (tx: object) => Promise<bigint> },
  factoryAddress: string,
  salt: string,
  initCode: string,
  label: string
): Promise<void> {
  const predicted = predictCreate2(factoryAddress, salt, initCode);
  const existing = await ethers.provider.getCode(predicted);
  if (existing !== "0x" && existing.length > 2) {
    console.log(`✅ ${label} 已存在:`, predicted);
    return;
  }
  const data = nickCreate2DeployCalldata(salt, initCode);
  let gasLimit = 8_000_000n;
  try {
    gasLimit = ((await deployer.estimateGas({ to: factoryAddress, data })) * 120n) / 100n;
  } catch {
    console.warn(`${label}: estimateGas 失败，使用默认 gasLimit`);
  }
  const fee = await ethers.provider.getFeeData();
  const maxFeePerGas = ((fee.maxFeePerGas ?? 1_000_000_000n) * 3n) / 1n;
  const maxPriorityFeePerGas = ((fee.maxPriorityFeePerGas ?? 100_000_000n) * 3n) / 1n;
  const tx = await deployer.sendTransaction({
    to: factoryAddress,
    data,
    gasLimit,
    maxFeePerGas,
    maxPriorityFeePerGas,
  });
  console.log(`${label} deploy tx:`, tx.hash);
  await tx.wait();
  const code = await ethers.provider.getCode(predicted);
  if (code === "0x" || code.length <= 2) {
    throw new Error(`${label} CREATE2 后无 code: ${predicted}`);
  }
  console.log(`✅ ${label}:`, predicted);
}

async function main() {
  const token = (process.env.TOKEN || "buint").toLowerCase() as TokenKey;
  if (!["buint", "gb", "usdc"].includes(token)) {
    throw new Error("TOKEN must be buint | gb | usdc");
  }

  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  if (!deployer) throw new Error("无签名账户");

  const factoryAddress = getAddress(process.env.ERC20_UUPS_FACTORY || NICK_CREATE2_FACTORY);
  const dryRun = process.env.DRY_RUN === "1";

  let implSalt: string;
  let proxySalt: string;
  let stack;
  if (token === "buint") {
    implSalt = BUINT_IMPL_CREATE2_SALT;
    proxySalt = BUINT_PROXY_CREATE2_SALT;
    stack = await predictErc20UupsStack({
      ethers,
      nickFactory: factoryAddress,
      implSalt,
      proxySalt,
      contractName: "BeamioBUnits",
      encodeInitialize: (iface: Interface) =>
        iface.encodeFunctionData("initialize", [BUINT_INITIAL_ADMIN]),
    });
  } else if (token === "gb") {
    implSalt = GBTOKEN_IMPL_CREATE2_SALT;
    proxySalt = GBTOKEN_PROXY_CREATE2_SALT;
    stack = await predictErc20UupsStack({
      ethers,
      nickFactory: factoryAddress,
      implSalt,
      proxySalt,
      contractName: "GBToken",
      encodeInitialize: (iface: Interface) =>
        iface.encodeFunctionData("initialize", [GBTOKEN_INITIAL_ADMIN]),
    });
  } else {
    implSalt = CONET_USDC_IMPL_CREATE2_SALT;
    proxySalt = CONET_USDC_PROXY_CREATE2_SALT;
    stack = await predictErc20UupsStack({
      ethers,
      nickFactory: factoryAddress,
      implSalt,
      proxySalt,
      contractName: "FactoryERC20Upgradeable",
      encodeInitialize: (iface: Interface) =>
        iface.encodeFunctionData("initialize", [
          CONET_USDC_TOKEN_NAME,
          CONET_USDC_TOKEN_SYMBOL,
          CONET_USDC_TOKEN_DECIMALS,
          CONET_USDC_MINTER,
        ]),
    });
  }

  console.log("=".repeat(60));
  console.log(`ERC20 UUPS CREATE2 deploy — ${token}`);
  console.log("impl: ", stack.impl);
  console.log("proxy:", stack.proxy, "(canonical)");
  if (dryRun) return;

  const factoryCode = await ethers.provider.getCode(factoryAddress);
  if (factoryCode === "0x" || factoryCode.length <= 2) {
    throw new Error(`Nick factory 无 code: ${factoryAddress}`);
  }

  await deployNick(ethers, deployer, factoryAddress, implSalt, stack.implInitCode, `${token} impl`);
  await deployNick(ethers, deployer, factoryAddress, proxySalt, stack.proxyInitCode, `${token} proxy`);

  if (token === "buint") {
    const fs = await import("fs");
    const path = await import("path");
    const out = {
      network: (await ethers.provider.getNetwork()).chainId.toString(),
      deployer: deployer.address,
      impl: stack.impl,
      proxy: stack.proxy,
      initialAdmin: BUINT_INITIAL_ADMIN,
      deployedAt: new Date().toISOString(),
    };
    const p = path.join(process.cwd(), "deployments", "conet-buint-uups-create2.json");
    fs.writeFileSync(p, JSON.stringify(out, null, 2));
    console.log("wrote", p);
  } else if (token === "gb") {
    const fs = await import("fs");
    const path = await import("path");
    const out = {
      network: (await ethers.provider.getNetwork()).chainId.toString(),
      deployer: deployer.address,
      impl: stack.impl,
      proxy: stack.proxy,
      initialAdmin: GBTOKEN_INITIAL_ADMIN,
      deployedAt: new Date().toISOString(),
    };
    const p = path.join(process.cwd(), "deployments", "conet-gb-uups-create2.json");
    fs.writeFileSync(p, JSON.stringify(out, null, 2));
    console.log("wrote", p);
  } else if (token === "usdc") {
    const fs = await import("fs");
    const path = await import("path");
    const usdc = await ethers.getContractAt("FactoryERC20Upgradeable", stack.proxy);
    const out = {
      network: (await ethers.provider.getNetwork()).chainId.toString(),
      deployer: deployer.address,
      impl: stack.impl,
      proxy: stack.proxy,
      minter: CONET_USDC_MINTER,
      name: await usdc.name(),
      symbol: await usdc.symbol(),
      decimals: (await usdc.decimals()).toString(),
      deployedAt: new Date().toISOString(),
    };
    const p = path.join(process.cwd(), "deployments", "conet-usdc-uups-create2.json");
    fs.writeFileSync(p, JSON.stringify(out, null, 2));
    console.log("wrote", p);
    console.log("   name:", out.name, "symbol:", out.symbol, "decimals:", out.decimals);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
