/**
 * Upgrade the already deployed BUnitAirdropV2 proxy with legacy-compatible
 * claim/purchase methods, then optionally switch ConetTreasury to the proxy.
 *
 * Formal switch requires CONET_V2_SWITCHOVER=1.
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");

async function main() {
  const { ethers: hh } = await networkModule.connect();
  const [signer] = await hh.getSigners();
  const net = await hh.provider.getNetwork();
  if (net.chainId !== 224422n) throw new Error(`Expected CoNET 224422, got ${net.chainId}`);
  const deployment = JSON.parse(
    fs.readFileSync(path.join(root, "deployments/conet-ReferralRegistryVaultV1-stack.json"), "utf8")
  );
  const addresses = JSON.parse(
    fs.readFileSync(path.join(root, "deployments/conet-addresses.json"), "utf8")
  );
  const proxyAddress = deployment.contracts.BUnitAirdropV2.proxy as string;
  const oldAirdrop = addresses.BUnitAirdrop as string;
  const treasury = deployment.dependencies.treasury as string;

  const ImplFactory = await hh.getContractFactory("BUnitAirdropV2");
  const impl = await ImplFactory.deploy();
  await impl.waitForDeployment();
  const implAddress = await impl.getAddress();
  console.log("new BUnitAirdropV2 implementation:", implAddress);

  const proxy = new ethers.Contract(
    proxyAddress,
    [
      "function upgradeToAndCall(address newImplementation, bytes data)",
      "function setLegacyBunitAirdrop(address legacy)",
      "function setClaimAmount(uint256 amount)",
      "function repairLegacyStorageCounters(uint256,uint256,uint256)",
      "function legacyBunitAirdrop() view returns(address)",
    ],
    signer
  );
  await (await proxy.upgradeToAndCall(implAddress, "0x")).wait();
  await (await proxy.setLegacyBunitAirdrop(oldAirdrop)).wait();
  await (await proxy.setClaimAmount(20_000_000)).wait();
  await (await proxy.repairLegacyStorageCounters(0, 0, 0)).wait();
  console.log("proxy upgraded and legacy claim guard configured:", oldAirdrop);

  if (process.env.CONET_V2_SWITCHOVER !== "1") {
    console.log("Treasury switch skipped. Set CONET_V2_SWITCHOVER=1 for formal switchover.");
  } else {
    const treasuryContract = new ethers.Contract(
      treasury,
      [
        "function bunitAirdrop() view returns(address)",
        "function setBUnitAirdrop(address newAirdrop)",
      ],
      signer
    );
    const current = await treasuryContract.bunitAirdrop();
    if (current.toLowerCase() !== proxyAddress.toLowerCase()) {
      await (await treasuryContract.setBUnitAirdrop(proxyAddress)).wait();
      console.log("ConetTreasury.bunitAirdrop switched:", proxyAddress);
    } else {
      console.log("ConetTreasury already points to V2:", proxyAddress);
    }
  }

  const recordPath = path.join(root, "deployments/conet-ReferralRegistryVaultV1-stack.json");
  deployment.contracts.BUnitAirdropV2.upgradedImplementation = implAddress;
  deployment.contracts.BUnitAirdropV2.upgradeTimestamp = new Date().toISOString();
  deployment.contracts.BUnitAirdropV2.legacyBunitAirdrop = oldAirdrop;
  deployment.switchover = process.env.CONET_V2_SWITCHOVER === "1";
  fs.writeFileSync(recordPath, JSON.stringify(deployment, null, 2) + "\n");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
