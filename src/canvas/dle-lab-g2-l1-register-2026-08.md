# 实验室 G2 L1 `registerLiveGroup`（2026-08-16）

- **Canvas 标识：** 无独立交互 Canvas
- **日期：** 2026-08-16
- **状态：** **已完成。** L1 登记 tx `0xf781f2c23fe3b3dac09dc3e1929016b0af200ee93978e916df64d750876d5153`（block **868793**）。用户可见第二组 Group ID = 该 tx。**不是** 30 天资格，**不是** 生产 DePIN。
- **规范优先级：** 英中白皮书 §5.2.0d / §5.2.0e > `GlobalArchiveRoutingRegistryV1` > 本快照。本页不是第二份规范。

## 事实来源

- 代理（canonical）：`0x8B261eAECdFfeE9e7aC9fFe73386B0d6C9E76AfB`（**未**为 G2 重部署；代理已 verified）。
- 证据：`src/conet-layer2/pilot/evidence/conet-dle-g2-l1-register-2026-08/g2-l1-register.json`。
- Blockscout：`https://mainnet.conet.network/tx/0xf781f2c23fe3b3dac09dc3e1929016b0af200ee93978e916df64d750876d5153`（`status: ok`，`method: registerLiveGroup`）。
- G1 已登记：uint `groupId=1`，用户可见 Group ID = `0x3076a806…6f2ad0`。
- G2 实验室 keccak（登记前占位；现仅为别名）：`0x7b3b8eb959dcc0f75a309fcc16e7f840efe76dc27f2ef0d4eca8b8617f9b1a07` = `keccak256(utf8("dle.lab.group.m6.g2.v1"))`。主机已 emit 登记 tx（见 `dle-lab-g2-own-groupid-register-tx-2026-08.md`）。
- 链上 `liveGroupIds()` 仍返回 uint `["1","2"]`（存储键，不是用户可见 ID）。
- `archivesOf(2)` 已对齐 `src/conet-layer2/pilot/inventories/conet-dle-m6-g2-2026-08.json`。
- 裂变 marker 仍用实验室 keccak 做种子（`labFissionMarkerHash`），已播种 `0x7ca21e5a…e2345c`。**禁止**对登记 tx 重算 marker。

## 假设

- 不重启 geth / beacon / validator。
- 不重部署 GARR 代理。
- 不把 G2 钱包写进 G1 BFT `peers`。
- 登记当时 **不** rolling restart 14 台归档；Explorer / runtime `canonicalGroupId` 先把旧 keccak / `2` / `0x2` 显示成登记 tx。主机 emit cutover 见后续 canvas。
- HMAC / HTTP / lab beacon 仍不是生产 DePIN；本登记 **不是** 30 天资格。

## 公式 / 数据

```text
active[5]  = inventory role=active participantWallet
standby[2] = inventory role=standby participantWallet
groupKeyHash    = id("dle.lab.group-2.key")
membershipRoot  = id("dle.lab.group-2.membership")
standbyRoot     = id("dle.lab.group-2.standby")
keyEpoch        = 1
L1 uint         = 2
user-visible ID = 0xf781f2c23fe3b3dac09dc3e1929016b0af200ee93978e916df64d750876d5153
alias           = laboratory keccak / "2" / "0x2"
```

## 冻结结论

1. **L1 才是用户可见 Group ID。** 实验室 keccak 是登记前占位，现为别名。
2. **钱包必须未占用。** 已登记成功；**禁止**再跑 `CONFIRM_REGISTER_G2=1`。
3. **登记 ≠ 裂变重做。** \(G_e\) 实验室已是 2；L1 只补出生证。
4. **诚实口径。** 完成本里程碑仍不是 30 天资格，也不是生产 DePIN。

## 替代关系

- 关闭 `dle-lab-m6-fission-2026-08.md` / P6 canvas 里「G2 L1 仍待做」的开放项。
- 不替代 §5.2.0d 生产跨组 proxy / DePIN 传输。
- `dle-lab-m6-fission-2026-08.md` 保持「当时用实验室 hash」的历史事实。

## 未决项

- 主机 `ownGroupId` → 登记 tx：**已关闭**（2026-08-16 keep-deploy + `lab:accept-m6`）。见 `dle-lab-g2-own-groupid-register-tx-2026-08.md`。
- 生产 DePIN 传输替换实验室 HTTP `:27101`。

## 实现检查表

- [x] 链上只读预检通过
- [x] 脚本默认不发交易（须显式确认）
- [x] 登记 tx 成功且 `archivesOf(2)` 对齐 inventory
- [x] Explorer / GitBook / RULES 诚实改写
- [x] 英中白皮书 Revision 同步
- [x] **未**宣称 30 天资格
