/**
 * 部署 BusinessStartKetRedeem 到 CoNET：授权 Ket + BUint mint，BUint.addAdmin(本合约)，并为 settle 钱包 addRedeemAdmin。
 *
 * 运行: npx hardhat run scripts/deployBusinessStartKetRedeemToConet.ts --network conet
 *
 * 读取 deployments/conet-addresses.json 的 BusinessStartKet、BUint。
 * 前置: 部署账号须为 BusinessStartKet admin；且须为 BeamioBUnits admin（否则需事后由 BUint admin 执行 addAdmin(redeem)）。
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";
import { mergeConetAdminPrivateKeysFromMasterFile } from "./utils/conetMasterAdmins.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function loadMasterSetup(): { settle_contractAdmin: string[] } {
  const pks = mergeConetAdminPrivateKeysFromMasterFile();
  if (!pks.length) {
    throw new Error("~/.master.json 中无有效私钥（settle_contractAdmin / beamio_Admins / admin）");
  }
  return { settle_contractAdmin: pks };
}

async function main() {
  const { ethers: ethersHH } = await networkModule.connect();
  const [deployer] = await ethersHH.getSigners();
  const net = await ethersHH.provider.getNetwork();
  const master = loadMasterSetup();

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const addrPath = path.join(deploymentsDir, "conet-addresses.json");
  if (!fs.existsSync(addrPath)) throw new Error("缺少 deployments/conet-addresses.json");
  const addrData = JSON.parse(fs.readFileSync(addrPath, "utf-8"));
  const ketAddr = addrData.BusinessStartKet as string | undefined;
  const buintAddr = addrData.BUint as string | undefined;
  if (!ketAddr || !ethers.isAddress(ketAddr)) throw new Error("conet-addresses.json 缺少 BusinessStartKet");
  if (!buintAddr || !ethers.isAddress(buintAddr)) throw new Error("conet-addresses.json 缺少 BUint");

  const settleAddresses = master.settle_contractAdmin.map((pk: string) => new ethers.Wallet(pk).address);
  const uniqueSettle = [...new Set(settleAddresses.map((a) => ethers.getAddress(a)))];

  console.log("=".repeat(60));
  console.log("Deploy BusinessStartKetRedeem on CoNET");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("chainId:", net.chainId.toString());
  console.log("BusinessStartKet:", ketAddr);
  console.log("BUint:", buintAddr);
  const balance = await ethersHH.provider.getBalance(deployer.address);
  console.log("balance:", ethers.formatEther(balance), "CNET\n");

  const Factory = await ethersHH.getContractFactory("BusinessStartKetRedeem");
  const redeem = await Factory.deploy(ketAddr, buintAddr, deployer.address);
  await redeem.waitForDeployment();
  const redeemAddr = await redeem.getAddress();
  console.log("BusinessStartKetRedeem deployed:", redeemAddr);

  const ketAbi = ["function admins(address) view returns (bool)", "function addAdmin(address) external"] as const;
  const buintAbi = ["function admins(address) view returns (bool)", "function addAdmin(address) external"] as const;
  const redeemAbi = ["function redeemAdmins(address) view returns (bool)", "function addRedeemAdmin(address) external"] as const;

  const ketWrite = new ethers.Contract(ketAddr, ketAbi, deployer);
  const buintWrite = new ethers.Contract(buintAddr, buintAbi, deployer);
  const redeemWrite = new ethers.Contract(redeemAddr, redeemAbi, deployer);

  if (!(await ketWrite.admins(redeemAddr))) {
    console.log("[1] BusinessStartKet.addAdmin(redeem)…");
    const tx = await ketWrite.addAdmin(redeemAddr);
    await tx.wait();
    console.log("  ok");
  } else {
    console.log("[1] BusinessStartKet: redeem already admin");
  }

  if (!(await buintWrite.admins(redeemAddr))) {
    console.log("[2] BeamioBUnits.addAdmin(redeem)…");
    try {
      const tx2 = await buintWrite.addAdmin(redeemAddr);
      await tx2.wait();
      console.log("  ok");
    } catch (e: unknown) {
      console.error(
        "  FAILED —当前部署者可能不是 BUint admin。请用已有 admin 执行: BUint.addAdmin(" + redeemAddr + ")"
      );
      throw e;
    }
  } else {
    console.log("[2] BUint: redeem already admin");
  }

  for (const addr of uniqueSettle) {
    if ((await redeemWrite.redeemAdmins(addr))) {
      console.log("already redeemAdmin:", addr);
      continue;
    }
    const tx = await redeemWrite.addRedeemAdmin(addr);
    await tx.wait();
    console.log("addRedeemAdmin ok:", addr);
  }

  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    deployer: deployer.address,
    settle_contractAdmin: uniqueSettle,
    constructorArgs: {
      ket: ethers.getAddress(ketAddr),
      buint: ethers.getAddress(buintAddr),
      initialRedeemAdmin: deployer.address,
    },
    timestamp: new Date().toISOString(),
    contracts: {
      BusinessStartKetRedeem: {
        address: redeemAddr,
        ket: ethers.getAddress(ketAddr),
        buint: ethers.getAddress(buintAddr),
        transactionHash: redeem.deploymentTransaction()?.hash ?? "",
      },
    },
  };

  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });
  const outPath = path.join(deploymentsDir, "conet-BusinessStartKetRedeem.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("\nsaved:", outPath);

  addrData.BusinessStartKetRedeem = redeemAddr;
  fs.writeFileSync(addrPath, JSON.stringify(addrData, null, 2) + "\n", "utf-8");
  console.log("updated conet-addresses.json BusinessStartKetRedeem:", redeemAddr);
  console.log("\n下一步: npx hardhat run scripts/verifyBusinessStartKetRedeemConet.ts --network conet");
  console.log("并同步 src/x402sdk/src/chainAddresses.ts CONET_BUSINESS_START_KET_REDEEM");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
