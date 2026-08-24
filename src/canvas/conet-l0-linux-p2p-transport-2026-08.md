# CoNET L0 Linux P2P 传输模块（调研）

> **单语开发参考，无对等译本。** 交互 Canvas：`conet-l0-linux-p2p-transport-2026-08.canvas.tsx`。本快照是架构调研，不是 L0 协议规范，也不是 `developers/l1-node.md` 的替代。实现时以当前 GitBook L0、CoNET-SI 源码与 L1 端口表为准。

**Canvas 标识：** `conet-l0-linux-p2p-transport-2026-08.canvas.tsx`  
**快照日期：** 2026-08-17  
**状态：** 2026-08-17 crate `src/conet-l0d`（`cargo test` 通过）+ GitBook Applications/Developers 已落地（含 example TOML / systemd）；**未**改 SI 命令、**未**改 geth/beacon/va、**未**测 L0 hop RTT、**未**跑 `deployGitbook.sh`

## 目标

在**不改** geth / Prysm `beacon-chain` / `validator` 源程序的前提下，新增 Linux **用户态**通讯模块：绑定聆听 CoNET DePIN（L0），用 `web3://<钱包>` 或 `web3://<beamioTag>.web3` 作为主机/client 身份，再配合 iptables / TUN，让 L1 节点 P2P 走钱包寻址而不是（或不只是）公网 `IP:port`。

## 事实来源（已核对代码 / 公开书）

| 来源 | 用到的事实 | 类型 |
| --- | --- | --- |
| `src/docs/gitbook/l0/using-l0.md` | L0 是 PGP/钱包转发平面；HTTP `/post` 只能 `{ data }`；节点间 HTTP :80 | 现行规范 |
| `src/docs/gitbook/l0/tcp-ip.md` | L0 **不是**第二套 IP 网；UDP forward 不是到 B 的原始 OS UDP | 现行规范 |
| `src/docs/gitbook/l0/udp-forward.md` | AES-256-GCM 帧；payload ≤ 12000 base64；空闲 10 min；无重传/拥塞控制 | 现行规范 + 实现 |
| `src/CoNET-SI/src/util/udpForward.ts` | 会话上限 16/64/256；池与 chat/mining 分离 | 实现 |
| `src/docs/gitbook/l0/wallet-address-p2p.md` | 身份 = EOA + user PGP + route PGP；@tag 须精确匹配 | 现行规范 |
| `src/docs/gitbook/applications/silentpass-vpn.md` | SilentPass / `SaaS_Sock5` = **出口**连公网 `host:port` | 现行规范 |
| `src/CoNET-SI` `SaaS_Sock5_v2` | 同节点 `Securitykey` 套接字拼接；60s 等待；付费准入 | 实现（模式可参考，产品不可复用） |
| `src/docs/gitbook/developers/l1-node.md` | geth **8400** TCP+UDP；beacon **4200/4300**；Engine/RPC 必须 loopback | 2026-08-17 生产参考 |
| AddressPGP | `0x684b0ac760cEE9c9b85de36d69746420648Cf9e2` | 链上常量 |

**不是实测：** 本调研没有对 L0 hop 做新的 RTT / 丢包测量。文中 50–800 ms 是按 HTTP/SSE 多跳的工程估计，标为**假设**。

## 假设

1. 操作员接受 Phase 1 用 **静态 overlay 对等**（关掉或弱化 discv4/discv5），而不是第一天就透明劫持全部 UDP。
2. 生产提议者仍保留至少一条**公网 P2P**（混合模式）。L0-only 对 6s slot 的 attestation 窗口是未验证风险。
3. 每台 L1 主机有独立 **routing EOA**（AddressPGP），与 validator keystore / fee recipient **不是同一把钥匙**。
4. 不重启、不 wipe 任何 geth / beacon / validator（`critical-chain-infra-restart-requires-approval`）。
5. `web3://` 在本设计里是 **peer locator**，不是 ERC-4804 合约内容 URI。

## 公式 / 数据

| 项 | 值 | 性质 |
| --- | --- | --- |
| L1 `chainId` | 224422 | 规范 |
| geth P2P | 8400 TCP+UDP | 2026-08-17 L1-node 表 |
| beacon P2P | 4200 TCP / 4300 UDP | 同上 |
| UDP 帧上限 | 12000 base64 ≈ 9 KiB 明文量级 | 由规范推出 |
| 空闲踢会话 | 10 min | 规范 |
| Slot | 6 s | `config.yml` |
| Overlay 建议 | `100.64.0.0/10` 或 `fd00:web3::/48` | 设计选择，未部署 |
| L0 额外时延 | 50–800 ms（估计） | **未测** |

确定性关系：

```text
resolve(web3://host/p2p/service)
  host is 0x+40hex → EOA
  host ends with .web3 → exact BeamioTag → EOA
  → searchKey(EOA) → userPGP + mailbox B
  → allocate/lookup overlay vIP
  → geth/beacon 只看见 vIP:port
```

## 冻结结论

