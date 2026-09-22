# BeamioAccount 部署指南

本指南说明如何使用 Hardhat 将 BeamioAccount 智能合约部署到 Base 链。

## Cluster/Master 服务器发布原则

服务器代码必须遵守“本地开发、推送后远程部署”：

1. 在本地 checkout 拉取并合并远程提交。
2. 本地完成冲突处理、测试和构建。
3. 提交并 push 到权威 Git 仓库，记录待部署 commit SHA。
4. 远程服务器只拉取该已发布 commit，然后构建、重启应用服务并做 smoke test。

禁止通过 SSH 直接修改源码或 `dist/`，禁止在远程脏工作树上执行强制
`reset`、覆盖、清理或盲目 `pull`。远程工作树存在未提交修改时，部署必须
停止；应先由维护者将其保留并提交，或在本地 checkout 中形成可审查的合并
提交。Telegram、FCM/APNs、Master 等密钥必须在目标主机本地配置，不能复制、
打印或提交。

Cluster 只负责完整预检与转发，Master 只消费已验证任务并执行排队写操作。
发布 API 不得重启或重初始化 Geth、Beacon、Validator 等链基础设施。详细
约束见 [Beamio Server Development and Deployment Boundary](.cursor/rules/beamio-server-local-dev-cluster-master.mdc)。

## 前置准备

1. **安装依赖**
   ```bash
   npm install
   ```

2. **配置环境变量**
   - 复制 `.env.example` 为 `.env`
   ```bash
   cp .env.example .env
   ```
   - 编辑 `.env` 文件，填入以下信息：
     - `PRIVATE_KEY`: 部署账户的私钥（格式：`0x...`）
     - `BASE_RPC_URL`: Base 主网 RPC URL（默认已配置）
     - `BASESCAN_API_KEY`: BaseScan API Key（用于合约验证，可选）

## 架构说明

### BeamioAccount vs BeamioUserCard

**重要**: BeamioAccount 和 BeamioUserCard 是两个独立的系统：

- **BeamioAccount**: ERC-4337 Account Abstraction，**不依赖** BeamioOracle
- **BeamioUserCard**: ERC-1155 用户卡系统，**需要** BeamioOracle 获取汇率

BeamioAccount 的构造函数只需要 `EntryPoint` 地址，不需要 Oracle。Oracle 是 UserCard 系统通过 Gateway 访问的。

详细架构说明请查看 [ARCHITECTURE.md](./ARCHITECTURE.md)

## 部署步骤

### 1. 编译合约

```bash
npm run compile
```

### 2. 部署方式

#### 方式 A: 直接部署 BeamioAccount（标准部署）

**Base 主网：**
```bash
npm run deploy:base
# 或
npx hardhat run scripts/deployBeamioAccount.ts --network base
```

**Base Sepolia 测试网：**
```bash
npm run deploy:base-sepolia
# 或
npx hardhat run scripts/deployBeamioAccount.ts --network baseSepolia
```

#### 方式 B: 部署完整系统（包括 Oracle）

如果需要使用 BeamioUserCard 功能，需要先部署 Oracle：

```bash
# Base 主网
npm run deploy:full:base

# Base Sepolia 测试网
npm run deploy:full:base-sepolia
```

这会部署：
- BeamioOracle（汇率预言机）
- BeamioQuoteHelperV07（报价辅助，依赖 Oracle）
- BeamioAccountDeployer（CREATE2 部署器）
- BeamioAccount（AA 账号）

#### 方式 C: 通过 BeamioAccountDeployer 部署（CREATE2 部署）

这种方式可以预先计算合约地址，适合批量部署 AA 账号。

**步骤 1: 部署 BeamioAccountDeployer**

```bash
# Base 主网
npm run deploy:deployer:base

# Base Sepolia 测试网
npm run deploy:deployer:base-sepolia
```

**步骤 2: 设置 Factory（如果需要）**

部署器部署后，需要设置 Factory 地址才能使用：
```typescript
await deployerContract.setFactory(factoryAddress);
```

**步骤 3: 通过部署器部署 AA 账号**

