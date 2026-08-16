# 实验室 G2 主机 `ownGroupId` → L1 登记 tx（2026-08-16）

- **Canvas 标识：** 无独立交互 Canvas
- **日期：** 2026-08-16
- **状态：** **已完成。** `lab:deploy-m6` keep + `lab:accept-m6` 通过。G2 `hop1.ownGroupId` / 两边 `liveGroupIds` 已 emit 登记 tx `0xf781f2c23fe3b3dac09dc3e1929016b0af200ee93978e916df64d750876d5153`。**不是** 30 天资格，**不是** 生产 DePIN。
- **规范优先级：** 英中白皮书 §5.2.0d / §5.2.0e > `runtime/RULES.md` §M6 > 本快照。本页不是第二份规范。

## 事实来源

- 前置登记：`src/canvas/dle-lab-g2-l1-register-2026-08.md`（block **868793**，GARR 代理未重部署）。
- 部署：`npm --prefix src/conet-layer2 run lab:deploy-m6`（G2 7/7 keep + G1 7/7 keep；**未** wipe data）。
- 验收：`npm run lab:accept-m6` → `ok: true`。
- G2 `hop1.ownGroupId` = `0xf781f2c2…876d5153`。
- G1 `hop1.ownGroupId` = `0x3076a806…6f2ad0`。
- 两边 `liveGroupIds` = `[G1 引导 tx, G2 登记 tx]`，`liveGroupCount === 2`。
- Evidence：`g2OwnGroupIdIsRegisterTx: true`，`g2GroupIdIsLabHash: false`，`twoGroups: true`，`planeFacts: true`。
- Marker 仍 `hit`：`6000000006` / `0x7ca21e5a…e2345c`（G2 this-group hit；G1 this-group notFound；G1 plane hit）。
- `seedLabFissionMarker` 再播种：locator 已存在且 NFT 匹配 → first-write-wins，**不** `putBody`（避免 freezer `ERR_FREEZER_APPEND_ONLY`）。

## 假设

- 不重启 geth / beacon / validator。
- 不重部署 GARR，不再跑 `CONFIRM_REGISTER_G2=1`。
- **禁止**用登记 tx 重算裂变 marker。
- HMAC / HTTP `:27101` / lab beacon 仍不是生产 DePIN。
- 本 cutover **不**开 30 天资格时钟，**不**接生产 EIP-712 / gossip / CL RANDAO。

## 公式 / 数据

```text
user-visible G2 ID = 0xf781f2c23fe3b3dac09dc3e1929016b0af200ee93978e916df64d750876d5153
alias               = laboratory keccak 0x7b3b8eb9…7f9b1a07 / "2" / "0x2"
marker seed         = laboratory keccak (not the register tx)
marker hash         = 0x7ca21e5aa612caa12bbd137aa374d30a113d42c1f60ea411fdb6998a63e2345c
marker NFT          = 6000000006
```

## 冻结结论

1. **主机 emit 必须是 L1 登记 tx。** 实验室 keccak 只做 alias / marker 种子。
2. **keep-deploy 不得改写已播种 marker。** 同一 hash + 同一 NFT 再 seed 是 no-op。
3. **G1 keep 不得 wipe。** on-demand 30 / newchain-user / NFT 42 BFT 仍在第一组。
4. **诚实口径。** 身份环收口仍不是 30 天资格，也不是生产 DePIN。

## 替代关系

- 关闭 `dle-lab-g2-l1-register-2026-08.md`「下次 deploy-m6 才换 ownGroupId」。
- 不替代 §5.2.0d 生产跨组 proxy / DePIN 传输。
- `dle-lab-m6-fission-2026-08.md` 保持「当时用实验室 hash」的历史事实。

## 未决项

- 生产 DePIN 传输替换实验室 HTTP `:27101`。
- 生产 EIP-712 / corpus SSZ Archive Certificate。
- §7.8.1 CL beacon / `pilotStartedAt` / 30 天资格计数。

## 实现检查表

- [x] `keepUpdateG1PlaneDirectory` 显式 `ownGroupId` = G1 引导 tx；G2 emit 登记 tx
- [x] `acceptM6Plane` 拒绝 G2 keccak `ownGroupId`
- [x] marker 再播种 first-write-wins（`runtime/test/m6-plane.test.ts`）
- [x] `lab:deploy-m6` + `lab:accept-m6` 通过
- [x] runtime / Explorer / GitBook / 英中白皮书去掉「主机仍 emit keccak / 登记仍待做」
- [x] **未**宣称 30 天资格