1. **做用户态守护进程 `conet-l0d`，不要改客户端源码，也不要做内核模块。** geth/beacon 只改启动参数（`--nat=extip:<own-vIP>`、bootnodes / `--peer` 写成 overlay 地址）。
2. **Validator 不进捕获面。** 它只连本机 beacon。模块“支持 VA”= 给 beacon 提供对等，而不是代理 validator gRPC。禁止把 keystore 读进 `conet-l0d`。
3. **禁止把 SilentPass / `SaaS_Sock5` 当 L1 P2P。** 那是出口上网，会在 egress 暴露 `host:port`，不是钱包寻址。
4. **现有 UDP forward 不能当 OS UDP。** 不能对 `0.0.0.0/0:8400/udp` 做盲目 REDIRECT。Phase 1 = TCP 管道 + 静态节点；Phase 2 再做 datagram 适配器。
5. **身份：** `web3://0x…/p2p/geth` 与 `web3://<tag>.web3/p2p/beacon`。@tag 必须精确匹配。AA 无 AddressPGP 则不是目的地。
6. **iptables 铁律：** 先 `RETURN` `127.0.0.0/8`；永不 mark `validator` uid；只把 **overlay 前缀** 送进 TUN。混合模式下不要劫持全部公网 8400/4200/4300。
7. **聆听：** 模块自己做 L0 bind+listen（加密给 B route PGP，HTTP 经 C ≠ B）。建议新 `listenKind: "l1p2p"`，不得进 chat/mining 池。
8. **Phase 1 需要一条钱包对钱包的 TCP 字节流**（新应用组合）。可选低时延模式：参考 `SaaS_Sock5_v2` 的同节点 splice，但必须是显式模式，不能当默认隐私路径。
9. **生产安全路径是混合：** 公网 P2P 保 slot 关键 gossip；L0 给 NAT / 无公网 IP / 备份对等。
10. 独立子项目 `src/conet-l0d/`，禁止 `../..` import。白皮书 / RULES / MVP 变更须同任务写 GitBook **Applications + Developers**（`applications/conet-l0d.md`、`developers/conet-l0d.md`）。若新增 SI 命令，再同任务写 L0 协议页。不新建域名。

## 替代关系

| 方案 | 结论 |
| --- | --- |
| 改 geth/beacon 加 SOCKS / 自定义 transport | 拒绝。用户约束是零源码改动。 |
| 全流量 iptables REDIRECT 到现有 UDP forward | 拒绝。语义不是 raw UDP，且会误伤 loopback。 |
| SilentPass VPN 套在节点上 | 拒绝。方向是 egress，不是 peer 钱包。 |
| 仅 TPROXY、不分配 overlay IP | 可做备选，但 geth 仍需要可广告的 `IP:port`；TUN + vIP 更干净。 |
| L0-only、关掉全部公网 P2P | 仅实验。未测 attestation 时延前不得当生产默认。 |
| ERC-4804 `web3://` 内容寻址 | 不采用。本 URI 只做 peer locator。 |

## 未决项

- [ ] 是否在 SI 增加正式 `p2p_stream_*` / `listenKind: l1p2p`，还是 Phase 1 先在现有 listen + 自研组帧上跑。
- [ ] Overlay 用 IPv4 CGNAT 还是 IPv6 ULA（geth enode 对 IPv6 的支持需按所用 geth 1.17.x 再确认）。
- [ ] 枢纽节点是否愿意登记 routing 钱包并发布 `web3://` 静态表（否则新节点无法发现第一批 overlay bootnode）。
- [ ] 实测：同城 / 跨区 L0 TCP pipe RTT、丢包、对 beacon gossip 延迟的影响。
- [ ] GB 计量：L1 P2P 字节是否走现有 hop-sig 用户钱包扣 GB。

## 实现检查表（若开做）

- [x] 独立 crate `src/conet-l0d`（Rust），不引用 SilentPassUI / x402sdk。
- [x] GitBook Applications + Developers 操作员/开发者页（2026-08-17）。
- [ ] routing EOA + PGP 仅模块持有；日志不含私钥 / 完整 armor / AES key。
- [ ] `listenKind` 与 mining/chat/udp 池隔离；禁止 `readableEnded` 误踢。
- [x] 解析 @tag 用精确匹配，禁止 `results[0]`（locator 单元测试）。
- [x] iptables：loopback RETURN、排除 validator、只路由 overlay（daemon 拥有链）。
- [x] geth `--nat=extip` 与 beacon `--p2p-host-ip` 等于 **本机 overlay vIP**（文档）。
- [x] 不重启 EL/CL/VA；不暴露 Engine / JWT。
- [ ] 新增 SI 命令则同步 GitBook L0 + developers + 两页 conet-l0d（**尚未新增**）。

## 与白皮书

本结论是 **L1 节点运维 + L0 应用组合**，不改变 CoNET-DLE 白皮书条款。产品白皮书在 `src/conet-l0d/whitepaper/`（英中成对，Revision 2026-08-17）。公开 how-to：`src/docs/gitbook/applications/conet-l0d.md` 与 `src/docs/gitbook/developers/conet-l0d.md`。
