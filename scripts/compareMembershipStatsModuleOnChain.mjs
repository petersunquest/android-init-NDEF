/**
 * 比对链上部署的 MembershipStatsModule 与本地编译产物
 * 用法: node scripts/compareMembershipStatsModuleOnChain.mjs
 */
import fs from "fs";
import { ethers } from "ethers";

const MODULE_ADDR = process.env.MODULE_ADDR || "0x2ab3534062dD731DBD6eB0cE78597DAFf17a46Bb";
const RPC = process.env.BASE_RPC_URL || "https://1rpc.io/base";

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);

  const chainCode = await provider.getCode(MODULE_ADDR);
  const chainClean =
    chainCode === "0x" || !chainCode
      ? ""
      : chainCode.startsWith("0x")
        ? chainCode.slice(2)
        : chainCode;

  const artifactPath =
    "artifacts/src/BeamioUserCard/MembershipStatsModule.sol/BeamioUserCardMembershipStatsModuleV1.json";
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
  const localDeployed =
    artifact.deployedBytecode?.object || artifact.deployedBytecode || "";
  const localClean = localDeployed.startsWith("0x")
    ? localDeployed.slice(2)
    : localDeployed;

  console.log("=== MembershipStatsModule 链上 vs 本地比对 ===\n");
  console.log("模块地址:", MODULE_ADDR);
  console.log("RPC:", RPC);
  console.log("");
  console.log("链上 runtime bytecode 长度:", chainClean.length);
  console.log("本地 deployedBytecode 长度:", localClean.length);
  console.log("");

  if (chainClean.length === 0) {
    console.log("❌ 链上该地址无合约代码");
    return;
  }

  const match = chainClean === localClean;
  console.log(
    "bytecode 一致:",
    match ? "✅ 是（链上为新版本）" : "❌ 否（链上为旧版本或不同）"
  );

  if (!match) {
    const minLen = Math.min(chainClean.length, localClean.length);
    let diffAt = -1;
    for (let i = 0; i < minLen; i += 2) {
      if (chainClean.slice(i, i + 2) !== localClean.slice(i, i + 2)) {
        diffAt = i;
        break;
      }
    }
    if (diffAt >= 0) {
      console.log("  首次差异位置 (hex offset):", diffAt);
      console.log(
        "  链上:",
        chainClean.slice(Math.max(0, diffAt - 4), diffAt + 40)
      );
      console.log(
        "  本地:",
        localClean.slice(Math.max(0, diffAt - 4), diffAt + 40)
      );
    } else {
      console.log(
        "  长度差:",
        Math.abs(chainClean.length - localClean.length)
      );
    }

    // 统计差异段
    const diffs = [];
    for (let i = 0; i < Math.min(chainClean.length, localClean.length); i += 2) {
      if (chainClean.slice(i, i + 2) !== localClean.slice(i, i + 2)) {
        let j = i;
        while (
          j < Math.min(chainClean.length, localClean.length) &&
          chainClean.slice(j, j + 2) !== localClean.slice(j, j + 2)
        ) {
          j += 2;
        }
        diffs.push({
          start: i,
          end: j,
          len: (j - i) / 2,
          chain: chainClean.slice(i, j),
          local: localClean.slice(i, j),
        });
        i = j - 2;
      }
    }
    console.log("\n  差异段数:", diffs.length);
    diffs.slice(0, 5).forEach((d, idx) => {
      console.log(
        `  段${idx + 1}: offset=${d.start} len=${d.len}bytes 链上=${d.chain?.slice(0, 24)}... 本地=${d.local?.slice(0, 24)}...`
      );
    });
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
