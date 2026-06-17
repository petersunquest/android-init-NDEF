/**
 * 部署 CoNET GB 栈：ConetGB1155 → ConetGB_total / ConetGB_userTotal。
 *
 * 运行: npx hardhat run scripts/deployConetGBStackToCoet.ts --network conet
 *
 * 环境变量（可选）:
 *   CONET_GB_START_TIME   uint64 秒，须整点对齐；默认 GB_START_TIME（见 gbDeployConstants.ts）
 *   CONET_GB_START_HOUR_ID  默认 GB_START_HOUR_ID
 *   SKIP_GB_TOTAL=1 / SKIP_GB_USER_TOTAL=1  跳过子合约
 *
 * 跨链 CREATE2 同址部署见 PR-2: scripts/deployGBStackCreate2.ts
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import {
  GB_INITIAL_ADMIN,
  GB_START_HOUR_ID,
  GB_START_TIME,
} from "./gbDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

const ADDR_JSON = path.join(root, "deployments", "conet-addresses.json");

function resolveStartTimeSec(): bigint {
  const env = process.env.CONET_GB_START_TIME?.trim();
  if (env) {
    const n = BigInt(env);
    if (n % 3600n !== 0n) throw new Error("CONET_GB_START_TIME 须为整点对齐（% 3600 == 0）");
    return n;
  }
  return GB_START_TIME;
}

function resolveStartHourId(): bigint {
  const env = process.env.CONET_GB_START_HOUR_ID?.trim();
  return env ? BigInt(env) : GB_START_HOUR_ID;
}

function mergeConetAddresses(patch: Record<string, string>): void {
  if (!fs.existsSync(ADDR_JSON)) return;
  const data = JSON.parse(fs.readFileSync(ADDR_JSON, "utf-8")) as Record<string, unknown>;
  Object.assign(data, patch);
  fs.writeFileSync(ADDR_JSON, JSON.stringify(data, null, 2) + "\n", "utf-8");
}

function saveDeployment(name: string, artifact: Record<string, unknown>): void {
  const dir = path.join(root, "deployments");
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  const out = path.join(dir, `conet-${name}.json`);
  fs.writeFileSync(out, JSON.stringify(artifact, null, 2) + "\n", "utf-8");
  console.log("saved:", out);
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  if (!deployer) throw new Error("无签名账户：请配置 ~/.master.json 或 PRIVATE_KEY");

  const net = await ethers.provider.getNetwork();
  if (net.chainId !== 224422n) throw new Error(`期望 chainId 224422，当前 ${net.chainId}`);

  const startTime = resolveStartTimeSec();
  const startHourId = resolveStartHourId();

  console.log("=".repeat(60));
  console.log("Deploy ConetGB1155 + gbTotal + gbUserTotal on CoNET");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("initialAdmin:", GB_INITIAL_ADMIN);
  console.log(
    "balance:",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "native"
  );
  console.log("startTime:", startTime.toString(), new Date(Number(startTime) * 1000).toISOString());
  console.log("startHourId:", startHourId.toString());

  const GBFactory = await ethers.getContractFactory("ConetGB1155");
  const gb = await GBFactory.deploy(startTime, startHourId, GB_INITIAL_ADMIN);
  await gb.waitForDeployment();
  const gbAddr = await gb.getAddress();
  const gbTx = gb.deploymentTransaction()?.hash ?? "";
  console.log("\n✅ ConetGB1155:", gbAddr);
  console.log("   tx:", gbTx);

  saveDeployment("ConetGB1155", {
    network: "conet",
    chainId: net.chainId.toString(),
    contract: "ConetGB1155",
    source: "src/b-unit/GB.sol",
    address: gbAddr,
    deployer: deployer.address,
    initialAdmin: GB_INITIAL_ADMIN,
    constructorArgs: [startTime.toString(), startHourId.toString(), GB_INITIAL_ADMIN],
    timestamp: new Date().toISOString(),
    transactionHash: gbTx,
  });
  mergeConetAddresses({ ConetGB1155: gbAddr });

  let gbTotalAddr = "";
  let gbUserTotalAddr = "";

  if (process.env.SKIP_GB_TOTAL !== "1") {
    const TotalFactory = await ethers.getContractFactory("ConetGB_total");
    const total = await TotalFactory.deploy(gbAddr);
    await total.waitForDeployment();
    gbTotalAddr = await total.getAddress();
    const tx = total.deploymentTransaction()?.hash ?? "";
    console.log("\n✅ ConetGB_total (gbTotal):", gbTotalAddr);
    console.log("   tx:", tx);
    saveDeployment("ConetGB_total", {
      network: "conet",
      chainId: net.chainId.toString(),
      contract: "ConetGB_total",
      source: "src/b-unit/gbTotal.sol",
      address: gbTotalAddr,
      conetgb: gbAddr,
      deployer: deployer.address,
      constructorArgs: [gbAddr],
      timestamp: new Date().toISOString(),
      transactionHash: tx,
    });
    mergeConetAddresses({ ConetGB_total: gbTotalAddr });
  }

  if (process.env.SKIP_GB_USER_TOTAL !== "1") {
    const UserTotalFactory = await ethers.getContractFactory("ConetGB_userTotal");
    const userTotal = await UserTotalFactory.deploy(gbAddr);
    await userTotal.waitForDeployment();
    gbUserTotalAddr = await userTotal.getAddress();
    const tx = userTotal.deploymentTransaction()?.hash ?? "";
    console.log("\n✅ ConetGB_userTotal (gbUserTotal):", gbUserTotalAddr);
    console.log("   tx:", tx);
    saveDeployment("ConetGB_userTotal", {
      network: "conet",
      chainId: net.chainId.toString(),
      contract: "ConetGB_userTotal",
      source: "src/b-unit/gbUserTotal.sol",
      address: gbUserTotalAddr,
      conetgb: gbAddr,
      deployer: deployer.address,
      constructorArgs: [gbAddr],
      timestamp: new Date().toISOString(),
      transactionHash: tx,
    });
    mergeConetAddresses({ ConetGB_userTotal: gbUserTotalAddr });
  }

  console.log("\nExplorer:");
  console.log("  GB:", `https://mainnet.conet.network/address/${gbAddr}`);
  if (gbTotalAddr) console.log("  gbTotal:", `https://mainnet.conet.network/address/${gbTotalAddr}`);
  if (gbUserTotalAddr) console.log("  gbUserTotal:", `https://mainnet.conet.network/address/${gbUserTotalAddr}`);
  console.log("\n验证: npx tsx scripts/verifyConetGBStackConetStandardJson.ts");
  console.log("引用同步: npx tsx scripts/updateConetReferences.ts");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
