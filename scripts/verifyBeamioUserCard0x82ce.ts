/**
 * 验证 0x82ceE96dB45933fE4b71D36fa8904508f929027C (USDC Topup Card) 在 BaseScan
 *
 * 用法:
 *   npx hardhat run scripts/verifyBeamioUserCard0x82ce.ts --network base
 *
 * 脚本会从链上读取 owner、currency、price、gateway，然后调用 verify。
 * 若 err_code_2，可尝试 URI="https://api.beamio.io/metadata/"（旧部署可能用此）
 */
import { network as networkModule } from "hardhat";

const CARD = "0x82ceE96dB45933fE4b71D36fa8904508f929027C";

/** 已知的 0x82ce 卡 constructor 参数（链上读取失败时使用） */
const FALLBACK_ARGS = {
  owner: "0x513087820Af94A7f4d21bC5B68090f3080022E0e",
  currency: 0,
  price: "1000000",
  gateway: "0x46E8a69f7296deF53e33844bb00D92309ab46233",
};

async function main() {
  const { ethers } = await networkModule.connect();

  let owner: string, currency: number, price: string, gateway: string;
  try {
    const card = await ethers.getContractAt("BeamioUserCard", CARD);
    const [o, c, p, g] = await Promise.all([
      card.owner(),
      card.currency(),
      card.pointsUnitPriceInCurrencyE6(),
      card.factoryGateway(),
    ]);
    owner = o;
    currency = Number(c);
    price = p.toString();
    gateway = g;
  } catch (e) {
    console.log("链上读取失败，使用已知参数:", e?.message);
    ({ owner, currency, price, gateway } = FALLBACK_ARGS);
  }

  const URI = process.env.URI || "https://beamio.app/api/metadata/0x";
  const constructorArgs = [URI, currency, price, owner, gateway];

  console.log("Card:", CARD);
  console.log("Constructor args from chain:");
  console.log("  URI:", URI);
  console.log("  currency:", currency);
  console.log("  price:", price);
  console.log("  owner:", owner);
  console.log("  gateway:", gateway);
  console.log("");

  const [uri, curr, prc, own, gw] = constructorArgs;
  const argsForCli = [JSON.stringify(uri), String(curr), String(prc), own, gw];
  const argsStr = argsForCli.join(" ");
  console.log("\n执行验证（可复制以下命令手动运行）:");
  console.log(`npx hardhat verify --network base ${CARD} ${argsStr}\n`);

  const { execSync } = await import("child_process");
  try {
    execSync(`npx hardhat verify --network base ${CARD} ${argsStr}`, {
      stdio: "inherit",
      cwd: process.cwd(),
    });
    console.log("✅ 验证成功");
  } catch (e: any) {
    if (e?.status === 0) return;
    if (e?.stderr?.toString?.()?.includes("Already Verified") || e?.stdout?.toString?.()?.includes("Already Verified")) {
      console.log("✅ 合约已验证");
    } else {
      console.error("\n若 err_code_2 (bytecode 不匹配):");
      console.error('  1. 尝试 URI="https://api.beamio.io/metadata/" 后重跑');
      console.error("  2. 或使用 Standard JSON 手动验证: deployments/base-BeamioUserCard-basescan-standard-input.json");
      process.exit(1);
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
