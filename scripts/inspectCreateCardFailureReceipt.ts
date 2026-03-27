/**
 * Read-only: fetch a failed createCard tx receipt on Base and print DeployFailedStep /
 * DeployFailedCreateDebug if the factory emitted them (needs factory bytecode with these events).
 *
 *   CREATE_CARD_FAIL_TX=0x14f52... FACTORY=0x2EB2... npx hardhat run scripts/inspectCreateCardFailureReceipt.ts --network base
 *
 * FACTORY defaults to deployments/base-UserCardFactory.json nested address.
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const FACTORY_FAILURE_EVENTS_ABI = [
  "event DeployFailedStep(uint8 step)",
  "event DeployFailedCreateDebug(uint256 initCodeLength, bytes32 initCodeHash)",
  "event CardDeployed(address indexed cardOwner, address indexed card, uint8 currency, uint256 priceE18)",
];

function loadProdFactoryAddress(): string | null {
  const p = path.join(__dirname, "..", "deployments", "base-UserCardFactory.json");
  if (!fs.existsSync(p)) return null;
  const j = JSON.parse(fs.readFileSync(p, "utf8"));
  return j?.contracts?.beamioUserCardFactoryPaymaster?.address ?? j?.address ?? null;
}

export function parseFactoryFailureLogs(
  ethers: any,
  factoryAddr: string,
  receipt: { logs: readonly { address: string; topics: readonly string[]; data: string }[] },
): void {
  const fa = factoryAddr.toLowerCase();
  const iface = new ethers.Interface(FACTORY_FAILURE_EVENTS_ABI);
  console.log("\n--- Factory logs (failure decode) ---");
  let any = false;
  for (const log of receipt.logs ?? []) {
    if (log.address.toLowerCase() !== fa) continue;
    try {
      const parsed = iface.parseLog({ topics: [...log.topics], data: log.data });
      any = true;
      console.log(parsed?.name, parsed?.args?.toObject?.() ?? parsed?.args);
    } catch {
      /* not our events */
    }
  }
  if (!any) console.log("(no DeployFailedStep / DeployFailedCreateDebug / CardDeployed from this factory — older bytecode or revert before emit)");
}

async function main() {
  const txHash = (process.env.CREATE_CARD_FAIL_TX || "").trim();
  if (!txHash || !txHash.startsWith("0x")) {
    throw new Error("Set CREATE_CARD_FAIL_TX=0x...");
  }

  const { ethers } = await networkModule.connect();
  const factory =
    (process.env.FACTORY || process.env.USER_CARD_FACTORY_ADDRESS || "").trim() ||
    loadProdFactoryAddress() ||
    "";
  if (!factory || !ethers.isAddress(factory)) {
    throw new Error("Set FACTORY=0x... or keep deployments/base-UserCardFactory.json");
  }

  const receipt = await ethers.provider.getTransactionReceipt(txHash);
  if (!receipt) throw new Error(`No receipt for ${txHash}`);
  console.log("tx:", txHash);
  console.log("status:", receipt.status?.toString?.() ?? receipt.status);
  console.log("gasUsed:", receipt.gasUsed?.toString?.());
  console.log("factory filter:", factory);

  parseFactoryFailureLogs(ethers, factory, receipt);

  const tx = await ethers.provider.getTransaction(txHash);
  if (tx?.data && tx.data !== "0x") {
    console.log("\ncalldata length (bytes):", (tx.data.length - 2) / 2);
  } else {
    console.log("\n(calldata empty in RPC response — use another RPC or indexer)");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
