/**
 * 部署 BeamioIndexerDiamond (CoNETIndexTaskdiamond) 到 CoNET mainnet
 * RPC: https://rpc1.conet.network（chainId 224422）
 * 部署完成后将 settle_contractAdmin + beamio_Admins + admin 私钥对应地址添加为 Diamond admin
 *
 * 运行: npx hardhat run scripts/deployCoNETIndexerDiamond.ts --network conet
 */

import { network as hreNetwork } from "hardhat";
import { ethers as ethersLib } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { mergeConetAdminPrivateKeysFromMasterFile } from "./utils/conetMasterAdmins.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const AdminFacetABI = [
  "function setAdmin(address admin, bool enabled) external",
  "function isAdmin(address admin) view returns (bool)",
];

const DIAMOND_CUT_SELECTOR = "0x1f931c1c"; // diamondCut(bytes4[])

function getSelectors(abi: any): string[] {
  const arr = Array.isArray(abi) ? abi : abi?.abi || abi;
  if (!Array.isArray(arr)) throw new Error("Bad ABI");
  const iface = new ethersLib.Interface(arr);
  return [...new Set(iface.fragments.filter((f: any) => f.type === "function").map((f: any) => f.selector.toLowerCase()))];
}

async function main() {
  const { ethers } = await hreNetwork.connect();
  const [deployer] = await ethers.getSigners();
  console.log("=".repeat(60));
  console.log("部署 BeamioIndexerDiamond 到 CoNET mainnet");
  console.log("=".repeat(60));
  console.log("部署账户:", deployer.address);
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("余额:", ethers.formatEther(balance), "ETH");
  const net = await ethers.provider.getNetwork();
  console.log("网络:", net.name, "ChainId:", net.chainId.toString());

  if (balance === 0n) {
    throw new Error("账户余额为 0，无法部署");
  }

  // 1. 部署 DiamondCutFacet
  console.log("\n[1/9] 部署 DiamondCutFacet...");
  const DiamondCutFacet = await ethers.getContractFactory("DiamondCutFacet");
  const diamondCutFacet = await DiamondCutFacet.deploy();
  await diamondCutFacet.waitForDeployment();
  const cutFacetAddr = await diamondCutFacet.getAddress();
  console.log("  DiamondCutFacet:", cutFacetAddr);

  // 2. 部署 BeamioIndexerDiamond
  console.log("\n[2/9] 部署 BeamioIndexerDiamond...");
  const BeamioIndexerDiamond = await ethers.getContractFactory("BeamioIndexerDiamond");
  const diamond = await BeamioIndexerDiamond.deploy(deployer.address, cutFacetAddr);
  await diamond.waitForDeployment();
  const diamondAddr = await diamond.getAddress();
  console.log("  BeamioIndexerDiamond:", diamondAddr);

  // 3-N. 部署其他 Facets
  const facetNames = [
    "DiamondLoupeFacet",
    "OwnershipFacet",
    "TaskFacet",
    "StatsFacet",
    "CatalogFacet",
    "ActionFacet",
    "FeeStatsFacet",
    "BeamioUserCardStatsFacet",
    "AdminFacet",
  ];
  const facetAddrs: Record<string, string> = {};

  for (const name of facetNames) {
    console.log(`\n[${facetNames.indexOf(name) + 3}/${facetNames.length + 2}] 部署 ${name}...`);
    const Facet = await ethers.getContractFactory(name);
    const facet = await Facet.deploy();
    await facet.waitForDeployment();
    facetAddrs[name] = await facet.getAddress();
    console.log(`  ${name}:`, facetAddrs[name]);
  }

  // 10. diamondCut 添加所有 Facets
  console.log("\n[10] 执行 diamondCut 添加 Facets...");

  const idiamondPath = path.join(__dirname, "..", "artifacts", "src", "CoNETIndexTaskdiamond", "interfaces", "IDiamondCut.sol", "IDiamondCut.json");
  const diamondCutAbi = JSON.parse(fs.readFileSync(idiamondPath, "utf-8")).abi;
  const diamondCut = new ethers.Contract(diamondAddr, diamondCutAbi, deployer);

  const facetAbis: Record<string, any> = {};
  const artifactsDir = path.join(__dirname, "..", "artifacts", "src", "CoNETIndexTaskdiamond");
  for (const name of facetNames) {
    const artifactPath =
      name === "DiamondLoupeFacet" || name === "OwnershipFacet"
        ? path.join(artifactsDir, "facets", `${name}.sol`, `${name}.json`)
        : path.join(artifactsDir, "facets", `${name}.sol`, `${name}.json`);
    facetAbis[name] = JSON.parse(fs.readFileSync(artifactPath, "utf-8")).abi;
  }

  const cuts: { facetAddress: string; action: number; functionSelectors: string[] }[] = [];
  const seenSelectors = new Set<string>();
  for (const name of facetNames) {
    const selectors = getSelectors(facetAbis[name]).filter((s) => s !== DIAMOND_CUT_SELECTOR);
    const uniqueSelectors = selectors.filter((s) => {
      if (seenSelectors.has(s)) return false;
      seenSelectors.add(s);
      return true;
    });
    const skipped = selectors.length - uniqueSelectors.length;
    if (skipped > 0) {
      console.log(`  ${name}: 跳过重复 selector ${skipped} 个`);
    }
    if (uniqueSelectors.length > 0) {
      cuts.push({
        facetAddress: facetAddrs[name],
        action: 0, // Add
        functionSelectors: uniqueSelectors,
      });
    }
  }

  const tx = await diamondCut.diamondCut(cuts, ethersLib.ZeroAddress, "0x");
  console.log("  diamondCut tx:", tx.hash);
  await tx.wait();
  console.log("  ✅ diamondCut 完成");

  // 11. 将 master 合并私钥对应地址添加为 Diamond admin
  try {
    const pks = mergeConetAdminPrivateKeysFromMasterFile();
    if (pks.length > 0) {
      const addresses = pks.map((pk: string) => new ethersLib.Wallet(pk).address);
      console.log("\n[11] 添加合并 admin 为 Diamond admin...");
        const adminContract = new ethersLib.Contract(diamondAddr, AdminFacetABI, deployer);
        for (let i = 0; i < addresses.length; i++) {
          const addr = addresses[i];
          const already = await adminContract.isAdmin(addr);
          if (already) {
            console.log(`  [${i + 1}/${addresses.length}] ${addr} 已是 admin，跳过`);
          } else {
            const txAdmin = await adminContract.setAdmin(addr, true);
            await txAdmin.wait();
            console.log(`  [${i + 1}/${addresses.length}] setAdmin(${addr}) ✅`);
          }
        }
      console.log("  ✅ admin 登记完成");
    }
  } catch (e) {
    console.warn("  跳过 admin 登记:", (e as Error).message);
  }

  // 保存部署结果
  const deployDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deployDir)) fs.mkdirSync(deployDir, { recursive: true });
  const outPath = path.join(deployDir, "conet-IndexerDiamond.json");
  const result = {
    network: "conet",
    chainId: net.chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    diamond: diamondAddr,
    facets: {
      DiamondCutFacet: cutFacetAddr,
      ...facetAddrs,
    },
  };
  fs.writeFileSync(outPath, JSON.stringify(result, null, 2));
  console.log("\n部署结果已保存至:", outPath);
  console.log("\n✅ 部署完成!");
  console.log("  Diamond 地址:", diamondAddr);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
