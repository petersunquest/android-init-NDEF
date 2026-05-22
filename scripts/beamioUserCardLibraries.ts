/**
 * BeamioUserCard 链接库：Formatting（uri 拼接）与 Transfer（AA/转账统计等）。
 * 部署卡前须先部署两库并在 getContractFactory("BeamioUserCard", { libraries }) 中传入地址。
 *
 * Hardhat 3：须传入 `const { ethers } = await networkModule.connect()`，勿从 `"hardhat"` 静态 import ethers。
 */
import type { Signer } from "ethers";

export type BeamioUserCardLibraryAddresses = {
  ReferrerRegistryLib: string;
  BeamioUserCardAdminGatewayLib: string;
  BeamioUserCardFaucetGatewayLib: string;
  BeamioUserCardFormattingLib: string;
  BeamioUserCardGatewayMintLib: string;
  BeamioUserCardGovernanceLib: string;
  BeamioUserCardIssuedNftGatewayLib: string;
  BeamioUserCardModuleRouterLib: string;
  BeamioUserCardRedeemGatewayLib: string;
  BeamioUserCardReferrerLib: string;
  BeamioUserCardTransferLib: string;
  BeamioUserCardUpdateLib: string;
  BeamioUserCardViewsLib: string;
};

export type BeamioUserCardLibraryDeployResult = BeamioUserCardLibraryAddresses & {
  deployTxHashes: Partial<Record<keyof BeamioUserCardLibraryAddresses, string>>;
};

type LibFactory = {
  connect(s: Signer): {
    deploy(): Promise<{
      waitForDeployment(): Promise<void>;
      getAddress(): Promise<string>;
      deploymentTransaction(): { hash?: string } | null;
    }>;
  };
};

type EthersLike = {
  getContractFactory(name: string, options?: { libraries?: Record<string, string> }): Promise<LibFactory>;
};

export const BEAMIO_USER_CARD_LIBRARY_NAMES = [
  "BeamioUserCardFormattingLib",
  "BeamioUserCardTransferLib",
  "BeamioUserCardIssuedNftGatewayLib",
  "ReferrerRegistryLib",
  "BeamioUserCardReferrerLib",
  "BeamioUserCardAdminGatewayLib",
  "BeamioUserCardFaucetGatewayLib",
  "BeamioUserCardGatewayMintLib",
  "BeamioUserCardGovernanceLib",
  "BeamioUserCardModuleRouterLib",
  "BeamioUserCardRedeemGatewayLib",
  "BeamioUserCardUpdateLib",
  "BeamioUserCardViewsLib",
] as const satisfies readonly (keyof BeamioUserCardLibraryAddresses)[];

const LIBRARY_LINK_DEPENDENCIES: Partial<
  Record<keyof BeamioUserCardLibraryAddresses, (keyof BeamioUserCardLibraryAddresses)[]>
> = {
  BeamioUserCardReferrerLib: ["ReferrerRegistryLib"],
  BeamioUserCardRedeemGatewayLib: ["BeamioUserCardIssuedNftGatewayLib", "BeamioUserCardTransferLib"],
  BeamioUserCardUpdateLib: ["BeamioUserCardReferrerLib", "BeamioUserCardTransferLib"],
};

export async function deployBeamioUserCardLibraries(
  ethers: EthersLike,
  deployer: Signer,
  existing: Partial<BeamioUserCardLibraryAddresses> = {}
): Promise<BeamioUserCardLibraryDeployResult> {
  const addresses: Partial<BeamioUserCardLibraryAddresses> = {};
  const deployTxHashes: Partial<Record<keyof BeamioUserCardLibraryAddresses, string>> = {};
  for (const name of BEAMIO_USER_CARD_LIBRARY_NAMES) {
    const reused = existing[name];
    if (reused) {
      addresses[name] = reused;
      continue;
    }
    const deps = LIBRARY_LINK_DEPENDENCIES[name] ?? [];
    const libraries = Object.fromEntries(deps.map((dep) => [dep, addresses[dep] as string]));
    const Factory = await ethers.getContractFactory(name, deps.length > 0 ? { libraries } : undefined);
    const c = await Factory.connect(deployer).deploy();
    await c.waitForDeployment();
    addresses[name] = await c.getAddress();
    deployTxHashes[name] = c.deploymentTransaction()?.hash;
  }

  return {
    ...(addresses as BeamioUserCardLibraryAddresses),
    deployTxHashes,
  };
}

export function beamioUserCardFactoryLibraries(libs: BeamioUserCardLibraryAddresses) {
  return { libraries: libs };
}
