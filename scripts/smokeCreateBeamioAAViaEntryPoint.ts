/**
 * Smoke test: create the configured signer EOA's index-0 BeamioAccount via EntryPoint.handleOps.
 *
 * This sends a real UserOperation through BeamioFactoryPaymasterV07.relayHandleOps.
 *
 * Usage:
 *   npx hardhat run scripts/smokeCreateBeamioAAViaEntryPoint.ts --network conet
 */
import { network as networkModule } from "hardhat";
import { getAddress } from "ethers";
import { BEAMIO_AA_FACTORY_PREDICTED } from "./aaDeployConstants.js";

function packUints128(low: bigint, high: bigint, ethers: Awaited<ReturnType<typeof networkModule.connect>>["ethers"]): string {
  return ethers.toBeHex((high << 128n) | low, 32);
}

function paymasterAndData(factory: string, ethers: Awaited<ReturnType<typeof networkModule.connect>>["ethers"]): string {
  return (
    "0x" +
    ethers.zeroPadValue(getAddress(factory), 20).slice(2) +
    ethers.toBeHex(4_000_000n, 16).slice(2) +
    ethers.toBeHex(100_000n, 16).slice(2)
  );
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("No configured signer");

  const eoa = getAddress(await signer.getAddress());
  const factoryAddress = getAddress(process.env.BEAMIO_AA_FACTORY || BEAMIO_AA_FACTORY_PREDICTED);
  const factoryAbi = [
    "function getAddress(address,uint256) view returns(address)",
    "function ENTRY_POINT() view returns(address)",
    "function relayHandleOps(tuple(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature)[] ops,address payable beneficiary) external",
  ];
  const entryPointAbi = [
    "function getNonce(address sender,uint192 key) view returns(uint256)",
    "function getUserOpHash(tuple(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature) op) view returns(bytes32)",
  ];

  const factory = new ethers.Contract(factoryAddress, factoryAbi, signer);
  const getAddressFn = factory.getFunction("getAddress(address,uint256)");
  const aa = getAddress(await getAddressFn(eoa, 0n));
  const code = await ethers.provider.getCode(aa);
  console.log("factory:", factoryAddress);
  console.log("eoa:", eoa);
  console.log("aa:", aa);
  if (code && code !== "0x" && code.length > 2) {
    console.log("AA already deployed; smoke creation skipped");
    return;
  }

  const entryPointAddress = getAddress(await factory.ENTRY_POINT());
  const entryPoint = new ethers.Contract(entryPointAddress, entryPointAbi, ethers.provider);
  const factoryIface = new ethers.Interface([
    "function createAccountForEntryPoint(address creator) returns(address)",
  ]);
  const accountIface = new ethers.Interface([
    "function executeBatch(address[] dest,uint256[] value,bytes[] func)",
  ]);
  const initCode = ethers.concat([
    ethers.zeroPadValue(factoryAddress, 20),
    factoryIface.encodeFunctionData("createAccountForEntryPoint", [eoa]),
  ]);
  const callData = accountIface.encodeFunctionData("executeBatch", [[], [], []]);
  const nonce = await entryPoint.getNonce(aa, 0n);
  const fee = await ethers.provider.getFeeData();
  const maxFeePerGas = fee.maxFeePerGas ?? 2_000_000_000n;
  const maxPriorityFeePerGas = fee.maxPriorityFeePerGas ?? 100_000_000n;
  const userOp = {
    sender: aa,
    nonce,
    initCode,
    callData,
    accountGasLimits: packUints128(8_000_000n, 8_000_000n, ethers),
    preVerificationGas: 300_000n,
    gasFees: packUints128(maxPriorityFeePerGas, maxFeePerGas, ethers),
    paymasterAndData: paymasterAndData(factoryAddress, ethers),
    signature: "0x",
  };
  const userOpHash = await entryPoint.getUserOpHash(userOp);
  const signature = await signer.signMessage(ethers.getBytes(userOpHash));
  const signedUserOp = { ...userOp, signature };
  console.log("entryPoint:", entryPointAddress);
  console.log("userOpHash:", userOpHash);
  const tx = await factory.relayHandleOps([signedUserOp], eoa, { gasLimit: 20_000_000n });
  console.log("tx:", tx.hash);
  await tx.wait();
  const codeAfter = await ethers.provider.getCode(aa);
  if (!codeAfter || codeAfter === "0x" || codeAfter.length <= 2) {
    throw new Error("AA code missing after handleOps");
  }
  console.log("done: AA deployed via EntryPoint");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
