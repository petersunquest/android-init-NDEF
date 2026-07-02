/**
 * ERC20 UUPS CREATE2 部署辅助（Nick factory + impl/proxy 双阶段）。
 */
import { AbiCoder, concat, getAddress, Interface, keccak256, solidityPacked } from "ethers";
import ERC1967ProxyArtifact from "@openzeppelin/contracts/build/contracts/ERC1967Proxy.json" with { type: "json" };

export function predictCreate2(factory: string, salt: string, initCode: string): string {
  return getAddress(
    "0x" +
      keccak256(
        solidityPacked(
          ["bytes1", "address", "bytes32", "bytes32"],
          ["0xff", getAddress(factory), salt, keccak256(initCode)]
        )
      ).slice(-40)
  );
}

export function nickCreate2DeployCalldata(salt: string, initCode: string): string {
  return concat([salt, initCode]);
}

export function buildErc1967ProxyInitCode(implementation: string, initializeCalldata: string): string {
  const encodedArgs = AbiCoder.defaultAbiCoder().encode(
    ["address", "bytes"],
    [getAddress(implementation), initializeCalldata]
  );
  return concat([ERC1967ProxyArtifact.bytecode, encodedArgs]);
}

export type Erc20UupsStack = {
  impl: string;
  proxy: string;
  implInitCode: string;
  proxyInitCode: string;
};

export async function predictErc20UupsStack(params: {
  ethers: { getContractFactory: (name: string) => Promise<{ getDeployTransaction: (...args: unknown[]) => Promise<{ data?: string }> }> };
  nickFactory: string;
  implSalt: string;
  proxySalt: string;
  contractName: string;
  encodeInitialize: (iface: Interface) => string;
}): Promise<Erc20UupsStack> {
  const implFactory = await params.ethers.getContractFactory(params.contractName);
  const implInitCode = (await implFactory.getDeployTransaction()).data!;
  const impl = predictCreate2(params.nickFactory, params.implSalt, implInitCode);

  const iface = new Interface([
    `function initialize(${params.contractName === "FactoryERC20Upgradeable" ? "string,string,uint8,address" : "address"})`,
  ]);
  const initData = params.encodeInitialize(iface);
  const proxyInitCode = buildErc1967ProxyInitCode(impl, initData);
  const proxy = predictCreate2(params.nickFactory, params.proxySalt, proxyInitCode);

  return { impl, proxy, implInitCode, proxyInitCode };
}
