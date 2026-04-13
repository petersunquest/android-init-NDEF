/**
 * 部署 BusinessStartKet (ERC-1155) 到 CoNET mainnet，并为 settle_contractAdmin 全部地址 addAdmin。
 *
 * 运行: npx hardhat run scripts/deployBusinessStartKetToConet.ts --network conet
 *
 * 环境变量（可选）:
 *   BUSINESS_START_KET_URI   默认 https://beamio.app/api/metadata/business-start-ket/{id}.json
 *   BUSINESS_START_KET_NAME  默认 Business Start Ket
 *   BUSINESS_START_KET_SYMBOL 默认 BSK
 *
 * 前置: ~/.master.json settle_contractAdmin[0] 与 hardhat conet 部署账号一致，且有足够 CNET gas。
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const MASTER_PATH = path.join(homedir(), ".master.json");

function loadMasterSetup(): { settle_contractAdmin: string[] } {
  if (!fs.existsSync(MASTER_PATH)) throw new Error("未找到 ~/.master.json");
  const data = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  if (!data?.settle_contractAdmin?.length) throw new Error("~/.master.json 中 settle_contractAdmin 为空");
  return {
    settle_contractAdmin: data.settle_contractAdmin.map((pk: string) =>
      pk.startsWith("0x") ? pk : `0x${pk}`
    ),
  };
}

async function main() {
  const { ethers: ethersHH } = await networkModule.connect();
  const [deployer] = await ethersHH.getSigners();
  const net = await ethersHH.provider.getNetwork();
  const master = loadMasterSetup();

  const settleAddresses = master.settle_contractAdmin.map((pk: string) => new ethers.Wallet(pk).address);
  const uniqueSettle = [...new Set(settleAddresses.map((a) => ethers.getAddress(a)))];

  const uri =
    process.env.BUSINESS_START_KET_URI?.trim() ||
    "https://beamio.app/api/metadata/business-start-ket/{id}.json";
  const name_ = process.env.BUSINESS_START_KET_NAME?.trim() || "Business Start Ket";
  const symbol_ = process.env.BUSINESS_START_KET_SYMBOL?.trim() || "BSK";

  console.log("=".repeat(60));
  console.log("Deploy BusinessStartKet on CoNET mainnet");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("chainId:", net.chainId.toString());
  console.log("uri:", uri);
  console.log("name:", name_, "symbol:", symbol_);
  const balance = await ethersHH.provider.getBalance(deployer.address);
  console.log("balance:", ethers.formatEther(balance), "CNET\n");

  if (!uniqueSettle.map((a) => a.toLowerCase()).includes(deployer.address.toLowerCase())) {
    console.warn(
      "警告: 部署者不在 settle_contractAdmin 中；部署后需自行用首个 admin 为 settle 钱包 addAdmin。"
    );
  }

  const Factory = await ethersHH.getContractFactory("BusinessStartKet");
  const c = await Factory.deploy(uri, name_, symbol_);
  await c.waitForDeployment();
  const deployed = await c.getAddress();
  console.log("BusinessStartKet deployed:", deployed);

  const abi = [
    "function admins(address) view returns (bool)",
    "function addAdmin(address) external",
  ] as const;
  const w = deployer;
  const write = new ethers.Contract(deployed, abi, w);

  for (const addr of uniqueSettle) {
    const already = (await write.admins(addr)) as boolean;
    if (already) {
      console.log("already admin:", addr);
      continue;
    }
    const tx = await write.addAdmin(addr);
    await tx.wait();
    console.log("addAdmin ok:", addr);
  }

  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    deployer: deployer.address,
    settle_contractAdmin: uniqueSettle,
    constructorArgs: { uri, name: name_, symbol: symbol_ },
    timestamp: new Date().toISOString(),
    contracts: {
      BusinessStartKet: {
        address: deployed,
        uri,
        name: name_,
        symbol: symbol_,
        transactionHash: c.deploymentTransaction()?.hash ?? "",
      },
    },
  };

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });
  const outPath = path.join(deploymentsDir, "conet-BusinessStartKet.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("\nsaved:", outPath);

  const addrPath = path.join(deploymentsDir, "conet-addresses.json");
  const addrData = fs.existsSync(addrPath) ? JSON.parse(fs.readFileSync(addrPath, "utf-8")) : {};
  addrData.BusinessStartKet = deployed;
  addrData.network = addrData.network ?? "conet";
  addrData.chainId = addrData.chainId ?? "224400";
  fs.writeFileSync(addrPath, JSON.stringify(addrData, null, 2) + "\n", "utf-8");
  console.log("updated conet-addresses.json BusinessStartKet:", deployed);
  console.log("\n下一步: npx hardhat run scripts/verifyBusinessStartKetConet.ts --network conet");
  console.log("并同步 src/x402sdk/src/chainAddresses.ts 中 CONET_BUSINESS_START_KET 为上述地址。");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
