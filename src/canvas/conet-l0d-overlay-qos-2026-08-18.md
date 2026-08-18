# conet-l0d：overlay 两端质量（2026-08-18）

> **单语开发参考，无对等译本。** 交互 Canvas：`l0-overlay-qos-both-ends.canvas.tsx`。可执行 `.canvas.tsx` 只在 Cursor 管理目录。本快照不是 L0 协议规范。规范以英中白皮书、`docs/P1.md`、`docs/P2.md` 为准。crate 仓库正文：[docs/lab-overlay-qos-2026-08-18.md](../conet-l0d/docs/lab-overlay-qos-2026-08-18.md)。

**Canvas 标识：** `l0-overlay-qos-both-ends.canvas.tsx`  
**快照日期：** 2026-08-18  
**状态：** **2026-08-18 18:56Z 实测。** mailbox 应用层零丢包；overlay TCP ~500 ms RTT + 乱序（非缺字节）；枢纽 `.98` TUN `tx_dropped=937`；不关闭 P1 追链；不是生产 discv5。

## 目标

1. 在通讯两端只读拉 log / TUN / `ss`，量化丢包与流量。
2. 区分 mailbox 应用层失败、overlay TCP 重传/乱序、TUN 内核丢包、isolate 公网 DROP、EL `0x0`。
3. 把结论写入 crate 文档并 git push，供后续对照。

## 事实来源

| 来源 | 用到的事实 | 类型 |
| --- | --- | --- |
| `.45` / `.98` SSH | 2026-08-18 **18:41:31Z–18:56:18Z** 本轮 `conet-l0d` 进程 log | **真实实测** |
| `ip -s link show conet-l0` | TUN RX/TX / `tx_dropped` | **真实实测** |
| `ss -tni` overlay | RTT / retrans / `rcv_ooopack` | **真实实测** |
| geth / beacon REST | peerCount、`connected`、`sync_distance` | **真实实测** |
| iptables isolate INPUT | 公网 `:8400/:4200/:4300` DROP | **真实实测**（不是 overlay 丢包） |

**不是 overlay 丢包：** isolate DROP、EL `eth_blockNumber=0x0`（CL 滞后）。

## 假设

1. `flushed for POST` = 入队，不是 HTTP 2xx。默认 `RUST_LOG=info` 看不到 inbound queued / POST accepted（debug）。失败只看 warn 计数。
2. Linux TUN TX = 内核 → l0d（出站）；TUN RX = l0d 写回（入站）。
3. `.45` `ss` 显示枢纽公网 `:4200` = DNAT 原目的，不是漏公网。
4. 本窗口未重启 geth / `.98` beacon / validator。

## 公式 / 数据

窗口约 15 分钟。Mailbox B = `9977E9A45187DD80`。C ≠ B。

| 计数 | .45 spoke | .98 hub |
| --- | ---: | ---: |
| flushed POST | 1,786 | 1,870 |
| flushed IPv4 packets | 2,793 | 5,736 |
| POST / queue / TUN write-back / armor / SSE fail | **全 0** | **全 0** |
| TUN tx_dropped | 0 | **937**（qlen 500，约 13.6%） |

端口（flushed packets）：`.45` `:8400` 396 / `:4200` 1,183 / `:4300` 1,214；`.98` 717 / 1,451 / 3,568。`:4200` 自 18:48 `.45` `restart-beacon` 后才有。枢纽→spoke TUN 4.42 MB 对上 spoke inbound 4.42 MB。Beacon 流 1,667,798 字节两端 ACK 一致；该套接字重传 1/1,540。Overlay RTT 475–750 ms；公网 peer ~40–55 ms。`.45` `rcv_ooopack` 156/1,423（~11%）。

## 冻结结论

1. **Mailbox 路径本窗口健康。** 应用层零丢包、seq gap 0、三通道分流。
2. **质量短板是延迟与乱序，不是缺字节。** 下一杠杆：枢纽 TUN qlen / 读速率，以及 mailbox hop RTT。
3. **不得**把 isolate DROP 或 EL `0x0` 当成 overlay 丢包。不得为修本快照重启 EL/CL。
4. **不关闭** P1 追链门；**不是**生产 discv5。

## 替代关系

- 替代「只口头说 overlay 通了」：有两端计数与 TCP 指标。
- 不替代 `docs/P1.md` / `docs/P2.md` 验收条款。
- 不扩写 GitBook mailbox-routing / SI 命令表。

## 未决项

- `.98` 937 TUN `tx_dropped` 是否主要伤 UDP `:4300`（未做短时 tcpdump 分协议）。
- `.98` 4 条 listen SSE（预期 3）+ Send-Q 7144 的根因。
- `.45` flushed 2,793 vs TUN TX 6,365：未知端口 fail-closed（debug）未在 info 展开。

## 实现检查表

- [x] 两端只读拉 log / TUN / ss，未重启链进程
- [x] crate `docs/lab-overlay-qos-2026-08-18.md` 写入 CoNET-L0D
- [x] 交互 Canvas 仍只在 Cursor 管理目录（未把 `.canvas.tsx` 复制进 git）
- [ ] 未改白皮书 / RULES / MVP（本快照不是协议改动）
