/**
 * BeamioUserCard 链接库：Formatting（uri 拼接）与 Transfer（AA/转账统计等）。
 * 部署卡前须先部署两库并在 getContractFactory("BeamioUserCard", { libraries }) 中传入地址。
 *
 * Hardhat 3：须传入 `const { ethers } = await networkModule.connect()`，勿从 `"hardhat"` 静态 import ethers。
 */
import type { Signer } from "ethers";

export type BeamioUserCardLibraryAddresses = {
  BeamioUserCardFormattingLib: string;
  BeamioUserCardTransferLib: string;
};

export type BeamioUserCardLibraryDeployResult = BeamioUserCardLibraryAddresses & {
  formattingDeployTxHash?: string;
  transferDeployTxHash?: string;
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
  getContractFactory(name: string): Promise<LibFactory>;
};

export async function deployBeamioUserCardLibraries(
  ethers: EthersLike,
  deployer: Signer
): Promise<BeamioUserCardLibraryDeployResult> {
  const Formatting = await ethers.getContractFactory("BeamioUserCardFormattingLib");
  const f = await Formatting.connect(deployer).deploy();
  await f.waitForDeployment();

  const Transfer = await ethers.getContractFactory("BeamioUserCardTransferLib");
  const t = await Transfer.connect(deployer).deploy();
  await t.waitForDeployment();

  return {
    BeamioUserCardFormattingLib: await f.getAddress(),
    BeamioUserCardTransferLib: await t.getAddress(),
    formattingDeployTxHash: f.deploymentTransaction()?.hash,
    transferDeployTxHash: t.deploymentTransaction()?.hash,
  };
}

export function beamioUserCardFactoryLibraries(libs: BeamioUserCardLibraryAddresses) {
  return { libraries: libs };
}
