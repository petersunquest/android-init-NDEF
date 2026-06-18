/**
 * Deploy the EntryPoint-aware Beamio AA stack on the selected chain.
 *
 * Steps:
 * 1. Deploy BeamioContainerModuleExternalLibV07.
 * 2. Deploy BeamioContainerModuleExternalLib2V07.
 * 3. Deploy BeamioContainerModuleV07 linked to those libraries.
 * 4. Deploy BeamioFactoryPaymasterV07 via Nick CREATE2 at the current predicted address.
 * 5. Initialize the factory chain config to the freshly deployed module.
 * 6. Add configured signer accounts as AA Factory paymasters.
 * 7. Update deployment address JSON for the selected chain.
 *
 * Usage:
 *   npx hardhat run scripts/deployBeamioAAEntryPointStack.ts --network conet
 *   npx hardhat run scripts/deployBeamioAAEntryPointStack.ts --network base
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { concat, getAddress } from "ethers";
import {
  BEAMIO_AA_FACTORY_ADMIN,
  BEAMIO_AA_FACTORY_CREATE2_SALT,
  BEAMIO_AA_FACTORY_INITIAL_ACCOUNT_LIMIT,
  BEAMIO_AA_FACTORY_PREDICTED,
  NICK_CREATE2_FACTORY,
} from "./aaDeployConstants.js";
import { BEAMIO_QUOTE_HELPER_PREDICTED } from "./oracleDeployConstants.js";
import { resolveBaseCardFactoryAddress } from "./readCanonicalBaseCardFactory.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");
const DEPLOYMENTS = path.join(ROOT, "deployments");
const CONFIG = path.join(ROOT, "config");
const BASE_CHAIN_ID = 8453n;
const CONET_CHAIN_ID = 224422n;

type ChainConfig = {
  quoteHelper: string;
  userCard: string;
  usdc: string;
  cardFactory?: string;
};

function readJson(pathname: string): Record<string, any> {
  if (!fs.existsSync(pathname)) return {};
  return JSON.parse(fs.readFileSync(pathname, "utf-8"));
}

function writeJson(pathname: string, value: unknown): void {
  fs.mkdirSync(path.dirname(pathname), { recursive: true });
  fs.writeFileSync(pathname, JSON.stringify(value, null, 2) + "\n", "utf-8");
}

function resolveChainConfig(chainId: bigint): ChainConfig {
  const fromEnv = (key: string): string | undefined => {
    const v = process.env[key];
    return v ? getAddress(v) : undefined;
  };

  if (chainId === CONET_CHAIN_ID) {
    const conet = readJson(path.join(DEPLOYMENTS, "conet-addresses.json"));
    return {
      quoteHelper:
        fromEnv("AA_QUOTE_HELPER") ??
        getAddress(String(conet.beamioQuoteHelperV07 ?? "0xD3f275774831810006d744d32E6b024507C0d374")),
      userCard:
        fromEnv("AA_USER_CARD") ??
        getAddress(String(conet.BEAMIO_USER_CARD_DEFAULT ?? "0xA5C727d11d04BeBC095bd814c6530c4e77fD6662")),
      usdc:
        fromEnv("AA_USDC") ??
        getAddress(String(conet.conetUsdc ?? "0x40E302aBC19f6c9f376D7Dee037192a7a203e3Aa")),
      cardFactory:
        fromEnv("CARD_FACTORY") ??
        (conet.CARD_FACTORY ? getAddress(String(conet.CARD_FACTORY)) : undefined),
    };
  }

  if (chainId === BASE_CHAIN_ID) {
    const base = readJson(path.join(CONFIG, "base-addresses.json"));
    return {
      quoteHelper:
        fromEnv("AA_QUOTE_HELPER") ??
        (BEAMIO_QUOTE_HELPER_PREDICTED !== "0x0000000000000000000000000000000000000000"
          ? BEAMIO_QUOTE_HELPER_PREDICTED
          : getAddress(String(base.BEAMIO_QUOTE_HELPER_V07 ?? "0xfa30c2086ff9a3D74576d55c2027586797A52F29"))),
      userCard:
        fromEnv("AA_USER_CARD") ??
        getAddress(String(base.BEAMIO_USER_CARD_ASSET_ADDRESS ?? "0xBCcfA50d2a5917C7A8662177F5F4B7A175787270")),
      usdc:
        fromEnv("AA_USDC") ??
        getAddress(String(base.USDC_BASE ?? "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")),
      cardFactory: fromEnv("CARD_FACTORY") ?? resolveBaseCardFactoryAddress(DEPLOYMENTS),
    };
  }

  throw new Error(`Unsupported chainId ${chainId.toString()}`);
}

function nickCreate2DeployCalldata(salt: string, initCode: string): string {
  return concat([salt, initCode]);
}

async function deployContract(
  ethers: Awaited<ReturnType<typeof networkModule.connect>>["ethers"],
  deployer: any,
  name: string,
  args: readonly unknown[] = [],
  libraries?: Record<string, string>
): Promise<any> {
  const factory = await ethers.getContractFactory(name, libraries ? { libraries } : undefined);
  const contract = await factory.connect(deployer).deploy(...args);
  await contract.waitForDeployment();
  const address = getAddress(await contract.getAddress());
  console.log(`✅ ${name}: ${address}`);
  return contract;
}

async function deployFactoryViaCreate2(
  ethers: Awaited<ReturnType<typeof networkModule.connect>>["ethers"],
  deployer: any
): Promise<{ address: string; txHash?: string; initCodeHash: string; nickFactory: string }> {
  const nickFactory = getAddress(process.env.BEAMIO_AA_CREATE2_FACTORY || NICK_CREATE2_FACTORY);
  const aaFactory = await ethers.getContractFactory("BeamioFactoryPaymasterV07");
  const deployTx = await aaFactory.getDeployTransaction(
    BEAMIO_AA_FACTORY_INITIAL_ACCOUNT_LIMIT,
    BEAMIO_AA_FACTORY_ADMIN
  );
  if (!deployTx.data) throw new Error("Unable to build BeamioFactoryPaymasterV07 initCode");
  const initCodeHash = ethers.keccak256(deployTx.data);

  const predicted = getAddress(
    "0x" +
      ethers
        .keccak256(
          ethers.solidityPacked(
            ["bytes1", "address", "bytes32", "bytes32"],
            ["0xff", nickFactory, BEAMIO_AA_FACTORY_CREATE2_SALT, initCodeHash]
          )
        )
        .slice(-40)
  );

  if (predicted.toLowerCase() !== BEAMIO_AA_FACTORY_PREDICTED.toLowerCase()) {
    throw new Error(`Predicted mismatch: computed=${predicted}, constant=${BEAMIO_AA_FACTORY_PREDICTED}`);
  }

  const code = await ethers.provider.getCode(predicted);
  if (code !== "0x" && code.length > 2) {
    console.log(`✅ BeamioFactoryPaymasterV07 already exists: ${predicted}`);
    return { address: predicted, initCodeHash, nickFactory };
  }

  const nickCode = await ethers.provider.getCode(nickFactory);
  if (nickCode === "0x" || nickCode.length <= 2) {
    throw new Error(`Nick CREATE2 factory has no code: ${nickFactory}`);
  }

  const data = nickCreate2DeployCalldata(BEAMIO_AA_FACTORY_CREATE2_SALT, deployTx.data);
  let gasLimit = 15_000_000n;
  try {
    gasLimit = ((await deployer.estimateGas({ to: nickFactory, data })) * 120n) / 100n;
  } catch {
    console.warn("estimateGas failed; using gasLimit=15000000");
  }

  const tx = await deployer.sendTransaction({ to: nickFactory, data, gasLimit });
  console.log("CREATE2 deploy tx:", tx.hash);
  await tx.wait();

  const codeAfter = await ethers.provider.getCode(predicted);
  if (codeAfter === "0x" || codeAfter.length <= 2) {
    throw new Error(`CREATE2 deploy failed; no code at ${predicted}`);
  }
  console.log(`✅ BeamioFactoryPaymasterV07: ${predicted}`);
  return { address: predicted, txHash: tx.hash, initCodeHash, nickFactory };
}

async function maybeSetCardFactoryAA(
  ethers: Awaited<ReturnType<typeof networkModule.connect>>["ethers"],
  signer: any,
  cardFactoryAddress: string | undefined,
  aaFactoryAddress: string
): Promise<void> {
  if (!cardFactoryAddress) return;
  const abi = [
    "function owner() external view returns (address)",
    "function aaFactory() external view returns (address)",
    "function setAAFactory(address f) external",
  ];
  const cardFactory = new ethers.Contract(cardFactoryAddress, abi, signer);
  const owner = getAddress(await cardFactory.owner());
  const signerAddress = getAddress(await signer.getAddress());
  if (owner.toLowerCase() !== signerAddress.toLowerCase()) {
    console.log(`[card factory] signer is not owner; skip setAAFactory. owner=${owner}, signer=${signerAddress}`);
    return;
  }
  const current = getAddress(await cardFactory.aaFactory());
  if (current.toLowerCase() === aaFactoryAddress.toLowerCase()) {
    console.log("[card factory] aaFactory already set");
    return;
  }
  const tx = await cardFactory.setAAFactory(aaFactoryAddress);
  console.log("[card factory] setAAFactory tx:", tx.hash);
  await tx.wait();
  console.log("[card factory] setAAFactory done");
}

async function addPaymasters(
  ethers: Awaited<ReturnType<typeof networkModule.connect>>["ethers"],
  adminSigner: any,
  factoryAddress: string,
  signers: any[]
): Promise<void> {
  const factory = await ethers.getContractAt("BeamioFactoryPaymasterV07", factoryAddress, adminSigner);
  const admin = getAddress(await factory.admin());
  const signerAddress = getAddress(await adminSigner.getAddress());
  if (admin.toLowerCase() !== signerAddress.toLowerCase()) {
    console.log(`[paymaster] signer is not factory admin; skip addPayMaster. admin=${admin}, signer=${signerAddress}`);
    return;
  }

  const addresses = Array.from(
    new Set(
      await Promise.all(signers.map(async (s) => getAddress(await s.getAddress())))
    )
  );
  for (const address of addresses) {
    const already = await factory.isPayMaster(address);
    if (already) {
      console.log(`[paymaster] already enabled: ${address}`);
      continue;
    }
    const tx = await factory.addPayMaster(address);
    console.log(`[paymaster] add ${address}: ${tx.hash}`);
    await tx.wait();
  }
}

function updateAddressFiles(chainId: bigint, netName: string, values: Record<string, string>): void {
  if (chainId === CONET_CHAIN_ID) {
    const p = path.join(DEPLOYMENTS, "conet-addresses.json");
    const conet = readJson(p);
    Object.assign(conet, {
      AA_FACTORY: values.aaFactory,
      beamioContainerModule: values.module,
      beamioContainerExtLibV07: values.lib1,
      beamioContainerExtLib2V07: values.lib2,
    });
    writeJson(p, conet);
    console.log("updated:", p);
  }

  if (chainId === BASE_CHAIN_ID) {
    const p = path.join(CONFIG, "base-addresses.json");
    const base = readJson(p);
    base.AA_FACTORY = values.aaFactory;
    writeJson(p, base);
    console.log("updated:", p);
  }

  const stackPath = path.join(DEPLOYMENTS, `${netName}-ContainerModuleStack.json`);
  writeJson(stackPath, {
    network: netName,
    chainId: chainId.toString(),
    updatedAt: new Date().toISOString(),
    contracts: {
      BeamioContainerExtLibV07: { address: values.lib1 },
      BeamioContainerExtLib2V07: { address: values.lib2 },
      BeamioContainerModuleV07: {
        address: values.module,
        linkedLibraries: {
          BeamioContainerModuleExternalLibV07: values.lib1,
          BeamioContainerModuleExternalLib2V07: values.lib2,
        },
      },
      BeamioFactoryPaymasterV07: { address: values.aaFactory },
    },
  });
  console.log("updated:", stackPath);
}

async function main() {
  const { ethers } = await networkModule.connect();
  const signers = await ethers.getSigners();
  const [deployer] = signers;
  if (!deployer) throw new Error("No signer configured for this network");

  const net = await ethers.provider.getNetwork();
  const netName = net.chainId === CONET_CHAIN_ID ? "conet" : net.chainId === BASE_CHAIN_ID ? "base" : net.name;
  const cfg = resolveChainConfig(net.chainId);

  console.log("=".repeat(70));
  console.log("Deploy Beamio AA EntryPoint stack");
  console.log("=".repeat(70));
  console.log("network:", netName, `(${net.chainId.toString()})`);
  console.log("deployer:", await deployer.getAddress());
  console.log("AA Factory predicted:", BEAMIO_AA_FACTORY_PREDICTED);
  console.log("quoteHelper:", cfg.quoteHelper);
  console.log("userCard:", cfg.userCard);
  console.log("usdc:", cfg.usdc);

  const lib1 = await deployContract(ethers, deployer, "BeamioContainerModuleExternalLibV07");
  const lib1Address = getAddress(await lib1.getAddress());
  const lib2 = await deployContract(ethers, deployer, "BeamioContainerModuleExternalLib2V07");
  const lib2Address = getAddress(await lib2.getAddress());
  const module = await deployContract(
    ethers,
    deployer,
    "BeamioContainerModuleV07",
    [],
    {
      BeamioContainerModuleExternalLibV07: lib1Address,
      BeamioContainerModuleExternalLib2V07: lib2Address,
    }
  );
  const moduleAddress = getAddress(await module.getAddress());

  const factoryDeployment = await deployFactoryViaCreate2(ethers, deployer);
  const aaFactoryAddress = factoryDeployment.address;
  const factory = await ethers.getContractAt("BeamioFactoryPaymasterV07", aaFactoryAddress, deployer);
  const initialized = await factory.chainConfigInitialized();
  if (!initialized) {
    const tx = await factory.initializeChainConfig(moduleAddress, cfg.quoteHelper, cfg.userCard, cfg.usdc);
    console.log("initializeChainConfig tx:", tx.hash);
    await tx.wait();
  } else {
    console.log("factory chain config already initialized; not changing module");
  }

  await addPaymasters(ethers, deployer, aaFactoryAddress, signers);
  await maybeSetCardFactoryAA(ethers, deployer, cfg.cardFactory, aaFactoryAddress);

  updateAddressFiles(net.chainId, netName, {
    lib1: lib1Address,
    lib2: lib2Address,
    module: moduleAddress,
    aaFactory: aaFactoryAddress,
  });

  const metaPath = path.join(DEPLOYMENTS, "beamioAAFactory-create2-meta.json");
  const meta = readJson(metaPath);
  meta.predictedAddress = aaFactoryAddress;
  meta.admin = BEAMIO_AA_FACTORY_ADMIN;
  meta.accountLimit = BEAMIO_AA_FACTORY_INITIAL_ACCOUNT_LIMIT;
  meta.create2Salt = BEAMIO_AA_FACTORY_CREATE2_SALT;
  meta.initCodeHash = factoryDeployment.initCodeHash;
  meta.nickFactory = factoryDeployment.nickFactory;
  meta.deployments = {
    ...(typeof meta.deployments === "object" && meta.deployments !== null ? meta.deployments : {}),
    [net.chainId.toString()]: aaFactoryAddress,
  };
  meta.updatedAt = new Date().toISOString();
  writeJson(metaPath, meta);

  console.log("\nDone.");
  console.log("Container module:", moduleAddress);
  console.log("AA Factory:", aaFactoryAddress);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
