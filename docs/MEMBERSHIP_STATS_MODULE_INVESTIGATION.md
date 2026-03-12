# MembershipStatsModule 排查报告

## 1. 链上配置与版本比对

### Factory 配置（Base 主网）

| 模块 | 地址 | 部署记录 |
|------|------|----------|
| defaultMembershipStatsModule | `0x2ab3534062dD731DBD6eB0cE78597DAFf17a46Bb` | base-UserCardModules.json (2026-03-11) |

### 版本比对结果

| 比对项 | 结果 |
|-------|------|
| **MembershipStatsModule 链上 bytecode** vs **本地 BeamioUserCardMembershipStatsModuleV1** | ✅ **完全一致**（新版本） |
| **BeamioUserCard 链上 bytecode** vs **本地 BeamioUserCardArtifact** | ✅ 逻辑一致（仅 1 处 20 字节地址占位符差异） |

**结论**：链上部署的 MembershipStatsModule 与 BeamioUserCard 均为新版本，模块逻辑正确。

---

## 2. 根因分析：Storage Layout 不匹配

### 问题

`BeamioUserCard` **不继承** `BeamioUserCardBase`，而是自行声明存储变量，导致与 `MembershipStatsModule`（继承 `BeamioUserCardBase`）的 storage layout 不一致。

当卡通过 `delegatecall` 调用模块时，模块按 `BeamioUserCardBase` 的布局读写 storage，而卡的实际布局不同，导致写入错位。

### 布局差异

**BeamioUserCardBase**（模块期望的布局）：
```
... _userOwnedNfts
→ activeMembershipId
→ activeTierIndexOrMax
→ ...
→ totalActiveMemberships
```

**BeamioUserCard**（卡的实际布局）：
```
... _userOwnedNfts
→ _totalSupplyById     ← 卡多出这两项
→ _totalSupplyAll
→ activeMembershipId
→ ...
→ totalActiveMemberships
```

### 后果

- 模块写入 `activeMembershipId[acct]` 时，实际写入的是卡的 `_totalSupplyById` 等错误 slot
- 模块写入 `totalActiveMemberships` 时，写入的 slot 与卡中 `totalActiveMemberships` 所在 slot 不一致
- 因此 `totalActiveMemberships` 和 `activeMembershipId` 在卡上始终为 0

### 证据

- `MemberNFTIssued` 事件正常发出 → 模块执行了 `_issueFromPointsDelta` 和 `_activateIssuedMembership`
- `totalMembershipIssued` 正确增加 → `_recordMembershipIssuedTotal` 写入的 slot 与卡中该变量一致
- `totalActiveMemberships` 和 `activeMembershipId` 为 0 → `_setActiveMembershipWithCounters` 写入的 slot 与卡中对应变量不一致

---

## 3. 修复建议

1. **统一 storage layout**：使 `BeamioUserCard` 与 `BeamioUserCardBase` 在共享变量上的布局完全一致。
2. **可选方案**：
   - 让 `BeamioUserCard` 继承 `BeamioUserCardBase`，或
   - 在 `BeamioUserCard` 中显式声明与 `BeamioUserCardBase` 相同顺序的变量，并在需要处使用 `assembly` 或 library 访问共享 storage。
3. **验证**：修改后重新部署模块和卡，确认 `totalActiveMemberships` 和 `activeMembershipId` 能正确更新。
