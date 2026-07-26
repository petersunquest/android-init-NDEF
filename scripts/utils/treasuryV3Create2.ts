import { keccak256, getCreate2Address, hexlify, type ContractFactory, type Signer } from "ethers";

export const NICK_CREATE2_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C";

export async function deployViaNick(
  signer: Signer,
  initCode: string,
  salt: string,
  provider: { getCode(address: string): Promise<string> }
): Promise<{ address: string; txHash?: string; reused: boolean }> {
  const predicted = getCreate2Address(NICK_CREATE2_FACTORY, salt, keccak256(initCode));
  const existing = await provider.getCode(predicted);
  if (existing !== "0x") return { address: predicted, reused: true };
  const tx = await signer.sendTransaction({
    to: NICK_CREATE2_FACTORY,
    data: hexlify(`0x${salt.replace(/^0x/, "")}${initCode.replace(/^0x/, "")}`),
  });
  await tx.wait();
  const deployed = await provider.getCode(predicted);
  if (deployed === "0x") throw new Error(`CREATE2 deployment produced no code at ${predicted}`);
  return { address: predicted, txHash: tx.hash, reused: false };
}

export function saltFromLabel(ethersLike: { id(label: string): string }, label: string): string {
  return ethersLike.id(`beamio.treasury.v3.${label}`);
}

export async function initCodeFor(
  factory: ContractFactory,
  ...args: unknown[]
): Promise<string> {
  const tx = await factory.getDeployTransaction(...args);
  if (!tx.data) throw new Error("factory returned no init code");
  return tx.data.toString();
}
