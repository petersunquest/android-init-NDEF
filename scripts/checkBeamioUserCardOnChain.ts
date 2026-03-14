/**
 * 查询 Base 上部署的 BeamioUserCard 合约状态
 * 用法: npx tsx scripts/checkBeamioUserCardOnChain.ts [合约地址]
 */
import { ethers } from "ethers";

const CARD = process.argv[2] || "0xcdAb59228695bbF2137d56382395f854267194E1";
const RPC = process.env.BASE_RPC_URL || "https://base-rpc.conet.network";

const ABI = [
  "function owner() view returns (address)",
  "function VERSION() view returns (uint256)",
  "function gateway() view returns (address)",
  "function deployer() view returns (address)",
  "function factoryGateway() view returns (address)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const contract = new ethers.Contract(CARD, ABI, provider);

  console.log("=== BeamioUserCard 链上查询 ===");
  console.log("合约地址:", CARD);
  console.log("RPC:", RPC);
  console.log("");

  try {
    const [owner, version, gateway, deployer, factoryGateway] = await Promise.all([
      contract.owner(),
      contract.VERSION(),
      contract.gateway(),
      contract.deployer(),
      contract.factoryGateway(),
    ]);

    console.log("owner():           ", owner);
    console.log("VERSION():         ", version.toString());
    console.log("gateway():         ", gateway);
    console.log("deployer():        ", deployer);
    console.log("factoryGateway():  ", factoryGateway);
    console.log("");

    const expectedOwner = "0x513087820Af94A7f4d21bC5B68090f3080022E0e";
    const ownerMatch = owner?.toLowerCase() === expectedOwner.toLowerCase();
    console.log("预期 owner:        ", expectedOwner);
    console.log("owner 匹配:        ", ownerMatch ? "✅ 是" : "❌ 否");
    console.log("");

    // VERSION 11 表示包含 AdminStatsStorage、getAdminHourlyData 等新功能
    const version11 = version === 11n;
    console.log("VERSION=11 (新功能):", version11 ? "✅ 是" : "❌ 否 (当前=" + version + ")");
  } catch (e: any) {
    console.error("查询失败:", e.message || e);
    process.exit(1);
  }
}

main();
