/**
 * 比对链上部署的 BeamioUserCard 与本地 artifact 的 bytecode
 * 用法: CARD=0xB87058b44C881020fD529E7E34A158f05bc4C28a node scripts/compareCardBytecodeOnChain.mjs
 */
import fs from "fs";
import { ethers } from "ethers";

const CARD = process.env.CARD || "0xB87058b44C881020fD529E7E34A158f05bc4C28a";
const RPC = process.env.BASE_RPC_URL || "https://base-rpc.conet.network";

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);

  const chainCode = await provider.getCode(CARD);
  const chainCodeClean =
    chainCode === "0x" || !chainCode
      ? ""
      : chainCode.startsWith("0x")
        ? chainCode.slice(2)
        : chainCode;

  const artifact = JSON.parse(
    fs.readFileSync("src/x402sdk/src/ABI/BeamioUserCardArtifact.json", "utf-8")
  );
  const localDeployed =
    artifact.deployedBytecode?.object || artifact.deployedBytecode || "";
  const localClean = localDeployed.startsWith("0x")
    ? localDeployed.slice(2)
    : localDeployed;

  console.log("=== 链上合约 vs 本地 Artifact 比对 ===\n");
  console.log("卡地址:", CARD);
  console.log("RPC:", RPC);
  console.log("");
  console.log("链上 runtime bytecode 长度:", chainCodeClean.length);
  console.log("本地 deployedBytecode 长度:", localClean.length);
  console.log("");

  if (chainCodeClean.length === 0) {
    console.log("❌ 链上该地址无合约代码（可能为 EOA、代理、或地址错误）");
    return;
  }

  const match = chainCodeClean === localClean;
  console.log(
    "bytecode 一致:",
    match ? "✅ 是（链上为新版本）" : "❌ 否（链上为旧版本或不同）"
  );

  if (!match) {
    const minLen = Math.min(chainCodeClean.length, localClean.length);
    let diffAt = -1;
    for (let i = 0; i < minLen; i += 2) {
      if (chainCodeClean.slice(i, i + 2) !== localClean.slice(i, i + 2)) {
        diffAt = i;
        break;
      }
    }
    if (diffAt >= 0) {
      console.log("  首次差异位置 (hex offset):", diffAt);
      console.log(
        "  链上:",
        chainCodeClean.slice(Math.max(0, diffAt - 4), diffAt + 20)
      );
      console.log(
        "  本地:",
        localClean.slice(Math.max(0, diffAt - 4), diffAt + 20)
      );
    } else {
      console.log("  长度差:", Math.abs(chainCodeClean.length - localClean.length));
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
