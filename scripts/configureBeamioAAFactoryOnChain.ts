/**
 * BeamioFactoryPaymasterV07 post-deploy 链上配置（CREATE2 同址部署后执行）:
 *   initializeChainConfig(module, quoteHelper, userCard, usdc)
 *   可选: setAAFactory on Card Factory
 *
 * 环境变量:
 *   BEAMIO_AA_FACTORY — 覆盖 Factory 地址（默认 deployments/beamioAAFactory-create2-meta.json predictedAddress）
 *   AA_MODULE / AA_QUOTE_HELPER / AA_USER_CARD / AA_USDC — 覆盖链上依赖地址
 *   SET_CARD_FACTORY_AA=1 — 同时调用 Card Factory setAAFactory
 *   CARD_FACTORY_OWNER_PK — setAAFactory 所需 owner 私钥
 *
 * 运行:
 *   npx hardhat run scripts/configureBeamioAAFactoryOnChain.ts --network base
 *   npx hardhat run scripts/configureBeamioAAFactoryOnChain.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { getAddress } from "ethers";
import { resolveBaseCardFactoryAddress } from "./readCanonicalBaseCardFactory.js";
import {
  BEAMIO_ORACLE_PREDICTED,
  BEAMIO_QUOTE_HELPER_PREDICTED,
} from "./oracleDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT = path.join(__dirname, "..");
const BASE_CHAIN_ID = 8453n;
const CONET_CHAIN_ID = 224422n;

type ChainConfig = {
  module: string;
  quoteHelper: string;
  userCard: string;
  usdc: string;
};

function readJson(pathname: string): Record<string, unknown> {
  if (!fs.existsSync(pathname)) return {};
  return JSON.parse(fs.readFileSync(pathname, "utf-8"));
}

function resolveFactoryAddress(): string {
  if (process.env.BEAMIO_AA_FACTORY) {
    return getAddress(process.env.BEAMIO_AA_FACTORY);
  }
  const metaPath = path.join(ROOT, "deployments", "beamioAAFactory-create2-meta.json");
  const meta = readJson(metaPath);
  if (meta.predictedAddress) return getAddress(String(meta.predictedAddress));
  throw new Error("未找到 AA Factory CREATE2 地址；先 deployBeamioAAFactoryCreate2 或设置 BEAMIO_AA_FACTORY");
}

function resolveChainConfig(chainId: bigint): ChainConfig {
  const fromEnv = (key: string): string | undefined => {
    const v = process.env[key];
    return v ? getAddress(v) : undefined;
  };

  if (chainId === BASE_CHAIN_ID) {
    const base = readJson(path.join(ROOT, "config", "base-addresses.json"));
    const full = readJson(path.join(ROOT, "deployments", "base-FullAccountAndUserCard.json"));
    const contracts = (full.contracts ?? {}) as Record<string, { address?: string }>;
    return {
      module:
        fromEnv("AA_MODULE") ??
        (contracts.BeamioContainerModuleV07?.address
          ? getAddress(contracts.BeamioContainerModuleV07.address)
          : getAddress("0xF50e41dFB647F8a62F3DBAf8f3Fcb39d74C7c9C8")),
      quoteHelper:
        fromEnv("AA_QUOTE_HELPER") ??
        (BEAMIO_QUOTE_HELPER_PREDICTED !== "0x0000000000000000000000000000000000000000"
          ? BEAMIO_QUOTE_HELPER_PREDICTED
          : getAddress("0xfa30c2086ff9a3D74576d55c2027586797A52F29")),
      userCard:
        fromEnv("AA_USER_CARD") ??
        (base.BEAMIO_USER_CARD_ASSET_ADDRESS
          ? getAddress(String(base.BEAMIO_USER_CARD_ASSET_ADDRESS))
          : getAddress("0xBCcfA50d2a5917C7A8662177F5F4B7A175787270")),
      usdc:
        fromEnv("AA_USDC") ??
        (base.USDC_BASE ? getAddress(String(base.USDC_BASE)) : getAddress("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")),
    };
  }

  if (chainId === CONET_CHAIN_ID) {
    const conet = readJson(path.join(ROOT, "deployments", "conet-addresses.json"));
    return {
      module:
        fromEnv("AA_MODULE") ??
        getAddress(String(conet.beamioContainerModule ?? "0xC0bd357A12100C47FB19E1a489B4375F44D63b8F")),
      quoteHelper:
        fromEnv("AA_QUOTE_HELPER") ??
        (BEAMIO_QUOTE_HELPER_PREDICTED !== "0x0000000000000000000000000000000000000000"
          ? BEAMIO_QUOTE_HELPER_PREDICTED
          : getAddress(String(conet.beamioQuoteHelperV07 ?? "0x052e34ed096875D0F1ce58eEFb88Ed676Fd1305f"))),
      userCard:
        fromEnv("AA_USER_CARD") ??
        getAddress(String(conet.BEAMIO_USER_CARD_DEFAULT ?? "0x5237e3A10e26bE616A02b49cbDf38d413d4d847F")),
      usdc:
        fromEnv("AA_USDC") ??
        getAddress(String(conet.conetUsdc ?? "0x40E302aBC19f6c9f376D7Dee037192a7a203e3Aa")),
    };
  }

  throw new Error(`Unsupported chainId ${chainId}; set AA_MODULE/AA_QUOTE_HELPER/AA_USER_CARD/AA_USDC`);
}

async function maybeSetCardFactoryAaFactory(
  ethers: Awaited<ReturnType<typeof networkModule.connect>>["ethers"],
  aaFactory: string,
  chainId: bigint
) {
  if (process.env.SET_CARD_FACTORY_AA !== "1") return;

  const pk = process.env.CARD_FACTORY_OWNER_PK;
  if (!pk) {
    console.warn("[card factory] SET_CARD_FACTORY_AA=1 但未设置 CARD_FACTORY_OWNER_PK，跳过 setAAFactory");
    return;
  }

  let cardFactoryAddr: string;
  if (chainId === BASE_CHAIN_ID) {
    cardFactoryAddr = resolveBaseCardFactoryAddress(path.join(ROOT, "deployments"));
  } else if (chainId === CONET_CHAIN_ID) {
    const conet = readJson(path.join(ROOT, "deployments", "conet-addresses.json"));
    cardFactoryAddr = getAddress(String(conet.CARD_FACTORY));
  } else {
    console.warn("[card factory] 未知 chainId，跳过 setAAFactory");
    return;
  }

  const wallet = new ethers.Wallet(pk, ethers.provider);
  const abi = [
    "function setAAFactory(address f) external",
    "function owner() external view returns (address)",
    "function aaFactory() external view returns (address)",
  ];
  const cardFactory = new ethers.Contract(cardFactoryAddr, abi, wallet);
  const owner = await cardFactory.owner();
  if (owner.toLowerCase() !== wallet.address.toLowerCase()) {
    throw new Error(`Card Factory owner 不匹配: owner=${owner}, signer=${wallet.address}`);
  }
  const current = await cardFactory.aaFactory();
  if (current.toLowerCase() === aaFactory.toLowerCase()) {
    console.log("[card factory] aaFactory 已是目标地址");
    return;
  }
  const tx = await cardFactory.setAAFactory(aaFactory);
  await tx.wait();
  console.log("[card factory] setAAFactory(", aaFactory, ")");
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("无签名账户");

  const net = await ethers.provider.getNetwork();
  const factoryAddress = resolveFactoryAddress();
  const cfg = resolveChainConfig(net.chainId);
  const factory = await ethers.getContractAt("BeamioFactoryPaymasterV07", factoryAddress, signer);

  console.log("=".repeat(60));
  console.log("Configure BeamioFactoryPaymasterV07");
  console.log("=".repeat(60));
  console.log("chainId:", net.chainId.toString());
  console.log("signer:", signer.address);
  console.log("AA Factory:", factoryAddress);
  console.log("module:", cfg.module);
  console.log("quoteHelper:", cfg.quoteHelper);
  console.log("userCard:", cfg.userCard);
  console.log("usdc:", cfg.usdc);

  const initialized = await factory.chainConfigInitialized();
  if (initialized) {
    console.log("\n[1] chainConfig 已初始化，跳过 initializeChainConfig");
  } else {
    const tx = await factory.initializeChainConfig(
      cfg.module,
      cfg.quoteHelper,
      cfg.userCard,
      cfg.usdc
    );
    await tx.wait();
    console.log("\n[1] initializeChainConfig 完成");
  }

  console.log("\n[verify] containerModule:", await factory.containerModule());
  console.log("[verify] quoteHelper:", await factory.quoteHelper());
  console.log("[verify] beamioUserCard:", await factory.beamioUserCard());
  console.log("[verify] USDC:", await factory.USDC());

  const currentQuoteHelper = await factory.quoteHelper();
  if (currentQuoteHelper.toLowerCase() !== cfg.quoteHelper.toLowerCase()) {
    console.log("\n[2] quoteHelper 不一致，admin setQuoteHelper...");
    console.log("    current:", currentQuoteHelper);
    console.log("    target: ", cfg.quoteHelper);
    const txQh = await factory.setQuoteHelper(cfg.quoteHelper);
    await txQh.wait();
    console.log("[2] setQuoteHelper 完成");
  } else {
    console.log("\n[2] quoteHelper 已是目标地址");
  }

  await maybeSetCardFactoryAaFactory(ethers, factoryAddress, net.chainId);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
