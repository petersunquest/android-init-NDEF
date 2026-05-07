# Conet 224422：对等信息（node-0/1/2、node-98、node-187）

> 供运维与工程参考。**每次任意节点**仅重启 **Geth** 和/或 **Prysm Beacon** 后，**enode / 16U（libp2p）** 中至少有一项可能变化；**凡重启即应在对应主机上重新拉取，并更新本文件**，以免静态对等、`--peer`、文档三方不一致。

## 拉取与记录方式（在节点所在机执行）

| 项目 | 命令 / 位置 |
|------|----------------|
| Geth 当前 enode | `./dependencies/go-ethereum/build/bin/geth attach --exec "admin.nodeInfo.enode" "ipc:…/execution/geth.ipc"`，将 `@127.0.0.1` 或旧 IP 换为**公网 IP:端口**再写入对端。 |
| Beacon 当前 P2P | `grep "Node started p2p" network/node-*/logs/beacon.log \| tail -1`，取行内 **multiAddr** 整段作为 Prysm `--peer=…`。 |

**网络**：`networkid=224422`，与 `config.yml` 中 `chain-id=224422` 一致。  
**共识 bootnode（Geth 常用 Bootstrap，与 Static 并存时以你方部署为准）**  
`enode://7ab828019e77f8ad89302b7a70096626cb7185bc992e96744349593787385f448713194f19a81a31f85b2e222cbe8c8165a5aa36a40cc87e90c06ae7598fd9b7@38.102.126.58:0?discport=30301`

---

## 38.102.126.58 — `node-0` / `node-1` / `node-2`

基础目录（参考）：`~/ethereum-pos-mainnet/network/node-{0,1,2}/`

Geth 对外 P2P 端口：**8400** / **8401** / **8402**（对端 enode 中 `@` 后请使用公网 `38.102.126.58:端口`；`geth attach` 里常见 `127.0.0.1` 仅为本机回显。）

Prysm 对外 P2P：**TCP+UDP 4200** / **4201** / **4202**（`multiAddr` 中已含公网 IP）。

| 节点 | 执行层 P2P（enode，公网） | 信标层 P2p multiAddr |
|------|---------------------------|------------------------|
| node-0 | `enode://bf2b58f922c994bc3ca7145273b09818a21a9f8647c6f47431941a2dbf92d564ddb046a1c86b064a1636a60d553d48049a324d0e8dd43c0b8dcaf665cfb5cc88@38.102.126.58:8400` | `/ip4/38.102.126.58/tcp/4200/p2p/16Uiu2HAmVLZyqYcH5FTEbMPusZhcnpnr875bY6fka5x2h371zaNM` |
| node-1 | `enode://4d59ac7ca35b9ab4369d0babede4812a2c29633d4a9ea7f22cdf837a47f7fe00dd4dc6fc9e42c5e31eff99278fdcbf0c3579cffd2f4e3813933850ccf18f0f50@38.102.126.58:8401` | `/ip4/38.102.126.58/tcp/4201/p2p/16Uiu2HAmTeuPvHgPbrXXXgZzHqr9nhcxh6YC9NxbaLfgSiRseW4n` |
| node-2 | `enode://d05a28e8f885645f20a7ff89d8b73380756f393c5836a09585c9a5c174f7bfa598d141587e8b1134c9b294c18ef407a1f014f5279a02a364533ec9c623274ee8@38.102.126.58:8402` | `/ip4/38.102.126.58/tcp/4202/p2p/16Uiu2HAmAyXTDofAdmbJG7uU45JtAe2sJupFYb9T5XbqFYqMvMV5` |

Prysm `--peer` 示例（`node-98` 的 `start-beacon.sh` 曾与此对齐，**具体以现网脚本为准**）：

```text
--peer=/ip4/38.102.126.58/tcp/4200/p2p/16Uiu2HAmVLZyqYcH5FTEbMPusZhcnpnr875bY6fka5x2h371zaNM
--peer=/ip4/38.102.126.58/tcp/4201/p2p/16Uiu2HAmTeuPvHgPbrXXXgZzHqr9nhcxh6YC9NxbaLfgSiRseW4n
--peer=/ip4/38.102.126.58/tcp/4202/p2p/16Uiu2HAmAyXTDofAdmbJG7uU45JtAe2sJupFYb9T5XbqFYqMvMV5
```

---

## 198.251.77.98 — `node-98`（`node-098`）

基础目录（参考）：`~/ethereum-pos-testnet/network/node-98/`

