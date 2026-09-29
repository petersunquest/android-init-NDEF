# CoNET-DLE 30 天冻结终期评估（2026-09-23）

- **Canvas 标识：** 无新增可执行 Canvas；本页是终期评估 Markdown 快照
- **日期：** 2026-09-23（抽检 `2026-09-23T15:16:45.701Z`）
- **状态：** **部分成功 / 未通过资格，并发现 roster/readiness 计数边界漂移**
- **规范优先级：** 当前代码与英中白皮书 / 独立规范 > 本快照

## 事实来源

- 原始终期证据：`src/conet-layer2/pilot/evidence/conet-dle-p23-live-2026-08/runtime-review-2026-09-23Tpostwindow.json`
- 开钟：`2026-08-18T09:53:58.092Z`
- 名义 30 天终点：`2026-09-17T09:53:58.092Z`
- 代码语义：
  - `runtime/src/archive/pilotClock.ts`
  - `pilot/src/gate.ts`
  - `runtime/src/archive/inventoryFreeze.ts`
  - `runtime/src/archive/syncQualification/types.ts`
- 历史对照：`dle-30d-freeze-midwindow-assessment-2026-09-01.md`

## 实测事实

正式七席在终期抽检时：

| 指标 | 结果 |
|---|---:|
| HTTP、时钟对齐、sticky operator freeze | 7/7 |
| `leafCount=9750` | 7/7 |
| seating `QUALIFIED` | 7/7 |
| `pilotQualified=true` | 0/7 |
| `lastQuorumOk=true` | 3/7（fd-01、fd-04、fd-06） |
| fd-05 peer | 0 |
| `officialStandbyReadyCount` | 4（7/7 均如此报告，但不是四个 official standby） |
| BFT started / hash index committed in AC / production \(C_G\) available | 0/7 |

现场 `syncRoster` 为 9–10 项，包含 extra `fd-08`、`fd-09`、`fd-10`，且不同节点的 roster 视图不完全一致。

## 代码语义与边界

1. `pilotClock.ts` 的 operator health 门面固定返回 `pilotQualified:false`；墙钟结束不自动改变资格。
2. `pilot/src/gate.ts` 的真实资格还要求 30 天、100 rotations、30 re-homes、100 takeovers。本次没有这些计数的终期完成证据。
3. `inventoryFreeze.ts` 只阻止新的 hash catalogue writes；replay / catch-up 的 `putLocator` 仍允许。因此 **inventory freeze 不是 roster freeze，也不是库存字节绝对不变**。
4. `isOfficialStandbyRole` 只排除 `fd-08`；Seoul extra standby `fd-09` / `fd-10` 进入计数，造成 `officialStandbyReadyCount=4`。正式冻结边界仍是 5 active + 2 official standby。

## 冻结目标判定

### 成功项

- 正式七席保持同一开钟时间、operator freeze sticky、`leafCount=9750` 和 seating `QUALIFIED`。
- Explorer 的非绿色 clock / readiness 诚实语义仍成立：时钟、heartbeat 与 seating 没有被误写成 production qualification。
- 冻结轨证明了实验室控制面的可持续性，但只在其定义边界内成立。

### 未通过项

- `pilotQualified` 仍为 0/7。
- 真实资格计数没有终期闭合证据。
- heartbeat quorum 只有 3/7，fd-05 peer=0。
- roster 已越出冻结的正式 5+2 边界，且 readiness 分类把 extras 计入 official 数。
- BFT、AC hash-index commitment、production \(C_G\) 均未启动或可用。

## 风险

- **计数误导：** UI 或运维若把 `officialStandbyReadyCount=4` 当成四个正式 standby，会扩大治理边界。
- **冻结误读：** 把 inventory freeze 当 roster freeze，会掩盖 extras 加入和不同节点 roster 分叉。
- **时间替代资格：** 仅因 30 天已过就自动解冻、晋升或启 signer，会绕过真实 gate。
- **可达性退化：** 3/7 quorum 和 fd-05 peer=0 说明 seating certificate 不能替代持续网络健康。

## 冻结结论

**终期总评：部分成功，但未通过资格。** 30 天墙钟已结束；这只证明观测窗口结束，不证明 `PilotQualificationGate` 通过。当前状态不得自动进入生产。

## 禁止操作

- 不自动解冻。
- 不自动把 extra / standby 升为正式席位。
- 不启动 production signer。
- 不宣称 production readiness、production AC 或 production \(C_G\)。
- 不发明 P26。

## 后续检查项

- 修正 official standby 分类，使正式 5+2 与 extras 明确分离。
- 对齐并冻结 roster 的规范来源，解释 9–10 项视图差异。
- 取得 rotations / re-homes / takeovers 的可复核终期证据。
- 单独处理 fd-05 peer=0 与全组 heartbeat quorum；不得用 seating 绿点覆盖该风险。
- 在修复后重新做只读资格评估；任何解冻、晋升或 production 启用须另有显式授权和完整 gate 证据。

## 替代关系

- 本页替代 2026-09-01 中期评估作为当前冻结结论。
- 中期评估保留为历史瞬时证据，不再作为当前 verdict。
- 本结论已同步到英中 L2 白皮书、GitBook L2 honesty track / developer pages，以及 runtime / Explorer 守则与 README。

## 实现检查表

- [x] 分离实测事实与代码语义
- [x] 分离 inventory freeze 与 roster freeze
- [x] 记录 standby count=4 的分类漂移根因
- [x] 明确 30 天墙钟不等于资格
- [x] 未授权解冻、晋升、production signer、SSH、重启或 wipe
