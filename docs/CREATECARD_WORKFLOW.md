# createBeamioCard 服务器 Workflow 检查清单

基于成功测试（`CARD_OWNER=0x23ad...401 npm run create:ccsa:base`）的对照检查。

## 配置来源（createCard 使用）

| 配置项 | 来源文件 | 说明 |
|--------|----------|------|
| **Factory 地址** | `src/x402sdk/src/chainAddresses.ts` → `BASE_CARD_FACTORY` | 与 config/base-addresses.ts 一致 |
| **BeamioUserCard initCode** | `src/x402sdk/src/ABI/BeamioUserCardArtifact.json` | 由 `npm run sync:card-artifact` 从 artifacts 同步 |
| **Settle_ContractPool** | `~/.master.json` → `settle_contractAdmin` | 每项私钥对应 Factory 登记的 paymaster |

**重部署 Factory/BeamioUserCard 后必做：**
1. 更新 `config/base-addresses.ts` 和 `src/x402sdk/src/chainAddresses.ts` 的 CARD_FACTORY
2. `npm run compile && npm run sync:card-artifact`
3. **重启 Master 服务**（否则仍用旧 artifact/配置）

## 成功测试条件（Hardhat createCCSACard.ts）

- **Caller/signer**: `0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1`（Factory owner）
- **Card Factory**: 见 config/base-addresses.ts
- **Deployer**: 已通过 `setFactory(Card Factory)` 指向当前工厂
- **Gateway**: Card Factory 地址（必须与工厂一致）

## 服务器 Workflow 链路

```
UI → createCardEndpoint (cluster 2222)
  → createCardPreCheck(body)          ← 校验 JSON，不合格 400
  → postLocalhost('/api/createCard', preChecked, res)
Master (1111)
  → 收到 body，normalize priceInCurrencyE6
  → createCardPool.push({...body, res})
  → createCardPoolPress()
createCardPoolPress
  → shift createCardPool（请求队列）
  → shift Settle_ContractPool         ← factory 登记的 owner 列表，排队取一 admin
  → createBeamioCardAdminWithHash(..., SC.baseFactoryPaymaster)
  → 写入 0x{owner}.json metadata
  → res.json({ success, cardAddress, hash })
  → unshift SC 回池，setTimeout 处理下一请求
```

**Settle_ContractPool**：factory 登记的 owner 列表，作为排队系统。使用约定：
- 使用前必须 `shift()` 调出一名 owner，避免其他 process 使用同一 owner，防止同一 owner 同时调用 RPC 造成 **nonce 冲突**。
- process 结束后（成功/失败/early return）必须 `unshift(SC)` 将 owner 放回，以便其他 process 复用。

## 必须满足的配置

### 1. ~/.master.json settle_contractAdmin

**Settle_ContractPool** 由 `settle_contractAdmin` 初始化，数组中每一私钥对应一名 factory 登记的 owner。每个 admin 有 `baseFactoryPaymaster`（Factory 合约 + 该 admin 为 signer），用于 createCard。多 admin 支持并发：request A 取 admin1，request B 取 admin2，可同时送上 RPC。

### 2. Deployer 配置

Card Factory 使用的 Deployer 必须已调用 `setFactory(Card Factory 地址)`。

**诊断**：
```bash
npm run check:createcard-deployer:base
```

**修复**（需 Deployer owner 私钥）：
```bash
npm run set:card-deployer-factory:base
```

### 3. chainAddresses BASE_CARD_FACTORY

与 `config/base-addresses.ts` 的 `CARD_FACTORY` 一致。重部署后运行 `npm run redeploy:card-factory:base` 会自动更新。

### 4. BeamioUserCardArtifact 同步

x402sdk 的 `BeamioUserCardArtifact.json` 用于构建 createCard 的 initCode。若合约修改后未同步，会出现 `missing revert data`。修改 BeamioUserCard.sol 后执行：

```bash
npm run compile && npm run sync:card-artifact
```

## 数据流对照

| 步骤 | createCCSACard (Hardhat) | createCardPoolPress (Server) |
|------|--------------------------|-----------------------------|
| Factory | deployments 文件 | BASE_CARD_FACTORY / chainAddresses |
| Signer | ethers.getSigners()[0] | Settle_ContractPool[0].walletBase |
| gateway | cardFactoryAddress | factory.getAddress() |
| uri | `{id}.json` | `0x{owner}.json` (buildOwnerMetadataUri) |
| initCode | BeamioUserCard.getDeployTransaction | buildBeamioUserCardInitCodeFromParams |

## 常见错误与修复

| 错误 | 原因 | 修复 |
|------|------|------|
| missing revert data (DEP_NotFactory) | Deployer.factory 未指向 Card Factory | npm run set:card-deployer-factory:base |
| signer not owner/paymaster | settle_contractAdmin 中某私钥非 factory 登记 owner | 确保 settle_contractAdmin 仅含 factory owner/paymaster 私钥 |
| UC_GlobalMisconfigured | gateway 无 code | gateway 应为 Factory 地址 |
| F_BadDeployedCard | 部署后校验失败 | 检查 initCode 参数：uri、gateway、owner、currency、price |
| missing revert data (artifact 不匹配) | x402sdk 的 BeamioUserCardArtifact 与合约不同步 | 先 `npm run compile`，再 `npm run sync:card-artifact` |

## 本地验证

```bash
# 1. 诊断 Deployer
npm run check:createcard-deployer:base

# 2. 测试发卡（需 Hardhat 配置 factory owner 私钥）
CARD_OWNER=0x23ad857a1d265467c06adab914b3639710371401 npm run create:ccsa:base
```