| 项目 | 值 |
|------|-----|
| 公网 IP | `198.251.77.98`（`--nat=extip:198.251.77.98`，`--p2p-host-ip=198.251.77.98`） |
| Geth 执行层 P2P | TCP **8498**（`--port` 与 `discovery.port` 均为 8498） |
| Geth 当前 enode（`geth attach`） | `enode://9d838083f231542afc16640c23bb172adb46bba0f95172fbd8abf475947774259f87b6affbbcf509b3ffe8b44212deab235bbe5d0e53f7b3e136f035cbaca624@198.251.77.98:8498?discport=0` |
| 信标层 P2P | TCP **4298**；UDP **4398** |
| 信标 P2p multiAddr（`beacon.log` 最近一条 `Node started p2p`） | `/ip4/198.251.77.98/tcp/4298/p2p/16Uiu2HAm2xuZx6QKhen2VZS6zAzf9rdrDByjz6oPMEA8EyJpKYYr` |
| 本机只读/网关（以 `start-*.sh` 为准） | Geth：HTTP `127.0.0.1:8088`、WS `127.0.0.1:8089`、Engine `127.0.0.1:8808`、metrics `127.0.0.1:8308`；Beacon：RPC `127.0.0.1:4098`、gRPC 网关 `0.0.0.0:4198`、监控 `127.0.0.1:4498` |

**node-98 Beacon 出站静态对等（`--peer`）**（另含 58 的 `node-0/1/2` 与 187 的 `node-187`；**以 `start-beacon.sh` 为准**）  
示例第四条（`node-187`）：  
`--peer=/ip4/216.225.197.187/tcp/4287/p2p/16Uiu2HAkwdWCKXWinvTeJ1ZSN41Ujka5vpgDn4n79GHvTjwDwUDc`  

> **说明**：仅重启 **Beacon** 会轮换 **16U**；上表「信标 P2p multiAddr」在每次 Beacon 重启后须按上文命令重拉。Geth 未重部署时 **enode 通常不变**。

---

## 216.225.197.187 — `node-187`

基础目录（参考）：`~/ethereum-pos-mainnet/network/node-187/`

| 项目 | 值 |
|------|-----|
| 公网 IP | `216.225.197.187`（`--nat=extip:216.225.197.187`，`--p2p-host-ip=216.225.197.187`） |
| Geth 执行层 P2P | TCP **8587**（`--port` 与 `discovery.port` 均为 8587） |
| Geth 当前 enode（`geth attach`） | `enode://22783de088ef2c1d9bd2df27422e884ff6a558e5555187428fd02783e4f43470abf301f2372781c1849f966f5c19b978ec804b1c51eecd946a8368f3a5551350@216.225.197.187:8587?discport=0` |
| 信标层 P2P | TCP **4287**；UDP **4387** |
| 信标 P2p multiAddr（`beacon.log` 最近一条 `Node started p2p`） | `/ip4/216.225.197.187/tcp/4287/p2p/16Uiu2HAkwdWCKXWinvTeJ1ZSN41Ujka5vpgDn4n79GHvTjwDwUDc` |
| 本机只读/网关（以 `start-*.sh` 为准） | Geth：HTTP `127.0.0.1:8187`、WS `127.0.0.1:8192`、Engine `127.0.0.1:8787`、metrics `127.0.0.1:8387`；Beacon：RPC `127.0.0.1:4087`、gRPC 网关 `127.0.0.1:4187`、监控 `127.0.0.1:4487` |

**node-187 的出站/静态对等**以现网 `geth-config.toml` 与 `start-beacon.sh` 为准；若仅 **Beacon** 重启，**16U 会变**，凡依赖 `--peer=…187…4287…` 的其它节点应同步为 **同一次** `beacon.log` 中的 **multiAddr**。

---

## 入站与防火墙（简要）

即使本机已监听 **0.0.0.0** 或公网 IP，**云安全组 / 外缘防火墙**未放行时，公网仍可能**超时**。

- **38.102.126.58**：TCP **8400–8402**、**4200–4202**；UDP 按 Prysm/运营商要求。  
- **198.251.77.98**：TCP **8498**、**4298**；UDP **4398**（与信标/发现一致时放行）。  
- **216.225.197.187**：TCP **8587**、**4287**；UDP **4387**。

---

*身份快照已按 **2026-04-22** 在 `198.251.77.98`、`216.225.197.187` 上 `geth attach` 与 `beacon.log` 拉取并写入；**任一节点的 Geth/Beacon 在本文档之后再次重启，请重新拉取并改写上表对应行。***
