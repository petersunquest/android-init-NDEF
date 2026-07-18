/**
 * Deploy the strict-isolation CoNET stack:
 *   ReferralRegistryVaultV1 (ERC1967 proxy)
 *   BUnitAirdropV2 (ERC1967 proxy)
 *
 * This script configures new permissions but does not switch ConetTreasury or
 * x402sdk to the new airdrop unless CONET_V2_SWITCHOVER=1 is explicitly set.
 * That prevents a partial application rollout from breaking the live API.
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";
import ERC1967ProxyArtifact from "@openzeppelin/contracts/build/contracts/ERC1967Proxy.json" with { type: "json" };
import { mergeConetAdminPrivateKeysFromMasterFile } from "./utils/conetMasterAdmins.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");
const ADDRESSES_PATH = path.join(root, "deployments", "conet-addresses.json");

function loadAddresses(): Record<string, string> {
  return JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf8")) as Record<string, string>;
}

function uniqueAddresses(privateKeys: string[]): string[] {
  return [...new Set(privateKeys.map((pk) => ethers.getAddress(new ethers.Wallet(pk).address)))];
}

async function deployProxy(
  ethersHH: Awaited<ReturnType<typeof networkModule.connect>>["ethers"],
  deployer: Awaited<ReturnType<typeof ethersHH.getSigners>>[number],
  contractName: string,
  initializeArgs: readonly unknown[]
): Promise<{ proxy: string; implementation: string; tx: string; block: number }> {
  const ImplFactory = await ethersHH.getContractFactory(contractName);
  const impl = await ImplFactory.deploy();
  await impl.waitForDeployment();
  const implAddress = await impl.getAddress();
  const initData = ImplFactory.interface.encodeFunctionData("initialize", initializeArgs as any[]);
  const proxyFactory = new ethers.ContractFactory(
    ERC1967ProxyArtifact.abi,
    ERC1967ProxyArtifact.bytecode,
    deployer
  );
  const proxy = await proxyFactory.deploy(implAddress, initData);
  await proxy.waitForDeployment();
  const proxyAddress = await proxy.getAddress();
  const receipt = await proxy.deploymentTransaction()?.wait();
  return {
    proxy: proxyAddress,
    implementation: implAddress,
    tx: proxy.deploymentTransaction()?.hash ?? "",
    block: Number(receipt?.blockNumber ?? 0),
  };
}

async function main() {
  const { ethers: ethersHH } = await networkModule.connect();
  const [deployer] = await ethersHH.getSigners();
  if (!deployer) throw new Error("No CoNET deployer signer");
  const net = await ethersHH.provider.getNetwork();
  if (net.chainId !== 224422n) throw new Error(`Expected CoNET 224422, got ${net.chainId}`);

  const addresses = loadAddresses();
  const bunit = ethers.getAddress(process.env.BUINT_ADDRESS ?? addresses.BUint);
  const treasury = ethers.getAddress(process.env.CONET_TREASURY_ADDRESS ?? addresses.ConetTreasury);
  const conetUsdc = ethers.getAddress(process.env.CONET_USDC_ADDRESS ?? addresses.conetUsdc);
  const businessStartKet = ethers.getAddress(
    process.env.BUSINESS_START_KET_ADDRESS ?? addresses.BusinessStartKet
  );
  const userCardFactory = ethers.getAddress(
    process.env.CONET_CARD_FACTORY_ADDRESS ?? addresses.CARD_FACTORY
  );
  const admins = uniqueAddresses(mergeConetAdminPrivateKeysFromMasterFile());
  const owner = ethers.getAddress(process.env.REFERRAL_VAULT_OWNER ?? deployer.address);

  console.log("Deploying strict CoNET referral stack");
  console.log({ chainId: net.chainId.toString(), deployer: deployer.address, owner });
  console.log({ bunit, treasury, conetUsdc, businessStartKet, userCardFactory });

  // Referral is deployed first with a temporary airdrop address, then rewired
  // after BUnitAirdropV2 has its canonical proxy address.
  const referral = await deployProxy(
    ethersHH,
    deployer,
    "ReferralRegistryVaultV1",
    [owner, businessStartKet, deployer.address, userCardFactory, conetUsdc]
  );
  console.log("ReferralRegistryVaultV1 proxy:", referral.proxy);
  console.log("ReferralRegistryVaultV1 implementation:", referral.implementation);

  const airdrop = await deployProxy(
    ethersHH,
    deployer,
    "BUnitAirdropV2",
    [owner, bunit, treasury, conetUsdc, referral.proxy]
  );
  console.log("BUnitAirdropV2 proxy:", airdrop.proxy);
  console.log("BUnitAirdropV2 implementation:", airdrop.implementation);

  const referralWrite = new ethers.Contract(
    referral.proxy,
    [
      "function setConfig(address,address,address,address)",
      "function setAdmin(address,bool)",
    ],
    deployer
  );
  await (await referralWrite.setConfig(businessStartKet, airdrop.proxy, userCardFactory, conetUsdc)).wait();
  for (const admin of admins) {
    await (await referralWrite.setAdmin(admin, true)).wait();
  }

  const airdropWrite = new ethers.Contract(
    airdrop.proxy,
    ["function setAdmin(address,bool)"],
    deployer
  );
  for (const admin of admins) {
    await (await airdropWrite.setAdmin(admin, true)).wait();
  }

  // New contracts need their own mint/burn permissions. These are explicit,
  // separate transactions so a failed permission grant cannot be mistaken for
  // a completed production switchover.
  const ket = new ethers.Contract(businessStartKet, ["function addAdmin(address)"], deployer);
  await (await ket.addAdmin(referral.proxy)).wait();
  const buint = new ethers.Contract(bunit, ["function addAdmin(address)"], deployer);
  await (await buint.addAdmin(airdrop.proxy)).wait();

  if (process.env.CONET_V2_SWITCHOVER === "1") {
    const treasuryWrite = new ethers.Contract(treasury, ["function setBUnitAirdrop(address)"], deployer);
    await (await treasuryWrite.setBUnitAirdrop(airdrop.proxy)).wait();
    console.log("WARNING: ConetTreasury.bunitAirdrop switched to BUnitAirdropV2");
  } else {
    console.log("Live switchover skipped; set CONET_V2_SWITCHOVER=1 only after API migration.");
  }

  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    timestamp: new Date().toISOString(),
    deployer: deployer.address,
    owner,
    compiler: "0.8.35+commit.47b9dedd",
    contracts: {
      ReferralRegistryVaultV1: {
        proxy: referral.proxy,
        implementation: referral.implementation,
        transactionHash: referral.tx,
        deployBlock: referral.block,
        initializeArgs: [owner, businessStartKet, airdrop.proxy, userCardFactory, conetUsdc],
      },
      BUnitAirdropV2: {
        proxy: airdrop.proxy,
        implementation: airdrop.implementation,
        transactionHash: airdrop.tx,
        deployBlock: airdrop.block,
        initializeArgs: [owner, bunit, treasury, conetUsdc, referral.proxy],
      },
    },
    dependencies: { bunit, treasury, conetUsdc, businessStartKet, userCardFactory },
    configuredAdmins: admins,
    switchover: process.env.CONET_V2_SWITCHOVER === "1",
  };
  const outputPath = path.join(root, "deployments", "conet-ReferralRegistryVaultV1-stack.json");
  fs.writeFileSync(outputPath, JSON.stringify(out, null, 2) + "\n");
  console.log("Deployment record:", outputPath);
  console.log("Next: export FULL Standard JSON, run local bytecode precheck, then verify every impl and proxy.");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
