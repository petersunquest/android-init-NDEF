/**
 * CoNET 新链（rpc1.conet.network / chainId 224422）一键顺序部署入口。
 *
 * 依赖: ~/.master.json 含 settle_contractAdmin、beamio_Admins 或 admin 中的有效私钥；
 *       Hardhat 使用合并后的私钥列表，首项为默认 deployer。
 *
 * 用法:
 *   npx tsx scripts/conetMigrate224422Orchestrator.ts
 *
 * 环境变量:
 *   DRY_RUN=1     仅打印将执行的命令，不执行
 *   SKIP_VERIFY=1 跳过末尾 verify 步骤
 *
 * 部署后请执行:
 *   npx tsx scripts/updateConetReferences.ts
 * 并把 BUnitAirdrop 链上 setBeamioIndexerDiamond / setQuoteHelper 等（若构造函数默认仍为 0 地址）。
 */

import { execSync } from "child_process";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

const steps: { cmd: string; desc: string }[] = [
  { cmd: "npx hardhat run scripts/deployBUintToConet.ts --network conet", desc: "1. BUint (BeamioBUnits)" },
  { cmd: "npx hardhat run scripts/deployBUnitAirdropToConet.ts --network conet", desc: "2. BUnitAirdrop" },
  { cmd: "npx hardhat run scripts/deployConetTreasuryToConet.ts --network conet", desc: "3. ConetTreasury + USDC" },
  { cmd: "npx hardhat run scripts/deployCoNETIndexerDiamond.ts --network conet", desc: "4. BeamioIndexerDiamond" },
  { cmd: "npx hardhat run scripts/deployConetOracleAndQuoteHelper.ts --network conet", desc: "5. Oracle + QuoteHelper" },
  { cmd: "npx hardhat run scripts/deployAccountRegistryToConet.ts --network conet", desc: "5b. AccountRegistry (社交注册表)" },
  { cmd: "npx hardhat run scripts/deployFullAccountAndUserCard.ts --network conet", desc: "6. FullAccount + UserCard" },
  { cmd: "npx hardhat run scripts/deployBuintRedeemAirdropToConet.ts --network conet", desc: "7. BuintRedeemAirdrop" },
  { cmd: "npx hardhat run scripts/deployBusinessStartKetToConet.ts --network conet", desc: "8. BusinessStartKet" },
  { cmd: "npx hardhat run scripts/deployBusinessStartKetRedeemToConet.ts --network conet", desc: "9. BusinessStartKetRedeem" },
  { cmd: "npx hardhat run scripts/deployMerchantPOSManagementToConet.ts --network conet", desc: "10. MerchantPOSManagement" },
  { cmd: "npx hardhat run scripts/deployGuardianNodesAddressToConet.ts --network conet", desc: "11. GuardianNodesAddress" },
  { cmd: "npx hardhat run scripts/deployGuardianNodesInfoV6ToConet.ts --network conet", desc: "12. GuardianNodesInfoV6" },
];

function main() {
  const dry = process.env.DRY_RUN === "1";
  console.log("ConNET 224422 顺序部署（RPC: https://rpc1.conet.network）\n");
  for (const { cmd, desc } of steps) {
    console.log("\n" + "=".repeat(60));
    console.log(desc);
    console.log("=".repeat(60));
    if (dry) {
      console.log("[DRY_RUN]", cmd);
      continue;
    }
    try {
      execSync(cmd, { stdio: "inherit", cwd: root });
    } catch (e) {
      console.error("\n❌ 步骤失败:", desc);
      console.error(e);
      process.exit(1);
    }
  }

  if (!dry && process.env.SKIP_VERIFY !== "1") {
    console.log("\n[验证] 运行 verifyConetDeployments（若存在）…");
    try {
      execSync("npx hardhat run scripts/verifyConetDeployments.ts --network conet", { stdio: "inherit", cwd: root });
    } catch {
      console.warn("verifyConetDeployments 跳过或失败，请手工在 Blockscout 验证。");
    }
  }

  console.log("\n✅ 顺序完成。请更新 deployments/conet-addresses.json 后运行: npx tsx scripts/updateConetReferences.ts");
}

main();
