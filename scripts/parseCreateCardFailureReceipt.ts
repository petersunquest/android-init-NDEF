/**
 * Decode DeployFailedStep / DeployFailedCreateDebug from a failed createCard tx receipt (needs factory bytecode that emits these events).
 *
 *   FAILED_TX=0x... npx hardhat run scripts/parseCreateCardFailureReceipt.ts --network base
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DEPLOYMENTS = path.join(__dirname, "..", "deployments");

async function main() {
  const txHash = process.env.FAILED_TX?.trim();
  if (!txHash?.startsWith("0x")) {
    throw new Error("Set FAILED_TX=0x...");
  }

  const { ethers } = await networkModule.connect();
  const receipt = await ethers.provider.getTransactionReceipt(txHash);
  if (!receipt) throw new Error("Receipt not found");
  console.log("tx:", txHash, "status:", receipt.status, "gasUsed:", receipt.gasUsed?.toString());
  console.log("logs count:", receipt.logs?.length ?? 0);

  const artifactPath = path.join(
    __dirname,
    "..",
    "artifacts",
    "src",
    "BeamioUserCard",
    "BeamioUserCardFactoryPaymasterV07.sol",
    "BeamioUserCardFactoryPaymasterV07.json",
  );
  if (!fs.existsSync(artifactPath)) {
    console.warn("No compiled artifact; run npm run compile. Printing raw topics only.");
    for (const log of receipt.logs ?? []) {
      console.log(" topic0:", log.topics[0]);
    }
    return;
  }
  const { abi } = JSON.parse(fs.readFileSync(artifactPath, "utf8")) as { abi: unknown[] };
  const iface = new ethers.Interface(abi as any);

  for (const log of receipt.logs ?? []) {
    try {
      const parsed = iface.parseLog({ topics: log.topics as string[], data: log.data });
      if (!parsed) continue;
      if (parsed.name === "DeployFailedStep") {
        console.log("DeployFailedStep(step):", parsed.args.step?.toString?.() ?? parsed.args);
      }
      if (parsed.name === "DeployFailedCreateDebug") {
        const len = parsed.args.initCodeLength ?? parsed.args[0];
        const h = parsed.args.initCodeHash ?? parsed.args[1];
        console.log("DeployFailedCreateDebug initCodeLength:", len?.toString?.() ?? len);
        console.log("DeployFailedCreateDebug initCodeHash:", h);
      }
    } catch {
      /* other contracts */
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
