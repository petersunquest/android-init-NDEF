/**
 * Deploy NodeSaleSplitter as a UUPS upgradeable ERC1967 proxy on Base.
 *
 *   1) NodeSaleSplitter implementation (UUPS)
 *   2) ERC1967Proxy(implementation, initialize(usdc, treasury, serverFee, nodePrice6, serverFee6, admin))
 *      ← canonical Base address (stays stable across upgrades)
 *
 * Splits each node purchase: nodePriceUsdc6 → treasury, serverFeeUsdc6 → serverFeeRecipient.
 * Defaults: 1250 USDC node price, 120 USDC server fee, recipients per chainAddresses.
 *
 * Run:
 *   npx hardhat run scripts/deployNodeSaleSplitterToBase.ts --network base
 *
 * Then:
 *   npx tsx scripts/verifyNodeSaleSplitterBaseScan.ts
 *
 * Env overrides (optional):
 *   NODE_SALE_SPLITTER_ADMIN        initial admin (default: deployer = settle_contractAdmin[0])
 *   NODE_SALE_TREASURY              node principal recipient (default: 0x5c64…0c58)
 *   NODE_SALE_SERVER_FEE_RECIPIENT  server fee recipient    (default: 0x87cA…05E1)
 *   NODE_SALE_USDC                  Base USDC                (default: 0x8335…2913)
 *   NODE_SALE_NODE_PRICE_USDC6      node principal per node  (default: 1250000000)
 *   NODE_SALE_SERVER_FEE_USDC6      server fee per node      (default: 120000000)
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";
import { ethers } from "ethers";
import ERC1967ProxyArtifact from "@openzeppelin/contracts/build/contracts/ERC1967Proxy.json" with { type: "json" };

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

const DEFAULT_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const DEFAULT_TREASURY = "0x5c64a8b0935DA72d60933bBD8cD10579E1C40c58";
const DEFAULT_SERVER_FEE_RECIPIENT = "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1";
const DEFAULT_NODE_PRICE_USDC6 = 1_250_000_000n; // 1250 USDC
const DEFAULT_SERVER_FEE_USDC6 = 120_000_000n; //   120 USDC

function loadMasterSetup(): { settle_contractAdmin: string[]; base_endpoint?: string } {
  const setupPath = path.join(homedir(), ".master.json");
  if (!fs.existsSync(setupPath)) {
    throw new Error("未找到 ~/.master.json，请配置 settle_contractAdmin");
  }
  const data = JSON.parse(fs.readFileSync(setupPath, "utf-8"));
  if (!Array.isArray(data.settle_contractAdmin) || data.settle_contractAdmin.length === 0) {
    throw new Error("~/.master.json 中 settle_contractAdmin 为空或不是数组");
  }
  return {
    settle_contractAdmin: data.settle_contractAdmin.map((pk: string) => (pk.startsWith("0x") ? pk : `0x${pk}`)),
    base_endpoint: data.base_endpoint,
  };
}

function addrFromEnv(name: string, fallback: string): string {
  const raw = process.env[name]?.trim();
  const value = raw && ethers.isAddress(raw) ? raw : fallback;
  return ethers.getAddress(value);
}

function usdc6FromEnv(name: string, fallback: bigint): bigint {
  const raw = process.env[name]?.trim();
  if (raw && /^\d+$/.test(raw)) return BigInt(raw);
  return fallback;
}

async function main() {
  const master = loadMasterSetup();
  const deployerPk = master.settle_contractAdmin[0];
  if (!deployerPk) throw new Error("settle_contractAdmin[0] 为空");

  const { ethers: ethersHH } = await networkModule.connect();
  const baseRpc = master.base_endpoint || process.env.BASE_RPC_URL || "https://base-rpc.conet.network";
  const provider = new ethers.JsonRpcProvider(baseRpc);
  const deployer = new ethers.Wallet(deployerPk, provider);

  const net = await provider.getNetwork();
  if (net.chainId !== 8453n) {
    throw new Error(`期望 Base chainId 8453，当前 ${net.chainId}`);
  }

  const usdc = addrFromEnv("NODE_SALE_USDC", DEFAULT_USDC);
  const treasury = addrFromEnv("NODE_SALE_TREASURY", DEFAULT_TREASURY);
  const serverFeeRecipient = addrFromEnv("NODE_SALE_SERVER_FEE_RECIPIENT", DEFAULT_SERVER_FEE_RECIPIENT);
  const nodePriceUsdc6 = usdc6FromEnv("NODE_SALE_NODE_PRICE_USDC6", DEFAULT_NODE_PRICE_USDC6);
  const serverFeeUsdc6 = usdc6FromEnv("NODE_SALE_SERVER_FEE_USDC6", DEFAULT_SERVER_FEE_USDC6);
  const admin = addrFromEnv("NODE_SALE_SPLITTER_ADMIN", deployer.address);

  console.log("=".repeat(60));
  console.log("Deploy NodeSaleSplitter UUPS proxy on Base");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("chainId:", net.chainId.toString());
  console.log("usdc:", usdc);
  console.log("treasury:", treasury);
  console.log("serverFeeRecipient:", serverFeeRecipient);
  console.log("nodePriceUsdc6:", nodePriceUsdc6.toString(), `(${ethers.formatUnits(nodePriceUsdc6, 6)} USDC)`);
  console.log("serverFeeUsdc6:", serverFeeUsdc6.toString(), `(${ethers.formatUnits(serverFeeUsdc6, 6)} USDC)`);
  console.log("grossPerNode:", ethers.formatUnits(nodePriceUsdc6 + serverFeeUsdc6, 6), "USDC");
  console.log("admin:", admin);
  console.log("balance:", ethers.formatEther(await provider.getBalance(deployer.address)), "ETH\n");

  const ImplFactory = await ethersHH.getContractFactory("NodeSaleSplitter");
  const impl = await ImplFactory.connect(deployer).deploy();
  await impl.waitForDeployment();
  const implAddr = await impl.getAddress();
  const implTx = impl.deploymentTransaction()?.hash ?? "";
  console.log("NodeSaleSplitter implementation:", implAddr);
  if (implTx) console.log("  impl tx:", implTx);

  const initData = ImplFactory.interface.encodeFunctionData("initialize", [
    usdc,
    treasury,
    serverFeeRecipient,
    nodePriceUsdc6,
    serverFeeUsdc6,
    admin,
  ]);

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
  console.log("NodeSaleSplitter proxy (canonical):", proxyAddr);
  console.log("  proxy tx:", proxyTxHash);
  if (proxyDeployBlock) console.log("  proxy block:", proxyDeployBlock);

  // Sanity read-back through the proxy.
  const splitter = ImplFactory.attach(proxyAddr).connect(deployer) as Awaited<ReturnType<typeof ImplFactory.deploy>>;
  const readTreasury = await (splitter as unknown as { treasury(): Promise<string> }).treasury();
  const readGross = await (splitter as unknown as { grossForNodes(n: bigint): Promise<bigint> }).grossForNodes(1n);
  console.log("readback treasury:", readTreasury);
  console.log("readback grossForNodes(1):", ethers.formatUnits(readGross, 6), "USDC");

  const out = {
    network: "base",
    chainId: net.chainId.toString(),
    contract: "NodeSaleSplitter",
    upgradeable: true,
    proxyPattern: "ERC1967Proxy",
    source: "src/mainnet/NodeSaleSplitter.sol",
    address: proxyAddr,
    implementation: implAddr,
    deployer: deployer.address,
    usdc,
    treasury,
    serverFeeRecipient,
    nodePriceUsdc6: nodePriceUsdc6.toString(),
    serverFeeUsdc6: serverFeeUsdc6.toString(),
    admin,
    initializeArgs: {
      usdc,
      treasury,
      serverFeeRecipient,
      nodePriceUsdc6: nodePriceUsdc6.toString(),
      serverFeeUsdc6: serverFeeUsdc6.toString(),
      admin,
    },
    compiler: "0.8.35+commit.47b9dedd",
    timestamp: new Date().toISOString(),
    deployBlock: proxyDeployBlock || undefined,
    transactionHash: proxyTxHash,
    implementationTransactionHash: implTx || undefined,
  };

  const deploymentsDir = path.join(root, "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });
  const outPath = path.join(deploymentsDir, "base-NodeSaleSplitter.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("\nsaved:", outPath);

  console.log("\n下一步:");
  console.log("  1) 验证: npx tsx scripts/verifyNodeSaleSplitterBaseScan.ts");
  console.log("  2) 把 Master relayer 钱包加为 admin（用于 distribute）: setAdmin(<relayer>, true)");
  console.log("  3) 在 x402sdk chainAddresses.ts 写入 NODE_SALE_SPLITTER_BASE =", proxyAddr);
  console.log("\n查看: https://basescan.org/address/" + proxyAddr + "#code");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
