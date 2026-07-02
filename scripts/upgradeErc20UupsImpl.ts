/**
 * 升级 ERC20 UUPS 代理背后的 implementation；**proxy 地址不变**（canonical）。
 *
 * 运行:
 *   TOKEN=buint npx hardhat run scripts/upgradeErc20UupsImpl.ts --network conet
 *   TOKEN=gb|usdc 同上
 *
 * 环境变量:
 *   TOKEN — buint | gb | usdc（默认 buint）
 *   ERC20_UUPS_PROXY — 覆盖 proxy 地址（默认 erc20UupsDeployConstants 预测值）
 */
import { network as networkModule } from "hardhat";
import { getAddress } from "ethers";
import {
  BUINT_UUPS_PROXY_PREDICTED,
  GBTOKEN_UUPS_PROXY_PREDICTED,
  CONET_USDC_UUPS_PROXY_PREDICTED,
} from "./erc20UupsDeployConstants.js";

type TokenKey = "buint" | "gb" | "usdc";

const CONTRACT_BY_TOKEN: Record<TokenKey, string> = {
  buint: "BeamioBUnits",
  gb: "GBToken",
  usdc: "FactoryERC20Upgradeable",
};

const DEFAULT_PROXY: Record<TokenKey, string> = {
  buint: BUINT_UUPS_PROXY_PREDICTED,
  gb: GBTOKEN_UUPS_PROXY_PREDICTED,
  usdc: CONET_USDC_UUPS_PROXY_PREDICTED,
};

async function main() {
  const token = (process.env.TOKEN || "buint").toLowerCase() as TokenKey;
  if (!["buint", "gb", "usdc"].includes(token)) {
    throw new Error("TOKEN must be buint | gb | usdc");
  }

  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  const proxyAddr = getAddress(process.env.ERC20_UUPS_PROXY || DEFAULT_PROXY[token]);
  const contractName = CONTRACT_BY_TOKEN[token];

  console.log("=".repeat(60));
  console.log(`Upgrade ${contractName} implementation (UUPS)`);
  console.log("proxy (unchanged):", proxyAddr);

  const proxyCode = await ethers.provider.getCode(proxyAddr);
  if (proxyCode === "0x" || proxyCode.length <= 2) {
    throw new Error(`Proxy 无 code，请先 deployErc20UupsCreate2.ts: ${proxyAddr}`);
  }

  const ImplFactory = await ethers.getContractFactory(contractName);
  const newImpl = await ImplFactory.deploy();
  await newImpl.waitForDeployment();
  const newImplAddr = await newImpl.getAddress();
  console.log("new implementation:", newImplAddr);
  const deployTx = newImpl.deploymentTransaction()?.hash;
  if (deployTx) console.log("  deploy tx:", deployTx);

  const proxy = await ethers.getContractAt(
    [
      "function upgradeToAndCall(address newImplementation, bytes data) external payable",
      "function admin() view returns (address)",
      "function minter() view returns (address)",
    ],
    proxyAddr,
    signer
  );

  if (token === "usdc") {
    const minter = await proxy.minter();
    if (getAddress(minter) !== getAddress(signer.address)) {
      throw new Error(`Signer ${signer.address} is not minter (${minter}) on USDC proxy`);
    }
  } else {
    const admin = await proxy.admin();
    if (getAddress(admin) !== getAddress(signer.address)) {
      throw new Error(`Signer ${signer.address} is not admin (${admin}) on ${token} proxy`);
    }
  }

  const tx = await proxy.upgradeToAndCall(newImplAddr, "0x");
  console.log("upgradeToAndCall tx:", tx.hash);
  await tx.wait();
  console.log("✅ upgraded — proxy still", proxyAddr);
  console.log("→ 验证 impl:", newImplAddr, "（Standard JSON + proxy legacy partial）");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