在 `.env` 文件中设置以下变量：
```env
DEPLOYER_ADDRESS=0x...  # BeamioAccountDeployer 合约地址
FACTORY_ADDRESS=0x...    # Factory 合约地址（如果已设置可省略）
CREATOR_ADDRESS=0x...    # 创建者地址（用于计算 salt，默认使用部署账户）
ACCOUNT_INDEX=0          # 账号索引（用于计算 salt，默认 0）
```

然后运行：
```bash
# Base 主网
npm run deploy:aa:base

# Base Sepolia 测试网
npm run deploy:aa:base-sepolia
```

## 自动合约验证

所有部署脚本都集成了**自动合约验证**功能，部署完成后会自动在 BaseScan 上验证合约源代码。

### 验证功能特性

1. **自动验证**: 部署完成后自动验证，无需手动操作
2. **智能重试**: 自动等待区块确认后再验证
3. **错误处理**: 友好的错误提示，已验证的合约会跳过
4. **CREATE2 支持**: 支持验证通过 CREATE2 部署的合约

### 配置验证

在 `.env` 文件中设置 BaseScan API Key：
```env
BASESCAN_API_KEY=your_api_key_here
```

获取 API Key: https://basescan.org/myapikey

### 验证状态

验证成功后，可以在 BaseScan 上查看：
- 合约源代码
- ABI 接口
- 合约交互功能

验证链接格式: `https://basescan.org/address/<合约地址>#code`

## 部署信息

部署成功后，脚本会：
- 输出合约地址和部署信息
- 将部署信息保存到 `deployments/` 目录（JSON 格式）
- **自动验证合约**（如果配置了 BaseScan API Key）
- 输出 BaseScan 查看链接

## 重要说明

1. **EntryPoint 地址**: BeamioAccount 使用 ERC-4337 EntryPoint V0.7，地址为 `0x0000000071727De22E5E9d8BAf0edAc6f37da032`（这是标准地址，在所有链上相同）

2. **Gas 费用**: 确保部署账户有足够的 ETH 支付 Gas 费用

3. **私钥安全**: 
   - 永远不要将 `.env` 文件提交到 Git
   - 使用专门的部署账户，不要使用主账户
   - 考虑使用硬件钱包或多签钱包

4. **网络配置**: 
   - Base 主网 Chain ID: 8453
   - Base Sepolia 测试网 Chain ID: 84532

## 手动验证合约（可选）

如果自动验证失败，可以手动验证：

### 标准部署的合约

```bash
npx hardhat verify --network base <合约地址> 0x0000000071727De22E5E9d8BAf0edAc6f37da032
```

### CREATE2 部署的合约

CREATE2 部署的合约验证方式相同，BaseScan 会自动识别：

```bash
npx hardhat verify --network base <合约地址> 0x0000000071727De22E5E9d8BAf0edAc6f37da032
```

### 使用验证工具函数

也可以使用我们提供的验证工具：

```typescript
import { verifyContract } from "./scripts/utils/verifyContract.js";

await verifyContract(contractAddress, [ENTRY_POINT_V07], "BeamioAccount");
```

## 故障排除

1. **"No contracts to compile"**: 运行 `npm run clean && npm run compile`

2. **"insufficient funds"**: 确保部署账户有足够的 ETH

3. **"nonce too low"**: 等待几秒后重试，或手动设置 nonce

4. **RPC 连接失败**: 检查网络连接和 RPC URL 是否正确

5. **验证失败**: 
   - 确保配置了 `BASESCAN_API_KEY`
   - 等待更多区块确认后重试（通常需要 5-10 个区块）
   - 检查合约地址和构造函数参数是否正确

6. **CREATE2 部署失败**:
   - 确保 Factory 地址已正确设置
   - 检查当前账户是否为 Factory
   - 验证 salt 和 initCode 是否正确

7. **"Already Verified"**: 这是正常提示，表示合约已经验证过了

## 相关链接

- [Base 官方文档](https://docs.base.org/)
- [BaseScan 浏览器](https://basescan.org/)
- [ERC-4337 规范](https://eips.ethereum.org/EIPS/eip-4337)
