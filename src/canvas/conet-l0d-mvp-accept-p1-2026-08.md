# conet-l0d：crate MVP 验收 + P1 出站 / 入站 / listen worker（crate 内；实验室二进制 `[l0]` 关）

> **单语开发参考，无对等译本。** 交互 Canvas：`conet-l0d-mvp-accept-p1.canvas.tsx`。本快照不是 L0 协议规范，也不是 SI 命令表。规范以英中白皮书、`docs/MVP.md`、`docs/P1.md`、GitBook Applications / Developers 为准。

**Canvas 标识：** `conet-l0d-mvp-accept-p1.canvas.tsx`  
**快照日期：** 2026-08-17  
**状态：** crate MVP **已验收**；P1 出站 **已在 crate**；P1 入站解密 + TUN 写回 **已在 crate**；P1 listen HTTP+SSE worker **已在 crate**（mock 测过、未签 `mining`）；`[l0]` **默认关**；实验室二进制将再装一次且 **不**开 `[l0]`；**未**打开生产 SI listen；**未**改 advertise 为 vIP；**未**改 SI。`.98` geth 已于 **21:47:24Z** 由既有 load watchdog 拉起（早先 21:40Z 因 `load15>2.11` 停机，**不是** l0d 导致）。

## 目标

1. 诚实验收本阶段：crate 生命周期 + 两机公网互为 peer + overlay TUN 桩。
2. 按白皮书 §10 推进 **P1**：在现役 `/post` + OpenPGP + A/B/C 上做钱包对钱包 TCP 字节流，而不是新 SI 命令。
3. 同一任务把「crate 已有出站 encrypt+wrap+POST、入站解密+TUN 写回、**以及** listen HTTP+SSE worker（mock、未签）/ 未打开生产 SI listen / 实验室可装二进制且 `[l0]` 关」写回白皮书、P1 成对页、RULES、GitBook Applications + Developers，并按用户要求 git push + 部署。

## 事实来源

| 来源 | 用到的事实 | 类型 |
| --- | --- | --- |
| 两机 SSH 探针 | 2026-08-17 **21:36Z** 验收；**21:43Z** 部署后复测；**21:50Z** geth 恢复后复测 | **真实实测** |
| `.50` / 本机 `cargo test` + `cargo build --release` | 本档 `cargo test` **43** passed（38 unit + 5 integration）；release 将再编 | **真实实测** |
| `deployGitbook.sh` | 上一轮 exit 0；本轮文档更新后再发 | **真实实测**（上一轮） |
| `whitepaper/conet-l0d.md` §10 | MVP / P1 / P2 / P3 分期 | 规范 |
| `docs/MVP.md` / `docs/P1.md` | 验收范围与 P1 线合同 | 规范 |
| GitBook Applications / Developers `conet-l0d` | 操作员 / 开发者 how-to | 公开书 |
| AddressPGP | `0x684b0ac760cEE9c9b85de36d69746420648Cf9e2` | 链上常量 |

**不是实测：** overlay TCP 送达、生产 SI mailbox 往返、生产 SI listen、L0 hop RTT、EL 追上 tip。

## 假设

1. 实验室 locator `0x1111…` / `0x2222…` **没有**真 AddressPGP。出站需要 `[[peers]]` 静态 armored **user + route** 公钥文件。
2. Listen 在专用 SI `listenKind: l1p2p` 存在之前，复用 `mining` + `listenKind: chat`，且必须用 **专用 routing EOA**（≠ Chat 钱包、≠ deposit、≠ fee recipient）。B 可解密的 listen 命令 **不得**带 `Securitykey`。
3. 在双向 overlay 帧写入对端 TUN 之前，geth/beacon 通告保持**公网 IP**。
4. 不重启、不 wipe 链进程；不开启 `[l0]`；不向生产 SI POST。

## 公式 / 数据

实验室探针（墙钟 **21:50Z**，`.98` geth 已恢复）：

| 主机 | overlay vIP | geth | beacon | l0d | `[l0]` |
| --- | --- | --- | --- | --- | --- |
| `74.208.224.45` | `100.64.0.5` | 1.17.3 · 9 peers（含 `.98:8400`）· `0x0` | v7.1.4 · head 679775 · dist 258073 · 15 peers | pid 863022 · TUN UP | 关 |
| `198.251.77.98` | `100.64.0.6` | **已恢复** 21:47:24Z；7 peers（含 `.45`）；EL `0xcd4dc` / `0xd7fbc` | v7.1.8 · head 937848 · dist 0 · optimistic · 15 peers | pid 3310266 · TUN UP | 关 |

确定性关系（P1 出站 + 入站解密 + listen worker，已在 crate；生产 SI listen 未打开）：

