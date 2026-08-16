# 实验室 P6：新链创世协议化（2026-08-16）

- **Canvas 标识：** 无独立交互 Canvas
- **日期：** 2026-08-16
- **状态：** **2026-08-16 live keep 已过**：`lab:deploy-m6` `ok: true`；trade 新链 7/7 \(Q_V\) + 约 10s 独立 AC；NFT 42 tip 仍为 `0x1`。**不是** L1 出生证 / **不是** 30 天资格。
- **规范优先级：** 英中白皮书 §5.2.0e / §15.20 > runtime `RULES.md` §「Lab new-chain HTTP plane」> 本快照。本页不是第二份规范。

## 事实来源

- 白皮书创世两层：验证人 \(Q_V=5/7\) + 托管归档 \(Q_A=4/5\) PrevoteQC → PrecommitQC（= AC）。
- 实验室此前只有 Mode A replay + `DleLabGenesisCertificateV1` stub（`notArchiveCertificate: true`），**不是** AC。
- Runtime：`validatorQuorum.ts`（确定性 HMAC 委员会）、`genesisBft.ts`（每链独立票图 + `POST /newchain/bft`）、`newchain/engine.ts`（accept 必须 \(Q_V\)；先编目 `tipStateRoot`；AC 后再编真 `kind=ac`）。
- Locator：`labChainObjectLocator(kind, hash, chainNftId, …)` — **禁止** `labAcLocator()`（写死 NFT 42）。
- 测试：`runtime/test/validator-quorum.test.ts`、`runtime/test/newchain-genesis-bft.test.ts`、`runtime/test/newchain.test.ts`。`npm run runtime:test` 须全绿。

## 假设

- 实验室 HMAC ≠ 生产 secp256k1 / EIP-712。
- 不改 5+2 名册，不第二组裂变，不宣称 30 天资格。
- G2 `enableBft: false`：只做 Mode A + \(Q_V\)，不 gossip 新链 AC。
- 旧 `newchain-state` 无 P6 字段 → legacy（不重写假 AC、不跑 BFT）。
- 不重启 geth / beacon / validator。

## 公式 / 数据

```text
Q_V: 7 validatorId derived from requestId; domain dle.lab.validator.mac.v1|{id}
     bind requestId + valueHash + tipStateRoot + bodyCommitment
     accept iff ≥5 valid HMAC
Q_A: per chainNftId, 4-of-5 PrevoteQC → PrecommitQC
     gossip POST /newchain/bft  schema DleLabNewChainBftMessageV1
chainNftId = 1000 + keccak % 998_999_000   ≠ 42
accept MUST NOT index valueHash as kind=ac  (freezer append-only)
new-chain AC MUST NOT write syntheticTipBlock / update NFT 42 eth_blockNumber
Clusters = G_e  (new chains copy NFT 42 wallets into same ownGroupId)
```

组网单测：5 active + 2 standby；新链 AC `nft ≠ 42`；NFT 42 engine 无证书。本地单测可用 `eth_blockNumber ≠ 0x1`；**线上 NFT 42 tip 就是 `0x1`**，live 验收只断言 **tip 不变**。

Live smoke（`p6-live-accept.json`，`acceptedAt=2026-08-16T19:12:11.677Z`）：

```text
requestId     = 0x6bec775648b2f8b9b27918734ac240bf9ec110a1efd5a95118012de71dd4e6a1
chainNftId    = 326990096   ≠ 42
valueHash     = 0x32788cf04183a3440d1c63aecbdca58fd01997a1082a2fb2642a172ca90cc5ff
tipStateRoot  = 0x1549535af4b03f378f577ea701a14bfc889c6a68cc4ba04daf39927322088065
Q_V schema    = DleLabValidatorQuorumV1
AC schema     = DleLabArchiveCertificateV1
certified     = fd-01…fd-07  (4-of-5 active; fd-01 本机 5 signer，其余 adopt 4)
tipBefore/After = 0x1 × 7
liveGroupCount  = 2 × 7
nft42 AC        = true × 7
```

## 冻结结论

1. **两层缺一不可（新 accept）。** Mode A 成功之后必须 \(Q_V\)；G1 再对该 `chainNftId` 形成独立 AC。
2. **隔离。** 新链票不得进入 `/bft/message` 或 `bft-state.json`。
3. **编目顺序。** 先 `tipStateRoot`；真 AC 形成后再 `kind=ac`。禁止把 stub 写成假 AC。
4. **诚实口径。** 完成本里程碑仍不是 L1 出生证，也不是 30 天资格。

## 替代关系

- 替代 `dle-lab-newchain-genesis-user-2026-08.md` 里「`notArchiveCertificate` 即合格」的口径。
- 不替代 M6 裂变、M7 typed roots、§5.2.1 生产 Tendermint 语料。

## 事故（2026-08-16 keep 发版）

`lab:deploy-archive-keep` 后 fd-03（`198.251.77.98`）与 fd-05（`170.205.39.67`）进程在听 `:27101`，但 localhost `/health` 30s 仍 0 字节。CPU 84–96%，ESTAB 260–340，listen backlog 260+。根因：`hashStore` 每次 Get 整文件读盘 + P6 load 对 700 条 `indexRouteAndTip` + `/health` 当场重算 Merkle；弱机事件循环饿死。`liveGroupCount` 被 keep 脚本打回 1（未带 `planeDirectory`）。**不**重启 geth/beacon/validator。

修复：内存 KV；load 只 `registerLabChainNft`；心跳 `/liveness`；`hashIndex` / extraHealth 缓存；`newchain-state` 原子写入 + 2s persist 防抖；**分批 gossip**（pending 3 + certified 2；空闲 certified 3 / 5s）；出证后单 topic 广播；同槽同 mac / 已出证票 **不 persist**。恢复平面须 `lab:deploy-m6`（**禁止**再跑 `lab:deploy-archive-keep`，会抹 `planeDirectory`）。

## 未决项

- G2 L1 `registerLiveGroup` — 已由 `dle-lab-g2-l1-register-2026-08.md` 关闭（tx `0xf781f2c2…876d5153`）。
- Explorer / GitBook 公网 Certificates 展示 P6 计数（本任务发版）。
- 生产 secp256k1 / DePIN 传输替换实验室 HMAC / HTTP。

## 实现检查表

- [x] \(Q_V\) HMAC stub + 不足 5 票拒绝
- [x] 每链独立 4-of-5 AC；`chainNftId ≠ 42`
- [x] accept 不把 `valueHash` 立刻编成 `kind=ac`
- [x] G2 `enableBft: false` 不跑新链 gossip
- [x] runtime 单测 80 绿
- [x] 英中白皮书 §5.2.0e / §15.20
- [x] runtime / daemon / explorer RULES + Cursor 镜像
- [x] Keep 发版 G1/G2（`lab:deploy-m6`）+ live smoke + `p6-live-accept.json`
