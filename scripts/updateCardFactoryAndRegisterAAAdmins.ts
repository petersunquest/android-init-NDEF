/**
 * 1) 将 BeamioUserCard 的 Factory（Card Factory）的 aaFactory 指向新的 AA Factory
 * 2) 在新 AA Factory 上登记 masterSetup.settle_contractAdmin 为 paymaster
 *
 * 从 ~/.master.json 读取 settle_contractAdmin；从 config/base-addresses.ts 读取当前 AA Factory。
 * 会自动用「Card Factory owner」执行 setAAFactory，用「AA Factory admin」执行 addPayMaster。
 *
 * 用法（不触发 Hardhat 编译，推荐）：
 *   npx tsx scripts/updateCardFactoryAndRegisterAAAdmins.ts
 * 或：
 *   npx hardhat run scripts/updateCardFactoryAndRegisterAAAdmins.ts --network base
 */
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { homedir } from "node:os";
import Colors from "colors/safe";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CONFIG_PATH = path.join(__dirname, "..", "config", "base-addresses.ts");
const MASTER_SETUP_PATH = path.join(homedir(), ".master.json");

function getAddressFromConfig(field: "AA_FACTORY" | "CARD_FACTORY"): string {
  if (!fs.existsSync(CONFIG_PATH)) {
    throw new Error("未找到 config/base-addresses.ts");
  }
  const content = fs.readFileSync(CONFIG_PATH, "utf-8");
  const m = content.match(new RegExp(`${field}:\\s*['"](0x[a-fA-F0-9]{40})['"]`));
  if (!m) throw new Error(`config/base-addresses.ts 中未解析到 ${field}`);
  return m[1];
}

function loadMasterSetup(): { settle_contractAdmin: string[]; base_endpoint: string } {
  if (!fs.existsSync(MASTER_SETUP_PATH)) {
    throw new Error(`未找到 ~/.master.json，请配置 settle_contractAdmin 与 base_endpoint`);
  }
  const data = JSON.parse(fs.readFileSync(MASTER_SETUP_PATH, "utf-8"));
  if (!data.settle_contractAdmin || !Array.isArray(data.settle_contractAdmin) || data.settle_contractAdmin.length === 0) {
    throw new Error("~/.master.json 中 settle_contractAdmin 为空或不是数组");
  }
  return {
    settle_contractAdmin: data.settle_contractAdmin.map((pk: string) => (pk.startsWith("0x") ? pk : `0x${pk}`)),
    base_endpoint: data.base_endpoint || "https://1rpc.io/base",
  };
}

async function main() {
  const newAAFactory = process.env.NEW_AA_FACTORY || getAddressFromConfig("AA_FACTORY");
  const master = loadMasterSetup();
  const provider = new ethers.JsonRpcProvider(master.base_endpoint);
  const CARD_FACTORY = process.env.CARD_FACTORY_ADDRESS || getAddressFromConfig("CARD_FACTORY");

  const wallets = master.settle_contractAdmin.map((pk: string) => new ethers.Wallet(pk, provider));
  const addresses = await Promise.all(wallets.map((w) => w.getAddress()));

  console.log(Colors.cyan("=".repeat(60)));
  console.log(Colors.cyan("1) Card Factory 指向新 AA Factory"));
  console.log(Colors.cyan("2) 新 AA Factory 登记 settle_contractAdmin 为 paymaster"));
  console.log(Colors.cyan("=".repeat(60)));
  console.log("新 AA Factory:", newAAFactory);
  console.log("Card Factory: ", CARD_FACTORY);
  console.log("settle_contractAdmin 数量:", addresses.length);
  console.log();

  const cardFactoryAbi = [
    "function owner() view returns (address)",
    "function setAAFactory(address f) external",
    "function aaFactory() view returns (address)",
  ];
  const aaFactoryAbi = [
    "function admin() view returns (address)",
    "function isPayMaster(address) view returns (bool)",
    "function addPayMaster(address) external",
  ];

  // ---- 1) 更新 Card Factory 的 aaFactory ----
  const cardFactoryContract = new ethers.Contract(CARD_FACTORY, cardFactoryAbi, provider);
  const cardOwner = await cardFactoryContract.owner();
  const currentCardAA = await cardFactoryContract.aaFactory();
  if (currentCardAA.toLowerCase() === newAAFactory.toLowerCase()) {
    console.log(Colors.green("Card Factory 的 aaFactory 已是新 AA Factory，跳过 setAAFactory"));
  } else {
    const ownerWallet = wallets.find((w) => w.address.toLowerCase() === cardOwner.toLowerCase());
    if (!ownerWallet) {
      console.log(Colors.yellow("⚠️  settle_contractAdmin 中无人是 Card Factory owner，无法执行 setAAFactory"));
      console.log("   Card Factory owner:", cardOwner);
      console.log("   请由 owner 手动执行: CARD_FACTORY_OWNER_PK=0x... npm run set:card-factory-aa:base");
    } else {
      console.log(Colors.cyan("使用 Card Factory owner 执行 setAAFactory..."));
      const cardFactoryWithSigner = new ethers.Contract(CARD_FACTORY, cardFactoryAbi, ownerWallet);
      const tx1 = await cardFactoryWithSigner.setAAFactory(newAAFactory);
      await tx1.wait();
      console.log(Colors.green("✅ Card Factory setAAFactory 成功"), tx1.hash);
    }
  }
  console.log();

  // ---- 2) 在新 AA Factory 上登记 settle_contractAdmin 为 paymaster ----
  const aaFactoryContract = new ethers.Contract(newAAFactory, aaFactoryAbi, provider);
  const aaAdmin = await aaFactoryContract.admin();
  const adminWallet = wallets.find((w) => w.address.toLowerCase() === aaAdmin.toLowerCase());
  if (!adminWallet) {
    console.log(Colors.yellow("⚠️  settle_contractAdmin 中无人是新 AA Factory 的 admin，无法添加 paymaster"));
    console.log("   AA Factory admin:", aaAdmin);
    console.log("   请由 admin 执行: npx hardhat run scripts/addSettleWalletsToFactories.ts --network base 或手动对每个地址调用 addPayMaster");
    return;
  }

  console.log(Colors.cyan("使用 AA Factory admin 为 settle_contractAdmin 添加 paymaster..."));
  const aaFactoryWithSigner = new ethers.Contract(newAAFactory, aaFactoryAbi, adminWallet);
  const added: string[] = [];
  for (const addr of addresses) {
    if (!ethers.isAddress(addr)) continue;
    const isPM = await aaFactoryWithSigner.isPayMaster(addr);
    if (isPM) {
      console.log("  已是 paymaster:", addr);
      continue;
    }
    try {
      const tx = await aaFactoryWithSigner.addPayMaster(addr);
      await tx.wait();
      added.push(addr);
      console.log(Colors.green("  + paymaster:"), addr, tx.hash);
    } catch (e) {
      console.error(Colors.red("  添加失败"), addr, (e as Error).message);
    }
  }
  console.log();
  console.log(Colors.cyan("=".repeat(60)));
  console.log(Colors.green("完成。新 AA Factory 新增 paymaster 数:"), added.length);
  if (added.length) added.forEach((a, i) => console.log(`  ${i + 1}. ${a}`));
  console.log(Colors.cyan("=".repeat(60)));
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(Colors.red("错误:"), e);
    process.exit(1);
  });
