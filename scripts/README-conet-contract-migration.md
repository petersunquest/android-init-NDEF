# CoNET 合约迁移与引用同步说明

本文档描述 CoNET mainnet（chainId **224422**）合约重部署后的标准流程，便于今后自动化迁移。

## 双 RPC 架构（新链 vs 旧链只读归档）

224422 **已从零重新启动**；线上业务、Hardhat `--network conet`、各客户端默认 RPC 均指向 **新链**。

| 角色 | RPC | 块高量级 | 用途 |
|------|-----|----------|------|
| **新链（权威）** | `https://rpc1.conet.network` | 低（重 genesis 后重新同步） | 读写：部署、交易、CoNET-SI / x402sdk / 应用 |
| **旧链只读归档** | `https://rpc-old.conet.network` | 高（中断前旧 224422 状态） | **只读**：从旧合约 `eth_call` / 事件拉取，用于迁移与恢复 |

两者 **chainId 均为 224422**，但 **不是同一条链历史**（新链新 genesis；`rpc-old` 保留旧状态）。  
**禁止**把 `rpc-old` 当作写 RPC 或默认业务 RPC；**禁止**假设同一地址在新旧 RPC 上 bytecode 一致。  
（运维：nginx 反代至 Geth `:8882`，见 `scripts/nginx-rpc-old-conet.conf`；**应用/脚本统一用 HTTPS 域名**，勿再写 `http://38.102.126.58:8880` / `:8001` 等直连 IP。）

### 旧链只读归档上的典型合约（rpc-old 可读）

| 合约 | 旧地址（rpc-old 有代码） | 新地址（rpc1 有代码） |
|------|------------------------|------------------------|
| GuardianNodesInfoV6 | `0x6d7a526BFD03E90ea8D19eDB986577395a139872` | `0x359F781A5eEb17630A44e15Bc2aC57b248b81790` |
| AddressPGP | `0xb2aABe52f476356AE638839A786EAE425A0c1b66` | `0xa5F64dd3c034442F5377c8F2Aa1A03ba378D685e` |
| ConetTreasury | `0x540767C2a183871deb22333a271D5e65bF489F22` | `0xb7A5d95a50b799d70424777D6f7d7EAAE0Da06A1` |
| LayerMinusNodeRestart_V2 | `0xf82a6362b9F23F2380C621B5A649987C5bc228B7` | `0x185b17bb66A28d1a86322Fc5c123361A324Bf3c3` |

从 rpc-old 拉 Guardian 示例（只读源 → 写入新链仍用 `--network conet` / rpc1）：

```bash
GUARDIAN_MIGRATE_SOURCE=0x6d7a526BFD03E90ea8D19eDB986577395a139872 \
GUARDIAN_MIGRATE_SOURCE_RPC=https://rpc-old.conet.network \
GUARDIAN_MIGRATE_EXPECT_SOURCE_CHAIN_ID=224422 \
GUARDIAN_MIGRATE_DUMP_PATH=deployments/guardian-migrate-from-rpc-old-dump.json \
DRY_RUN=1 npx hardhat run scripts/migrateGuardianNodesInfoV6FromLegacyTo224422.ts --network conet
```

亦可使用已有 dump（如 `guardian-migrate-224400-to-6d7a-dump.json`）配合 `GUARDIAN_MIGRATE_DUMP_INPUT`，在 rpc-old 不可达时离线恢复。

## 权威配置（单一真相来源）

| 文件 | 用途 |
|------|------|
| `deployments/conet-addresses.json` | 全部 CoNET 合约地址与 `chainId` |
| `deployments/conet-*.json` | 各合约独立部署记录（脚本写入） |
| `config/contract-addresses.ts` | Hardhat / 根仓 TS 读取（部分脚本） |

**禁止**在业务代码中硬编码旧地址；部署完成后必须运行引用同步脚本。

## 标准迁移顺序

### 1. 前置

- 确认 `hardhat.config.ts` 中 `conet` 网络：`url: https://rpc1.conet.network`，`chainId: 224422`（**非** rpc-old 只读归档）
- 链上历史恢复只读源：`https://rpc-old.conet.network`（见上文「双 RPC 架构」）
- 确认 `~/.master.json` 含有效 deployer / `settle_contractAdmin` 私钥
- 编译：`npm run clean && npm run compile`

### 2. 顺序部署（推荐）

```bash
npx tsx scripts/conetMigrate224422Orchestrator.ts
```

或按 orchestrator 内步骤逐项执行（BUint → BUnitAirdrop → ConetTreasury → Indexer → Oracle → AccountRegistry → FullAccount/UserCard → …）。

**Orchestrator 未包含、常需单独执行的步骤：**

```bash
# AddressPGP（Chat / 路由公钥）
npx hardhat run scripts/deployAddressPGPToConet.ts --network conet

# LayerMinus 节点重启事件
npx hardhat run scripts/deployLayerMinusNodeRestartV2ToConet.ts --network conet

# BUnitAirdrop 与 Indexer / Treasury 链上登记
npx hardhat run scripts/registerBUnitAirdropToConet.ts --network conet
```

各 `deploy*.ts` 成功后会合并地址到 `deployments/conet-addresses.json`。

### 3. 链上数据迁移（Guardian / PGP 路由）

Guardian 节点与 AddressPGP IP 路由不会随新合约自动复制，需专项脚本：

```bash
# GuardianNodesInfoV6：从 dump 或旧合约迁移节点列表
GUARDIAN_MIGRATE_DUMP_INPUT=deployments/guardian-migrate-224400-dump.json \
  npx tsx scripts/migrateGuardianNodesInfoV6FromLegacyTo224422.ts

# AddressPGP：登记 Guardian IP → route（须 settle_contractAdmin[0] 签名）
npx tsx scripts/addRoutesToAddressPGP.ts
# 或 CoNET-DL 路由：scripts/addCoNETDLRouterAdminsToAddressPGP.ts
```

