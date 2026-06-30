# GBToken 在各 L1 Explorer 正确显示 名称 / Decimals / 图片

GBToken（9 位 ERC20 GB）同址：`0xbeEbE03943b55e67373796ddc7314fC76f5b5911`（CoNET 224422 / Base 8453）。

Explorer 展示分两层：
- **名称 / 符号 / Decimals**：链上 `name()` `symbol()` `decimals()` 常量，**验证合约源码后** Blockscout / Etherscan 自动读取，无需额外操作。
- **代币图片（logo）**：标准 ERC20 **不携带链上图片**，须在各 Explorer 单独登记（off-chain）。本目录提供素材。

素材：
- `GB.png`（1024×1024）/ `GB-256.png`（256×256）：代币 logo
- `metadata.json`：合约级元数据（与合约 `contractURI()` 一致，供支持的钱包/浏览器）

> 先把 `GB.png` 上传到合约 `contractURI` 指向的托管地址：`https://assets.conet.network/gb/erc20/GB.png`
> 与 `…/metadata.json`（保持与本目录 `metadata.json` 内容一致）。

---

## 1. 第一步：验证合约源码（名称/Decimals 即显示）

```bash
# CoNET scan（Blockscout / 兼容 etherscan API）
npx hardhat verify --network conet 0xbeEbE03943b55e67373796ddc7314fC76f5b5911 0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1

# Basescan
npx hardhat verify --network base 0xbeEbE03943b55e67373796ddc7314fC76f5b5911 0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1
```

构造参数为 `initialAdmin = 0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1`。

## 2. CoNET scan（自托管 Blockscout）登记 logo

自托管 Blockscout 三种方式任选其一（推荐 A）：

### A. Token Info / Admin 后台（最简单）
管理后台 → 找到该 token → 上传 `GB-256.png`，填 name `CONET GB`、symbol `GB`、decimals `9`、官网 `https://conet.network`。

### B. 环境变量指定图标 CDN
Blockscout 前端支持按合约地址映射图标。把 `GB.png` 放到前端可访问的静态目录，并在
`common-frontend.env` / 前端 `NEXT_PUBLIC_*` 配置代币图标映射（不同 Blockscout 版本字段名不同，见下「字段对照」）。

### C. 数据库直写（应急）
向 Blockscout DB `tokens` 表对应行写入 `icon_url`（指向托管的 `GB.png`）。仅在 A/B 不可用时使用，升级可能被覆盖。

## 3. Basescan（Etherscan 系）登记 logo

Base 上是 Etherscan 系，须走官方「Token Update / Token Info」表单：
1. 合约已验证 + 该地址持有人发起 Token Info 申请；
2. 上传 32×32 / 256×256 PNG（用 `GB-256.png`），填 name/symbol/decimals、官网、社媒；
3. 审核通过后 Basescan 显示 logo。
（Etherscan 系不读链上 `contractURI`，必须走表单。）

## 4. 钱包 / 聚合器（可选，加速生态识别）

- 提交到 Trust Wallet assets 仓库：`blockchains/<chain>/assets/0xbeEbE03943b55e67373796ddc7314fC76f5b5911/{logo.png, info.json}`（用 `GB-256.png`）。
- 任何读 `contractURI()` 的钱包会拿到本目录 `metadata.json` 的 `image`。

---

## 字段对照（核对一致）

| 项 | 值 |
|----|----|
| name | CONET GB |
| symbol | GB |
| decimals | 9 |
| 1 GB | 1e9 最小单位（1 byte = 1 单位） |
| 地址（各 L1 同址） | 0xbeEbE03943b55e67373796ddc7314fC76f5b5911 |
| contractURI | https://assets.conet.network/gb/erc20/metadata.json |
| image | https://assets.conet.network/gb/erc20/GB.png |
