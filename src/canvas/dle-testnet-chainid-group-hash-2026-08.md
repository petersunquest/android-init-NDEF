# CoNET-DLE Testnet EIP-155 vs Group ID = 登记交易 hash（2026-08-15）

- **Canvas 标识：** 无独立交互 `.canvas.tsx`（白皮书 / runtime 身份冻结快照）
- **日期：** 2026-08-15
- **状态：** **已写入** runtime / Explorer / GitBook / 英中白皮书 §5.2.0d；**未**部署 7 台实验室归档新包
- **规范优先级：** 英中白皮书 §5.2.0d > runtime `protocol.ts` / `hashLookup.ts` > 本快照。本页取代旧冻结「DLE Chain ID ≡ 整数 `groupId`」。

## 事实来源

- 用户：`0x44c45` 改为 **CoNET-DLE Testnet** 的全局 EIP-155 Chain ID；Group ID 用引导组 L1 **登记交易 hash**。
- 链上登记证明：`deployments/conet-GlobalArchiveRoutingRegistry.json` → `bootstrapGroup.registerTxHash` = `0x3076a806de71ab75b2d48063cc3f1e7d8f8e3d54cb1d45a7469c75c9276f2ad0`。
- L1 Solidity 今日仍用 uint `groupId = 1`（`archivesOf(1)` / `nextGroupId`）。**未改**已部署合约。
- 实验室 7 台归档现役 `eth_chainId` 已是 `0x44c45` / `281669`（改数字会对不上）。这是 **已观测** 的实验室 RPC 值，不是新猜的 id。
- 旧实验室字符串 `dle.lab.group.v1` 曾出现在 `/health` `liveGroupIds`；runtime 现用 `canonicalGroupId()` / `sameGroupId()` 兼容。

## 假设

- 数值保持 `0x44c45`：只改语义标签，不改实验室 chain id 数字。
- 用户可见 Group ID = **该组成组那笔 L1 register tx** 的 hash，不是 uint `1`，也不是 EIP-155。
- 裂变组必须用**自己的** register tx hash；在拿到新 hash 之前，`dle.lab.group.v2` 可暂留。
- 门面映射：uint `1` / `0x1` / `dle.lab.group.v1` → bootstrap register hash。
- 白皮书写协议结论，**不写** Home UI 文案。

## 公式 / 数据

| 标识 | 值 | 用途 |
| --- | --- | --- |
| EIP-155 Chain ID | `281669` / `0x44c45` | `eth_chainId` / `net_version` / 钱包区分本平面 |
| `chainName` | `CoNET-DLE Testnet` | facade / Explorer 标签 |
| 用户可见 Group ID | `0x3076a806…6f2ad0` | `liveGroupIds` / `route()` 门面 |
| L1 uint 存储键 | `1` | Solidity `archivesOf` / `archiveGroupId[tokenId]` |
| CoNET L1 | `224422` | 结算层；不是 DLE 平面 id |

```text
canonicalGroupId("dle.lab.group.v1") = registerTxHash
canonicalGroupId("1") = registerTxHash
canonicalGroupId("0x1") = registerTxHash
sameGroupId(legacy, registerTxHash) = true
sameGroupId("dle.lab.group.v2", registerTxHash) = false
```

- **确定性映射**（代码常量，非链上实测公式）。
- **不可测 / 未部署：** 7 台归档未发版前，线上 `/health` 仍可能返回 `dle.lab.group.v1`。

## 冻结结论

1. **EIP-155 Chain ID** 是本 DLE 平面的唯一 uint；钱包与 `eth_chainId` 用它区分链。Testnet = `0x44c45`。
2. **Group ID** 是该归档组的 L1 register tx hash。`route(chainNftId)` 门面返回这个 hash，不是 EIP-155。
3. **L1 uint `groupId`** 只是注册表存储键（引导组 `1`），不得展示为 Group ID。
4. 裂变：新组用自己的 register tx hash；解散后不得复用该 hash 或该 uint。
5. 外组代理比较的是 **Group ID**，不是 chain id。
6. 已部署 L1 Solidity 与 `pilot/evidence/**` **不改**。

## 替代关系

- 取代白皮书 / GitBook 旧句：「协议 DLE Chain ID = 归档整数 `groupId`」「实验室 `0x44c45` 不是 DLE Chain ID」。
- 不推翻 §5.2.0e：hash-only 仍必须先击中 `chainNftId`；组仍是 `route(nftId)` 派生量。
- 不推翻全局 RPC 跨组代理；只把比较键从 uint / 旧字符串换成 register hash。

## 未决项

- 7 台实验室归档发版后，`liveGroupIds` 才会从 `dle.lab.group.v1` 变成 hash。
- L1 合约若日后增加 `registerTxHash` 字段，须另开升级任务；今日仅门面映射。
- 裂变组 `dle.lab.group.v2` 在没有自己的 L1 register tx 前保持字符串。

## 实现检查表

- [x] runtime `DLE_TESTNET_CHAIN_ID` / `DLE_TESTNET_CHAIN_NAME` / `DLE_LAB_GROUP_ID` = register hash
- [x] `canonicalGroupId` / `sameGroupId`；Explorer 独立拷贝常量
- [x] facade `chainName`；Home 胶囊标签 **Group ID**
- [x] `npm run runtime:test` 61/61
- [x] GitBook explorer / routing-registry / design-thesis / archive-plane / README
- [x] 英中白皮书 Revision、摘要、术语、§5.2.0d、§5.2.0e、checklist、glossary
- [ ] 部署 / 重启 7 台实验室归档（本任务未授权）