可选：`ConetTreasury.setGuardianNodesInfoV6(新地址)`（若 Treasury 需指向新 Guardian 合约）。

### 4. 引用同步（必做）

```bash
npx tsx scripts/updateConetReferences.ts
```

从 `conet-addresses.json` 同步到各子项目。**部署后任何地址变更都必须重跑此脚本。**

### 5. Artifact 同步（UserCard / 模块变更时）

```bash
npm run clean && npm run compile
node scripts/syncBeamioUserCardToX402sdk.mjs
```

### 6. 验证

```bash
npx hardhat run scripts/verifyConetDeployments.ts --network conet
# CoNET-SI Guardian 探测
node src/CoNET-SI/scripts/check-getAllNodes.mjs
```

### 7. 服务重启

| 组件 | 说明 |
|------|------|
| x402sdk Cluster/Master | `npm run build` 后 restart systemd |
| CoNET-SI 节点 | 更新代码/env 后 restart（Guardian/PGP 地址在进程内硬编码常量） |
| SilentPassUI / bizSite | 重新 build + 部署 PWA / bizSite |

## `updateConetReferences.ts` 同步范围

| 键（conet-addresses.json） | 主要目标 |
|---------------------------|----------|
| `BUint` / `BUnitAirdrop` | x402sdk `MemberCard.ts`、`chainAddresses.ts`、各 beamio.ts |
| `BeamioIndexerDiamond` | x402sdk / SilentPassUI / bizSite chainAddresses |
| `ConetTreasury` / `conetUsdc` | CoNET-SI `server.ts`、`env.example`、readme、rules |
| `AccountRegistry` | x402sdk、bizSite、SilentPassUI、Android、iOS |
| `GuardianNodesInfoV6` | **CoNET-SI** `util.ts`、`localNodeCommand.ts`；**CoNET-DL** `layerMinusClientV2.ts`、`serverV4forMinerTotal.ts`；x402sdk `util.ts`；`scripts/API server/util.ts`；`check-getAllNodes.mjs` |
| `AddressPGP` | **CoNET-SI** `util.ts` `conet_PGP_address`；x402sdk `db.ts` `addressPGP` |
| `LayerMinusNodeRestart_V2` | **CoNET-SI** `localNodeCommand.ts` `nodeRestartEvent_addr` |
| `ConetGB1155` | **CoNET-DL** `serverV4forMinerTotal.ts` `eGB_addr`；**Dashboard** `contracts.ts` `CoNET_GB`；`gbTotal.sol` / `gbUserTotal.sol` 内 `ConetGB1155(...)` 指针 |
| `ConetGB_total` | **Dashboard** `contracts.ts` `CoNET_GBTotal`；子合约 `conetgb` 链上指向 `ConetGB1155` |
| `ConetGB_userTotal` | 写入 `conet-addresses.json`（Dashboard 未引用） |

### Dashboard GB 常量

| 键 | 文件 | JSON 键 |
|----|------|---------|
| `CoNET_GB` | `src/utils/contracts.ts` | `ConetGB1155` |
| `CoNET_GBTotal` | `src/utils/contracts.ts` | `ConetGB_total` |

### CoNET-DL GB 常量

| 常量 | 文件 | JSON 键 |
|------|------|---------|
| `eGB_addr` | `serverV4forMinerTotal.ts` | `ConetGB1155` |

### CoNET-SI 常量对照

| 常量 | 文件 | JSON 键 |
|------|------|---------|
| `CONET_TREASURY_ADDRESS`（env / server 默认） | `server.ts`, `env.example` | `ConetTreasury` |
| `GuardianNodeInfo_mainnet` | `util.ts`, `localNodeCommand.ts` | `GuardianNodesInfoV6` |
| `conet_PGP_address` | `util.ts` | `AddressPGP` |
| `nodeRestartEvent_addr` | `localNodeCommand.ts` | `LayerMinusNodeRestart_V2` |
| `CONTRACT`（诊断脚本） | `scripts/check-getAllNodes.mjs` | `GuardianNodesInfoV6` |

**未纳入自动同步（仍硬编码、非本次 Beamio 栈）：** Cancun 测试网地址、DePIN Passport、`duplicateFactory` 等 — 若重部署需手工更新或扩展 `updateConetReferences.ts`。

## 废弃地址

`conet-addresses.json` 中 `DEPRECATED_BUINT`、`DEPRECATED_CONET_USDC` 列表内的地址不得再用于新部署或默认配置。

## 自动化检查清单

- [ ] `deployments/conet-addresses.json` 已更新且 `chainId` 正确
- [ ] `npx tsx scripts/updateConetReferences.ts` 已执行且无报错
- [ ] Guardian 节点已迁移且 `check-getAllNodes.mjs` 返回节点数 > 0
- [ ] AddressPGP route 已登记（Chat 发件人 `searchKey` 可解析）
- [ ] x402sdk 已 build + 线上 restart
- [ ] CoNET-SI 已部署新代码并 restart

## 相关脚本

| 脚本 | 说明 |
|------|------|
| `conetMigrate224422Orchestrator.ts` | 一键顺序部署 |
| `updateConetReferences.ts` | 引用同步 |
| `migrateGuardianNodesInfoV6FromLegacyTo224422.ts` | Guardian 数据迁移 |
| `topupCoNETDLAdminEth.ts` | admin 钱包 CNET 余额补充 |
| `verifyConetDeployments.ts` | 部署后链上抽查 |
