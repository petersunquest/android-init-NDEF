# Base Mainnet 基础设施地址

**单一数据源：** `config/base-addresses.json` → `config/contract-addresses.ts`。AA/Card Factory 重部署后更新 JSON，各模块自动生效。

---

## 1. AA Factory（账户工厂）

创建 BeamioAccount（智能合约账户）的工厂合约。  
重部署后地址会变，以 `config/base-addresses.json` 中的 `AA_FACTORY` 为准。

| 项目 | 值 |
|------|-----|
| **合约** | BeamioFactoryPaymasterV07 |
| **地址** | 见 config/base-addresses.json（当前为 `0x4b31D6a05Cdc817CAc1B06369555b37a5b182122`） |
| **网络** | Base Mainnet (Chain ID: 8453) |

**重部署 AA Factory：** `npm run redeploy:aa-factory:base` 或 `npm run deploy:factory:base`。完成后需由 Card Factory owner 执行 `npm run set:card-factory-aa:base`（或链上调用 `setAAFactory(新地址)`）。

---

## 2. Card Factory（UserCard 工厂）

创建 BeamioUserCard（用户卡）的工厂合约。

| 项目 | 值 |
|------|-----|
| **合约** | BeamioUserCardFactoryPaymasterV07 |
| **地址** | 见 config/base-addresses.json（当前为 `0xfB5E3F2AbFe24DC17970d78245BeF56aAE8cb71a`） |
| **网络** | Base Mainnet (Chain ID: 8453) |

**重部署 Card Factory：** `npm run redeploy:card-factory:base`。自动更新 config/base-addresses.json，各模块自动生效。

---

## 区块浏览器

- AA Factory: https://basescan.org/address/0x4b31D6a05Cdc817CAc1B06369555b37a5b182122
- Card Factory: https://basescan.org/address/0xfB5E3F2AbFe24DC17970d78245BeF56aAE8cb71a

---

*由 scripts/writeBaseMainnetFactoriesMd.mjs 根据 config/base-addresses.json 生成。*