```text
出站:
TUN IPv4
  → envelope { type: conet_l0d_overlay_v1, from, seq, ipv4: b64(raw) }
    → OpenPGP encrypt(peer user PGP) → innerArmor
    → mailbox-work { data: innerArmor, NoPush: true } encrypt(B route PGP) → outerArmor
    → POST { "data": outerArmor } to healthy entry A ≠ B

入站（crate 内；不打开生产 SI listen）:
user-PGP armor
  → decrypt → refuse mailbox-work JSON (NoPush)
  → envelope.decode → IPv4 sanity (len≥20, version=4)
  → mpsc try_send → TUN write

Listen（crate 内；mock 测过；未签 EIP-191）:
unsigned { command: mining, listenKind: chat, walletAddress, timestamp }
  → encrypt(this host B route PGP) → POST { "data" } to C ≠ B
  → SSE chunk → extract armor → apply_inbound_armor
```

HTTP 只能 `{ "data" }`。`NoPush` 只能进 B route PGP 工作包。出站 fail-closed：`[l0].enabled` + 对端 user PGP + 对端 route PGP + 至少一个 entry。入站 fail-closed：`[l0].enabled` + `routing_key_file` 为 OpenPGP **私钥**证书。Listen fail-closed：enabled + `listen_entries`（禁止回退出站 `entries`）+ `mailbox_route_pgp_file`（本机 B route **公钥**）+ `routing_eoa` + user 私钥。本修订 listen **无 EIP-191**；生产 SI `checkSign` 会拒。

## 冻结结论

1. **Crate MVP 通过。** TUN + iptables 生命周期、locator、静态对等表、收包计数、L0 桩 — 按 `docs/MVP.md` 验收。
2. **实验室阶段通过（公网面）。** 21:36Z 两机 geth+beacon 无 validator、公网互为 peer。21:40Z `.98` geth 被既有 load watchdog 停掉（非 l0d）。**21:47:24Z geth 已恢复**；21:50Z 两机再次互为 peer。advertise 仍是公网 IP。未授权不得重启/wipe 链进程。
3. **不得声称：** overlay 已转发 TCP；advertise 已切 vIP；EL 已同步；存在现役 SI `p2p_stream_*` / `listenKind: l1p2p`；生产 mailbox 已投递；生产 SI listen 已打开。
4. **P1 出站 + 入站解密/TUN 写回 + listen HTTP+SSE worker 已在 crate。** `cargo test` 43（38 unit + 5 integration）。Listen 未签 EIP-191。装二进制 ≠ 现役 mailbox 客户端。**未**打开生产 SI listen。
5. **通告铁律：** 双向 overlay 帧进对端 TUN 之前，`--nat` / `--p2p-host-ip` 保持公网 IP。
6. 白皮书 / RULES / MVP / P1 / CLI-config 语义已同任务写 GitBook Applications + Developers（及成熟度相关索引）。用户已要求跑 `deployGitbook.sh`。不扩写 mailbox-routing / SI 命令表。

## 替代关系

| 方案 | 结论 |
| --- | --- |
| 新 SI 命令 `p2p_stream_*` / `listenKind: l1p2p` 当现役 | 拒绝。未上线不得写入 current SI。 |
| 复用 UDP `udp_relay` 当 overlay TCP | 拒绝。那不是 raw OS TCP。 |
| 只加密给 user PGP 就 POST 到现役 SI | 拒绝（会 APNs 轰炸）。必须再 wrap 给 B route PGP。 |
| 在 B 可解密的 listen 命令里放 `Securitykey` | 拒绝。 |
| 实验室开启 `[l0].enabled = true` 并 POST 假 armor | 拒绝。 |
| 为试 P1 把 advertise 切到 vIP | 拒绝（会黑洞）。 |
| 把验收失败归咎于 overlay ping 100% loss | 拒绝。桩预期如此，不算 MVP 失败。 |

## 未决项

- 生产 SI listen（须 EIP-191 签 `mining`；专用 routing EOA；经 C ≠ B）。crate worker 已在，但未签，生产 `checkSign` 会拒。
- 证明双向帧后再讨论 advertise 切 vIP。
- EL 全量同步（与 overlay P1 独立；不要为追块重启/wipe）。

## 实现检查表

- [x] 两机只读验收（21:36Z）+ geth 恢复后复测（21:50Z）
- [x] `src/l0/{frame,envelope,post,address_pgp,client,pgp,listen}.rs` + `[l0]` 默认关
- [x] OpenPGP encrypt + mailbox wrap + POST `{ data }`（crate 内；`cargo test` 不打生产 SI）
- [x] 入站解密 + TUN 写回队列（crate 内；不打开生产 SI listen）
- [x] Listen HTTP+SSE worker（crate 内；wiremock；未签 `mining`）
- [x] `cargo test` 43（38 unit + 5 integration）
- [x] `docs/P1.md` + `.zh-CN.md`；白皮书 §10 双语；RULES；operator-flags 通告铁律
- [x] GitBook Applications + Developers + 成熟度索引
- [ ] 本轮实验室二进制再装且 `[l0]` 关（不重启 geth/beacon）
- [ ] 本轮 `deployGitbook.sh` + smoke
- [x] 未开 `[l0]` / 未改 SI / mailbox-routing
- [x] 未切 advertise 到 vIP
