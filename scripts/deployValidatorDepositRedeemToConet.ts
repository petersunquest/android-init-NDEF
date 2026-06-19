/**
 * 部署 ValidatorDepositRedeem 到 CoNET。
 *
 * 运行:
 *   npx hardhat run scripts/deployValidatorDepositRedeemToConet.ts --network conet
 *
 * 部署后必须验证:
 *   npx tsx scripts/verifyValidatorDepositRedeemConet.ts
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";
import { mergeConetAdminPrivateKeysFromMasterFile } from "./utils/conetMasterAdmins.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

function loadInitialRedeemAdmin(): string | undefined {
  const env = process.env.VALIDATOR_DEPOSIT_REDEEM_INITIAL_ADMIN?.trim();
  if (env) return env;
  const pks = mergeConetAdminPrivateKeysFromMasterFile();
  if (!pks.length) return undefined;
  return new ethers.Wallet(pks[0]).address;
}

async function main() {
  const { ethers: ethersHH } = await networkModule.connect();
  const [deployer] = await ethersHH.getSigners();
  const net = await ethersHH.provider.getNetwork();
  if (net.chainId !== 224422n) {
    throw new Error(`期望 chainId 224422，当前 ${net.chainId}`);
  }

  const initialRedeemAdminRaw = loadInitialRedeemAdmin() || deployer.address;
  if (!ethers.isAddress(initialRedeemAdminRaw)) {
    throw new Error("VALIDATOR_DEPOSIT_REDEEM_INITIAL_ADMIN 不是有效地址");
  }
  const initialRedeemAdmin = ethers.getAddress(initialRedeemAdminRaw);

  console.log("=".repeat(60));
  console.log("Deploy ValidatorDepositRedeem on CoNET");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("chainId:", net.chainId.toString());
  console.log("initialRedeemAdmin:", initialRedeemAdmin);
  console.log("balance:", ethers.formatEther(await ethersHH.provider.getBalance(deployer.address)), "CNET\n");

  const Factory = await ethersHH.getContractFactory("ValidatorDepositRedeem");
  const redeem = await Factory.deploy(initialRedeemAdmin);
  await redeem.waitForDeployment();
  const redeemAddr = await redeem.getAddress();
  const txHash = redeem.deploymentTransaction()?.hash ?? "";

  console.log("ValidatorDepositRedeem deployed:", redeemAddr);
  console.log("tx:", txHash);

  const deploymentsDir = path.join(root, "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    contract: "ValidatorDepositRedeem",
    source: "src/mainnet/ValidatorDepositRedeem.sol",
    address: redeemAddr,
    deployer: deployer.address,
    initialRedeemAdmin,
    constructorArgs: {
      initialRedeemAdmin,
    },
    timestamp: new Date().toISOString(),
    transactionHash: txHash,
    contracts: {
      ValidatorDepositRedeem: {
        address: redeemAddr,
        initialRedeemAdmin,
        transactionHash: txHash,
      },
    },
  };

  const outPath = path.join(deploymentsDir, "conet-ValidatorDepositRedeem.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("saved:", outPath);

  const addrPath = path.join(deploymentsDir, "conet-addresses.json");
  if (fs.existsSync(addrPath)) {
    const addrData = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, unknown>;
    addrData.ValidatorDepositRedeem = redeemAddr;
    addrData.validatorDepositRedeemDeployer = deployer.address;
    addrData.validatorDepositRedeemDeployedAt = new Date().toISOString();
    addrData.validatorDepositRedeemTx = txHash;
    fs.writeFileSync(addrPath, JSON.stringify(addrData, null, 2) + "\n", "utf-8");
    console.log("updated deployments/conet-addresses.json ValidatorDepositRedeem:", redeemAddr);
  }

  console.log("\n下一步（必须）: npx tsx scripts/verifyValidatorDepositRedeemConet.ts");
  console.log("然后同步 src/x402sdk/src/chainAddresses.ts CONET_VALIDATOR_DEPOSIT_REDEEM");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
