/**
 * 将 Card Factory 的 aaFactory 更新为部署文件中记录的新 AA Factory。
 * 需要由 Card Factory 的 owner 私钥执行。
 *
 * 用法：
 *   CARD_FACTORY_OWNER_PK=0x... npx hardhat run scripts/setCardFactoryAAFactory.ts --network base
 *
 * 或指定 AA Factory 地址：
 *   NEW_AA_FACTORY=0x... CARD_FACTORY_OWNER_PK=0x... npx hardhat run scripts/setCardFactoryAAFactory.ts --network base
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DEPLOYMENT_FILE = path.join(__dirname, "..", "deployments", "base-UserCardFactory.json");
const FULL_DEPLOYMENT_FILE = path.join(__dirname, "..", "deployments", "base-FullAccountAndUserCard.json");
const CONFIG_PATH = path.join(__dirname, "..", "config", "base-addresses.json");

/** Base 主网 Card Factory 默认值，与 config/base-addresses.json、deployments/base-UserCardFactory.json 一致 */
const DEFAULT_CARD_FACTORY = "0x2EB245646de404b2Dce87E01C6282C131778bb05";

function getCardFactoryAddress(): string {
  if (process.env.CARD_FACTORY_ADDRESS) return process.env.CARD_FACTORY_ADDRESS;
  if (fs.existsSync(FULL_DEPLOYMENT_FILE)) {
    const data = JSON.parse(fs.readFileSync(FULL_DEPLOYMENT_FILE, "utf-8"));
    const addr = data.contracts?.beamioUserCardFactoryPaymaster?.address;
    if (addr) return addr;
  }
  if (fs.existsSync(DEPLOYMENT_FILE)) {
    const data = JSON.parse(fs.readFileSync(DEPLOYMENT_FILE, "utf-8"));
    const addr = data.contracts?.beamioUserCardFactoryPaymaster?.address;
    if (addr) return addr;
  }
  if (fs.existsSync(CONFIG_PATH)) {
    const data = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf-8"));
    if (data.CARD_FACTORY) return data.CARD_FACTORY;
  }
  return DEFAULT_CARD_FACTORY;
}

async function main() {
  const { ethers } = await networkModule.connect();
  const pk = process.env.CARD_FACTORY_OWNER_PK;
  if (!pk) {
    throw new Error("请设置环境变量 CARD_FACTORY_OWNER_PK (Card Factory owner 私钥)");
  }

  let newAAFactory = process.env.NEW_AA_FACTORY;
  if (!newAAFactory) {
    if (fs.existsSync(CONFIG_PATH)) {
      const data = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf-8"));
      newAAFactory = data.AA_FACTORY;
    }
  }
  if (!newAAFactory) {
    throw new Error("未找到新 AA Factory 地址，请设置 NEW_AA_FACTORY 或先运行 redeployAAFactoryAndUpdateConfig.ts");
  }

  const CARD_FACTORY = getCardFactoryAddress();
  const wallet = new ethers.Wallet(pk, ethers.provider);
  const abi = ["function setAAFactory(address f) external", "function owner() external view returns (address)", "function aaFactory() external view returns (address)"];
  const cardFactory = new ethers.Contract(CARD_FACTORY, abi, wallet);
  const owner = await cardFactory.owner();
  if (owner.toLowerCase() !== wallet.address.toLowerCase()) {
    throw new Error(`当前私钥不是 Card Factory owner。owner=${owner}`);
  }
  const current = await cardFactory.aaFactory();
  if (current.toLowerCase() === newAAFactory.toLowerCase()) {
    console.log("Card Factory 的 aaFactory 已是目标地址，无需更新。");
    return;
  }
  const tx = await cardFactory.setAAFactory(newAAFactory);
  await tx.wait();
  console.log("已调用 setAAFactory(", newAAFactory, ")");
}

main().then(() => process.exit(0)).catch((e) => { console.error(e); process.exit(1); });
