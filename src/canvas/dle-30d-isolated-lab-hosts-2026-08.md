# DLE 30 天隔离实验室主机分配（2026-08-14）

- **Canvas 标识：** 无独立交互 Canvas；本快照记录用户指定的 7 台正式验收主机。
- **日期：** 2026-08-14；**2026-08-17** 把 `fd-01` 从 `74.208.224.45` 换到 `45.132.74.220`，把 `fd-03` 从 `198.251.77.98` 换到 `45.132.74.221`。
- **状态：** 官方 7 席位身份仍在名册；两席均 **live**。已停 `74.208.224.45` 与 `198.251.77.98` 上的 L2，且这两台旧 IP **今后不可再被 MVP 使用**。2026-08-17 已对 `45.132.74.220` / `45.132.74.221` 做 keep-data 并启 L2（`lab:keep-remap-l2`）；现役 `fd-02` / `fd-04` / `fd-05` extraPeers 已指向新 IP。`dle.conet.network` upstream 现为 `.220` / `.221` + 东京两台。未开 `pilotStartedAt`。未自动升 standby。未反代 `.189`。
- **规范优先级：** 白皮书 5+2 / 4-of-5 与 `pilot/` 资格门 > 本快照。

## 事实来源

- 用户 `RPC Cancun` 清单指定 7 台主机。
- 2026-08-14 `peter@` SSH 只读盘点：hostname、CPU/RAM/磁盘、监听端口、systemd unit、ipinfo ASN。
- whois / ipinfo：IONOS `AS8560`（3 台 leftover）、HostHatch `AS63473`（东京 2 台 + NYC `45.132.74.220` fd-01 + NYC `45.132.74.221` fd-03）。
- 2026-08-17：用户指定用 `45.132.74.220` 替代 `74.208.224.45`。旧机 L2 已停；`:27101` 已无监听。席位仍 live。
- 2026-08-17：用户指定用 `45.132.74.221` 替代 `198.251.77.98`。旧机 `lab-cli.js` pid 3299829 已停；`:27101` 已无监听；`~/dle-30d-lab/data` 保留。当时旧机无 geth/beacon/validator。新机 `NY2` 1C/1.9Gi、无 `dle-30d-lab`、无 `:27101`、无 EL/CL、ASN `AS63473`。
- 2026-08-17：用户授权对 `.220` / `.221` keep / 启 L2。`lab:keep-remap-l2` keep-data 成功：`fd-01` STARTED=2190 LIVE_OK；`fd-03` STARTED=2050 LIVE_OK。随后 keep-data 刷新 `fd-02` / `fd-04` / `fd-05` extraPeers（去掉旧 `.45` / `.98`）。公网 `http://45.132.74.220:27101/liveness` 与 `.221` 均为 `"ok":true`。未碰 EL/CL，未启 standby。
- 2026-08-17：用户授权把 `.220` / `.221` 加进 `dle.conet.network` upstream 并部署 Explorer。nginx `least_conn` 现为四台上游；仍不反代 `.189` / 旧 IONOS / standby leftover。
- 用户声明：每台主机每月账单 **USD 4**，**无限制流量**；云防火墙已放行实验室 **TCP 27101**。
- 2026-08-14 实测：7×7 `http://<peer>:27101/health` 全部 HTTP 200；7 个 agent 均 `lastQuorumOk=true`、`lastPeerOk=6`。

## 假设

- 7 个 `hostId` 视为独立故障域。live IONOS leftover 为 3 台（fd-02 / fd-06 / fd-07）。`fd-01` 与 `fd-03` 现为 HostHatch NYC，与东京 HostHatch 同 ASN、不同 region。
- 实验室只跑 `~/dle-30d-lab` 轻量 Node 副本，不与 leftover / 现役 EL/CL 共进程。
- 主机月租 $4 + 不限流量是本窗口可归属成本；**不**因此关闭生产成本 epoch 或宣称 30 天资格。

## 公式 / 数据

- 主机月租：`7 × USD 4 = USD 28 / month`
- 流量：`unmetered-traffic` 单价 0（不按字节计费）
- 发票：`invoice.json` `inv-conet-dle-30d-lab-2026-08-host-month`，账期 `2026-08-14` → `2026-09-13`
- Quorum：5 active 中至少 4 台 `lastQuorumOk`；实测 5/5 active + 2 standby 均通

## 冻结结论

| domainId | IP | 角色 | 盘点 |
|---|---|---|---|
| fd-01-ionos-45 | 45.132.74.220 | active | 2026-08-17 换机。旧机 `74.208.224.45` L2 已停并永久排除。新机 keep-data L2 已启。席位仍 live，禁止 wipe。 |
| fd-02-ionos-189 | 216.225.197.189 | active | 现役只读 beacon，勿重启 |
| fd-03-ionos-98 | 45.132.74.221 | active | 2026-08-17 换机。旧机 `198.251.77.98` L2 已停并永久排除。新机 keep-data L2 已启。席位仍 live，禁止 wipe。 |
| fd-04-hosthatch-tokyo1 | 167.254.243.38 | active | 绿场 1C/2G/9G |
| fd-05-hosthatch-tokyo2 | 170.205.39.67 | active | 绿场 1C/2G/9G |
| fd-06-ionos-174 | 216.225.193.174 | standby | leftover geth+beacon 可能仍在 |
| fd-07-ionos-207 | 212.227.242.207 | standby | leftover geth+beacon，VA 已关 |

- `billingRef` = `usd-4-unmetered-<hostId>`（每主机唯一）。
- 仅放行实验室 TCP **27101**；不得改 EL/CL 端口。
- Warmup 时钟未重置：`warmupStartedAt = 2026-08-14T17:10:16.786Z`。

## 未决项

- 跨 IONOS 相关故障是否另开独立 provider 域。
- 72h warmup 结束后才允许计入 rotation / re-home / takeover。
- 公开脱敏 bundle 尚未发布。

## 实现检查表

- [x] 官方 inventory 7 唯一 host / operator / domain，5+2
- [x] 隔离目录与端口 27101
- [x] 故障注入只杀 `dle-30d-lab/agent.mjs` 或 `app/archive/lab-cli.js`（不得碰 EL/CL）
- [x] 跨域 TCP 27101 7×7 mesh + 4-of-5 quorum
- [x] P1 `archive` command 已替换心跳 agent（2026-08-14 验收；非 BFT）
- [x] 可归属月租发票：USD 4 / 主机，流量不限，小计 USD 28
- [ ] 72h warmup 完成
- [ ] 30 天窗口 + 100/30/100 计数
