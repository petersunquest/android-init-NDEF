import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function readJsonIfExists(file: string): any {
  if (!fs.existsSync(file)) return null;
  return JSON.parse(fs.readFileSync(file, "utf-8"));
}

function writeJson(file: string, value: unknown): void {
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n", "utf-8");
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) {
    throw new Error("未获取到 signer。请设置 PRIVATE_KEY 后再运行。");
  }

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const configPath = path.join(__dirname, "..", "config", "base-addresses.json");
  const fullAccountPath = path.join(deploymentsDir, "base-FullAccountAndUserCard.json");
  const fullSystemPath = path.join(deploymentsDir, "base-FullSystem.json");
  const factoryAndModulePath = path.join(deploymentsDir, "base-FactoryAndModule.json");
  const factoryAndModuleFixedPath = path.join(deploymentsDir, "base-FactoryAndModule-fixed.json");

  const config = readJsonIfExists(configPath) || {};
  const fullAccount = readJsonIfExists(fullAccountPath) || {};
  const fullSystem = readJsonIfExists(fullSystemPath) || {};
  const factoryAndModule = readJsonIfExists(factoryAndModulePath) || {};
  const factoryAndModuleFixed = readJsonIfExists(factoryAndModuleFixedPath) || {};

  const oldQuoteHelper =
    process.env.OLD_QUOTE_HELPER_ADDRESS ||
    fullAccount.existing?.beamioQuoteHelper ||
    fullSystem.contracts?.beamioQuoteHelper?.address ||
    factoryAndModule.contracts?.beamioFactoryPaymaster?.quoteHelper ||
    "";

  const oracleAddress =
    process.env.ORACLE_ADDRESS ||
    fullAccount.existing?.beamioOracle ||
    fullSystem.contracts?.beamioQuoteHelper?.oracle ||
    fullSystem.contracts?.beamioOracle?.address ||
    "";

  const aaFactoryAddress =
    process.env.AA_FACTORY ||
    config.AA_FACTORY ||
    fullAccount.contracts?.beamioFactoryPaymaster?.address ||
    factoryAndModule.contracts?.beamioFactoryPaymaster?.address ||
    "";

  if (!oracleAddress || !aaFactoryAddress) {
    throw new Error("缺少 ORACLE_ADDRESS 或 AA_FACTORY。");
  }

  const aaFactory = await ethers.getContractAt("BeamioFactoryPaymasterV07", aaFactoryAddress);
  const admin = await aaFactory.admin();
  if (admin.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(`当前 signer 不是 AA Factory admin（admin=${admin}）`);
  }

  console.log("Signer:", signer.address);
  console.log("AA Factory:", aaFactoryAddress);
  console.log("Oracle:", oracleAddress);
  console.log("Old AA QuoteHelper:", oldQuoteHelper || "(not set)");

  const QuoteHelper = await ethers.getContractFactory("BeamioQuoteHelperV07");
  const quoteHelper = await QuoteHelper.deploy(oracleAddress, signer.address);
  await quoteHelper.waitForDeployment();

  const newQuoteHelper = await quoteHelper.getAddress();
  const deployTx = quoteHelper.deploymentTransaction();
  console.log("New AA QuoteHelper:", newQuoteHelper);
  console.log("Deploy tx:", deployTx?.hash || "(missing)");

  const setTx = await aaFactory.setQuoteHelper(newQuoteHelper);
  await setTx.wait();
  console.log("AA Factory.setQuoteHelper tx:", setTx.hash);

  fullAccount.existing = fullAccount.existing || {};
  fullAccount.existing.beamioOracle = oracleAddress;
  fullAccount.existing.beamioQuoteHelper = newQuoteHelper;
  if (fullAccount.contracts?.beamioFactoryPaymaster) {
    fullAccount.contracts.beamioFactoryPaymaster.quoteHelper = newQuoteHelper;
  }
  writeJson(fullAccountPath, fullAccount);

  fullSystem.contracts = fullSystem.contracts || {};
  fullSystem.contracts.beamioQuoteHelper = {
    address: newQuoteHelper,
    oracle: oracleAddress,
    owner: signer.address,
    transactionHash: deployTx?.hash || null,
  };
  writeJson(fullSystemPath, fullSystem);

  if (factoryAndModule.contracts?.beamioFactoryPaymaster) {
    factoryAndModule.contracts.beamioFactoryPaymaster.quoteHelper = newQuoteHelper;
    writeJson(factoryAndModulePath, factoryAndModule);
  }

  if (factoryAndModuleFixed.contracts?.beamioFactoryPaymaster?.quoteHelper === oldQuoteHelper) {
    factoryAndModuleFixed.contracts.beamioFactoryPaymaster.quoteHelper = newQuoteHelper;
    writeJson(factoryAndModuleFixedPath, factoryAndModuleFixed);
  }

  console.log("已更新部署配置中的 AA QuoteHelper 引用。");
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
