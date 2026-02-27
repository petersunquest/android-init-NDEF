# createCard 与 RedeemStorage 分析

## 问题

卡 `0xeA7B248CFcD457c4884371c55Ae5aFb0F428c483` 于 2026-02-26 14:41:49 由服务器创建，但链上 bytecode **不包含** RedeemStorage v1 slot (`cb1a422c...`)，导致 getRedeemStatusEx 等 revert。

## RedeemStorage 说明

**RedeemStorage 不是单独部署的合约地址**，而是一个 Solidity library，编译时内联进 BeamioUserCard 的 bytecode。slot 常量 `keccak256("beamio.usercard.redeem.storage.v1")` 会直接出现在部署的 initCode 中。

## createCard initCode 来源链路

```
createCard API (cluster 2222)
  → postLocalhost('/api/createCard')
Master (1111)
  → createCardPool.push()
  → createCardPoolPress()
    → createBeamioCardAdminWithHash()     [src/x402sdk/src/MemberCard.ts]
      → createBeamioCardWithFactoryReturningHash()  [src/x402sdk/src/CCSA.ts]
        → createBeamioCardWithFactory()
          → buildBeamioUserCardInitCodeFromParams()  [src/x402sdk/src/CCSA.ts]
            → import BeamioUserCardArtifact from './ABI/BeamioUserCardArtifact.json'
```

**initCode 使用的 artifact 路径**：`src/x402sdk/src/ABI/BeamioUserCardArtifact.json`

## sync:card-artifact 命令

```json
"sync:card-artifact": "cp artifacts/src/BeamioUserCard/BeamioUserCard.sol/BeamioUserCard.json src/x402sdk/src/ABI/BeamioUserCardArtifact.json"
```

- 同步目标正确：就是 createCard 使用的 `src/x402sdk/src/ABI/BeamioUserCardArtifact.json`
- 同步源：`artifacts/`（Hardhat 编译产物）

## 为何卡 0xeA7B 使用旧版 RedeemStorage？

可能原因：

1. **服务器未重启**：artifact 在进程启动时加载。执行 `sync:card-artifact` 后若未重启 Master，进程仍使用旧 artifact 构建的 initCode。
2. **sync 未执行**：在加入 RedeemStorage v1 或修改合约后，未执行 `npm run compile && npm run sync:card-artifact`。
3. **部署使用旧代码**：生产环境若从其他仓库/分支部署，可能未包含最新 artifact。
4. **scripts/API server 未同步**：`scripts/API server/ABI/BeamioUserCardArtifact.json` 是另一份拷贝，当前 sync 不更新它；若某处误用该文件，可能引入旧 bytecode（当前 createCard 走 x402sdk，不受影响）。

## 建议

1. **修改 sync 命令**：同时更新 `scripts/API server/ABI/BeamioUserCardArtifact.json`，保持两处一致。
2. **部署后必做**：`npm run compile && npm run sync:card-artifact` 后**重启 Master 服务**。
3. **部署流程**：确认生产部署会拉取最新代码并执行 sync，再重启服务。
