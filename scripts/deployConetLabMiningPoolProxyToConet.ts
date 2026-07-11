/**
 * Deploy ConetLabMiningPool as a UUPS upgradeable ERC1967 proxy on CoNET (224422).
 *
 *   1) ConetLabMiningPool implementation (UUPS)
 *   2) ERC1967Proxy(implementation, initialize(initialAdmin))
 *      ← canonical address (stays stable for fee_recipient / reward payout)
 *
 * Run:
 *   npx hardhat run scripts/deployConetLabMiningPoolProxyToConet.ts --network conet
 *
 * Then:
 *   npx tsx scripts/verifyConetLabMiningPoolConet.ts
 *
 * Env (optional):
 *   CONET_LAB_MINING_POOL_INITIAL_ADMIN  initial admin (default: deployer)
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";
import ERC1967ProxyArtifact from "@openzeppelin/contracts/build/contracts/ERC1967Proxy.json" with { type: "json" };

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

function loadConetAddresses(): Record<string, unknown> {
  const addrPath = path.join(root, "deployments", "conet-addresses.json");
  if (!fs.existsSync(addrPath)) return {};
  try {
    return JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, unknown>;
  } catch {
    return {};
  }
}

function loadInitialAdmin(deployer: string): string {
  const env = process.env.CONET_LAB_MINING_POOL_INITIAL_ADMIN?.trim();
  if (env && ethers.isAddress(env)) return ethers.getAddress(env);
  return ethers.getAddress(deployer);
}

async function main() {
  const { ethers: ethersHH } = await networkModule.connect();
  const [deployer] = await ethersHH.getSigners();
  const net = await ethersHH.provider.getNetwork();
  if (net.chainId !== 224422n) {
    throw new Error(`期望 chainId 224422，当前 ${net.chainId}`);
  }

  const initialAdmin = loadInitialAdmin(deployer.address);
  const addrData = loadConetAddresses();

  console.log("=".repeat(60));
  console.log("Deploy ConetLabMiningPool UUPS proxy on CoNET");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("chainId:", net.chainId.toString());
  console.log("initialAdmin:", initialAdmin);
  console.log("balance:", ethers.formatEther(await ethersHH.provider.getBalance(deployer.address)), "CNET\n");

  const ImplFactory = await ethersHH.getContractFactory("ConetLabMiningPool");
  const impl = await ImplFactory.deploy();
  await impl.waitForDeployment();
  const implAddr = await impl.getAddress();
  const implTx = impl.deploymentTransaction()?.hash ?? "";
  console.log("ConetLabMiningPool implementation:", implAddr);
  if (implTx) console.log("  impl tx:", implTx);

  const initData = ImplFactory.interface.encodeFunctionData("initialize", [initialAdmin]);

  const ProxyFactory = new ethers.ContractFactory(
    ERC1967ProxyArtifact.abi,
    ERC1967ProxyArtifact.bytecode,
    deployer
  );
  const proxy = await ProxyFactory.deploy(implAddr, initData);
  await proxy.waitForDeployment();
  const proxyAddr = await proxy.getAddress();
  const proxyDeployTx = proxy.deploymentTransaction();
  const proxyTxHash = proxyDeployTx?.hash ?? "";
  let proxyDeployBlock = 0;
  if (proxyDeployTx) {
    const receipt = await proxyDeployTx.wait();
    proxyDeployBlock = Number(receipt?.blockNumber ?? 0);
  }
  console.log("ConetLabMiningPool proxy (canonical):", proxyAddr);
  console.log("  proxy tx:", proxyTxHash);
  if (proxyDeployBlock) console.log("  proxy block:", proxyDeployBlock);

  const pool = ImplFactory.attach(proxyAddr) as Awaited<ReturnType<typeof ImplFactory.deploy>>;
  const isAdmin = await (pool as unknown as { admins(a: string): Promise<boolean> }).admins(initialAdmin);
  console.log("readback admins(initialAdmin):", isAdmin);
  if (!isAdmin) throw new Error("initialize failed: initialAdmin is not admin");

  const prevCanonical =
    typeof addrData.ConetLabMiningPool === "string" ? (addrData.ConetLabMiningPool as string) : "";

  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    contract: "ConetLabMiningPool",
    upgradeable: true,
    proxyPattern: "ERC1967Proxy",
    source: "src/mainnet/ConetLabMiningPool.sol",
    address: proxyAddr,
    proxy: proxyAddr,
    implementation: implAddr,
    deployer: deployer.address,
    initialAdmin,
    initializeArgs: {
      initialAdmin,
    },
    compiler: "0.8.35+commit.47b9dedd",
    timestamp: new Date().toISOString(),
    deployBlock: proxyDeployBlock || undefined,
    transactionHash: proxyTxHash,
    implementationTransactionHash: implTx || undefined,
    previousCanonical: prevCanonical || undefined,
  };

  const deploymentsDir = path.join(root, "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });
  const outPath = path.join(deploymentsDir, "conet-ConetLabMiningPool.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("\nsaved:", outPath);

  const merged = { ...addrData, ConetLabMiningPool: proxyAddr };
  const addrPath = path.join(deploymentsDir, "conet-addresses.json");
  fs.writeFileSync(addrPath, JSON.stringify(merged, null, 2) + "\n", "utf-8");
  console.log("updated:", addrPath, "→ ConetLabMiningPool =", proxyAddr);

  console.log("\n下一步:");
  console.log("  1) 导出 Standard JSON: npm run clean && npm run compile");
  console.log("     node scripts/exportStandardJsonFromBuildInfo.mjs ConetLabMiningPool --full");
  console.log("  2) 验证: npx tsx scripts/verifyConetLabMiningPoolConet.ts");
  console.log("  3) 将质押/投票节点 fee_recipient 指向代理:", proxyAddr);
  console.log("\n查看: https://mainnet.conet.network/address/" + proxyAddr);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
