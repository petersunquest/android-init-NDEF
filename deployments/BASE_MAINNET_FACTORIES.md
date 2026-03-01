# Base Mainnet 基础设施地址

**单一数据源：** `config/base-addresses.ts`。AA/Card Factory 重部署后会更新该文件，UI/API/SDK 均从此处或同步文件读取。

---

## 1. AA Factory（账户工厂）

创建 BeamioAccount（智能合约账户）的工厂合约。  
重部署后地址会变，以 `config/base-addresses.ts` 中的 `AA_FACTORY` 为准。

| 项目 | 值 |
|------|-----|
| **合约** | BeamioFactoryPaymasterV07 |
| **地址** | 见 config/base-addresses.ts（当前为 `0xD86403DD1755F7add19540489Ea10cdE876Cc1CE`） |
| **网络** | Base Mainnet (Chain ID: 8453) |

**重部署 AA Factory：** `npm run redeploy:aa-factory:base`。完成后需由 Card Factory owner 执行 `npm run set:card-factory-aa:base`（或链上调用 `setAAFactory(新地址)`）。

---

## 2. Card Factory（UserCard 工厂）

创建 BeamioUserCard（用户卡）的工厂合约。

| 项目 | 值 |
|------|-----|
| **合约** | BeamioUserCardFactoryPaymasterV07 |
| **地址** | 见 config/base-addresses.ts（当前为 `0xDdD5c17E549a4e66ca636a3c528ae8FAebb8692b`） |
| **网络** | Base Mainnet (Chain ID: 8453) |

**重部署 Card Factory：** `npm run redeploy:card-factory:base` 或 `npm run deploy:card-factory-only:base`。自动更新 SilentPassUI、x402sdk、config。

---

## 区块浏览器

- AA Factory: https://basescan.org/address/0xD86403DD1755F7add19540489Ea10cdE876Cc1CE
- Card Factory: https://basescan.org/address/0xDdD5c17E549a4e66ca636a3c528ae8FAebb8692b

---

*Card Factory 重部署后请运行 `npm run redeploy:card-factory:base` 或 `npm run deploy:card-factory-only:base` 以自动更新所有配置。*
