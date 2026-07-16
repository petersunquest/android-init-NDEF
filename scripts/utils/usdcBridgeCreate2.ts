import { Interface } from "ethers";
import {
  buildErc1967ProxyInitCode,
  nickCreate2DeployCalldata,
  predictCreate2,
} from "./erc20UupsCreate2.js";

export { nickCreate2DeployCalldata, predictCreate2 };

export type UsdcBridgeUupsStack = {
  impl: string;
  proxy: string;
  implInitCode: string;
  proxyInitCode: string;
};

export async function predictUsdcBridgeUupsStack(params: {
  ethers: {
    getContractFactory: (
      name: string
    ) => Promise<{
      getDeployTransaction: () => Promise<{ data?: string }>;
    }>;
  };
  nickFactory: string;
  implSalt: string;
  proxySalt: string;
  initialOwner: string;
  conetTreasuryTokenRegistry: string;
}): Promise<UsdcBridgeUupsStack> {
  const factory = await params.ethers.getContractFactory("UsdcBridgeTreasury");
  const implInitCode = (await factory.getDeployTransaction()).data;
  if (!implInitCode) throw new Error("UsdcBridgeTreasury implementation init code missing");
  const impl = predictCreate2(params.nickFactory, params.implSalt, implInitCode);
  const iface = new Interface(["function initialize(address initialOwner,address conetTreasuryTokenRegistry)"]);
  const initializeCalldata = iface.encodeFunctionData("initialize", [
    params.initialOwner,
    params.conetTreasuryTokenRegistry,
  ]);
  const proxyInitCode = buildErc1967ProxyInitCode(impl, initializeCalldata);
  const proxy = predictCreate2(params.nickFactory, params.proxySalt, proxyInitCode);
  return { impl, proxy, implInitCode, proxyInitCode };
}

