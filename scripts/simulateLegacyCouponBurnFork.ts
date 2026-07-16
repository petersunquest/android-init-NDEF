/**
 * Fork CoNET: deploy IssuedNftModuleV2 (legacy burn fallback), bind factory, simulate POS burn.
 *
 *   npx hardhat run scripts/simulateLegacyCouponBurnFork.ts --network hardhat
 */
import { network as networkModule } from "hardhat";

const CARD = "0xB24D242A320b8dd756572b410645FE41Cd07FC8C";
const FACTORY = "0xfA52a0CcC96C19cF4b6Ea864615F6d52BD0774FB";
const HOLDER_AA = "0x0f8415369D20bf1002E9C649693dd0c18e7b2d58";
const TOKEN_ID = 100_000_000_001n;

async function main() {
  const { ethers } = await networkModule.connect();
  const provider = ethers.provider;

  await provider.send("hardhat_reset", [
    { forking: { jsonRpcUrl: process.env.CONET_RPC?.trim() || "https://publicrpc.conet.network" } },
  ]);

  const [deployer] = await ethers.getSigners();
  const factoryAbi = [
    "function owner() view returns (address)",
    "function defaultIssuedNftModule() view returns (address)",
    "function setIssuedNftModule(address m) external",
  ];
  const factory = new ethers.Contract(FACTORY, factoryAbi, provider);
  const owner = await factory.owner();
  await provider.send("hardhat_setBalance", [owner, "0x" + (10n ** 20n).toString(16)]);
  await provider.send("hardhat_impersonateAccount", [owner]);
  const ownerSigner = await ethers.getSigner(owner);

  const IssuedFac = await ethers.getContractFactory("BeamioUserCardIssuedNftModuleV2");
  const issued = await IssuedFac.connect(deployer).deploy();
  await issued.waitForDeployment();
  const newMod = await issued.getAddress();
  console.log("deployed IssuedNftModuleV2", newMod);

  await (await factory.connect(ownerSigner).setIssuedNftModule(newMod)).wait();
  console.log("factory.defaultIssuedNftModule", await factory.defaultIssuedNftModule());

  const card = new ethers.Contract(
    CARD,
    ["function balanceOf(address,uint256) view returns (uint256)", "function burnIssuedNftByGateway(address,uint256,uint256)"],
    provider,
  );
  const balBefore = (await card.balanceOf(HOLDER_AA, TOKEN_ID)) as bigint;
  console.log("balance before", balBefore.toString());

  const data = card.interface.encodeFunctionData("burnIssuedNftByGateway", [HOLDER_AA, TOKEN_ID, 1n]);
  await provider.send("hardhat_impersonateAccount", [FACTORY]);
  const factorySigner = await ethers.getSigner(FACTORY);
  await factorySigner.sendTransaction({ to: CARD, data });

  const balAfter = (await card.balanceOf(HOLDER_AA, TOKEN_ID)) as bigint;
  console.log("balance after", balAfter.toString());
  if (balAfter !== balBefore - 1n) {
    throw new Error(`expected burn ${balBefore} -> ${balBefore - 1n}, got ${balAfter}`);
  }
  console.log("OK legacy card POS burn simulation passed");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
