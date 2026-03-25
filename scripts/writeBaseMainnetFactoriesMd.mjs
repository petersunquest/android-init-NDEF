/**
 * 根据 config/base-addresses.json 生成 deployments/BASE_MAINNET_FACTORIES.md
 * （与 redeployCardFactoryAndUpdateConfig.ts 中文档块保持一致）。
 *
 * 用法：node scripts/writeBaseMainnetFactoriesMd.mjs
 */
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const configJsonPath = path.join(ROOT, "config", "base-addresses.json");
const mdPath = path.join(ROOT, "deployments", "BASE_MAINNET_FACTORIES.md");

if (!fs.existsSync(configJsonPath)) {
  console.error("Missing:", configJsonPath);
  process.exit(1);
}
const baseJson = JSON.parse(fs.readFileSync(configJsonPath, "utf-8"));
const aaFactoryInConfig = baseJson.AA_FACTORY;
const factoryAddress = baseJson.CARD_FACTORY;
if (!aaFactoryInConfig || !factoryAddress) {
  console.error("base-addresses.json 需要 AA_FACTORY 与 CARD_FACTORY");
  process.exit(1);
}

const mdContent = `# Base Mainnet 基础设施地址

**单一数据源：** \`config/base-addresses.json\` → \`config/contract-addresses.ts\`。AA/Card Factory 重部署后更新 JSON，各模块自动生效。

---

## 1. AA Factory（账户工厂）

创建 BeamioAccount（智能合约账户）的工厂合约。  
重部署后地址会变，以 \`config/base-addresses.json\` 中的 \`AA_FACTORY\` 为准。

| 项目 | 值 |
|------|-----|
| **合约** | BeamioFactoryPaymasterV07 |
| **地址** | 见 config/base-addresses.json（当前为 \`${aaFactoryInConfig}\`） |
| **网络** | Base Mainnet (Chain ID: 8453) |

**重部署 AA Factory：** \`npm run redeploy:aa-factory:base\` 或 \`npm run deploy:factory:base\`。完成后需由 Card Factory owner 执行 \`npm run set:card-factory-aa:base\`（或链上调用 \`setAAFactory(新地址)\`）。

---

## 2. Card Factory（UserCard 工厂）

创建 BeamioUserCard（用户卡）的工厂合约。

| 项目 | 值 |
|------|-----|
| **合约** | BeamioUserCardFactoryPaymasterV07 |
| **地址** | 见 config/base-addresses.json（当前为 \`${factoryAddress}\`） |
| **网络** | Base Mainnet (Chain ID: 8453) |

**重部署 Card Factory：** \`npm run redeploy:card-factory:base\`。自动更新 config/base-addresses.json，各模块自动生效。

---

## 区块浏览器

- AA Factory: https://basescan.org/address/${aaFactoryInConfig}
- Card Factory: https://basescan.org/address/${factoryAddress}

---

*由 scripts/writeBaseMainnetFactoriesMd.mjs 根据 config/base-addresses.json 生成。*
`;

fs.mkdirSync(path.dirname(mdPath), { recursive: true });
fs.writeFileSync(mdPath, mdContent, "utf-8");
console.log("Wrote", mdPath);
