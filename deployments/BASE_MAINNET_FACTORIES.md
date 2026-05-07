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
| **地址** | 见 config/base-addresses.json（当前为 `0xbA92e9122CDff1e8dD817eE55BCe7C7f6c9bFc9B`） |
| **网络** | Base Mainnet (Chain ID: 8453) |

**重部署 Card Factory：** `npm run redeploy:card-factory:base`。自动更新 config/base-addresses.json，各模块自动生效。

---

## 3. BeamioUserCard 链接库（发卡 initCode）

`BeamioUserCard` 部署字节码依赖两个 **external library**（须先部署并在验证器 / initCode 中链接）。

| 项目 | JSON 键 | 当前值 |
|------|---------|--------|
| **BeamioUserCardFormattingLib** | `BEAMIO_USER_CARD_FORMATTING_LIB` | 0xe56dca3aF78a12164dC6546e6CD0E9Fe9d9Cc4b3 |
| **BeamioUserCardTransferLib** | `BEAMIO_USER_CARD_TRANSFER_LIB` | 0xc7fAF8e33e9fE9D4409961Ec72d46B2200766f8F |

**部署：** `npm run deploy:usercard-libraries:base`（需 Base 主网 `PRIVATE_KEY`）。成功后脚本会写入 `config/base-addresses.json` 并同步 `src/x402sdk/src/chainAddresses.ts`。

**验证：** `deployments/base-BeamioUserCardFormattingLib-standard-input-FULL.json`、`base-BeamioUserCardTransferLib-standard-input-FULL.json`（见同目录 `*-basescan-verify-meta.txt`）。

---

## 区块浏览器

- AA Factory: https://basescan.org/address/0x4b31D6a05Cdc817CAc1B06369555b37a5b182122
- Card Factory: https://basescan.org/address/0xbA92e9122CDff1e8dD817eE55BCe7C7f6c9bFc9B

---

*由 scripts/writeBaseMainnetFactoriesMd.mjs 根据 config/base-addresses.json 生成。*
