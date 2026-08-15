# CoNET-DLE MVP 分期实现（归档 / ethers JSON-RPC / on-demand / explorer）

- **Canvas 标识：** `dle-mvp-phased-runtime.canvas.tsx`
- **日期：** 2026-08-14
- **状态：** P1 已拆 `archive` / `daemon`；**P1 联网归档 BFT / Mode A / 4-of-5 AC 已落地**（独立 `runtime/src/archive/bft`，复用 TCP 27101；实验室 HMAC-SHA256，**不是**冻结 EIP-712 / corpus SSZ）；**P2 JSON-RPC 2.0 只读 facade 已落地**；**P3 on-demand 钩 / poolRoot / 可重算 7+2 已落地**（实验室 beacon ≠ L1 CL RANDAO）；**P4 explorer 已展示实验室 AC 与 P3 等待池 / 7+2 SelectionLog**
- **规范优先级：** 英中白皮书 §5.1 / §5.4 / §6.3 / §8.1 与现有合约 / corpus > 本快照

## 事实来源

- 白皮书：归档全节点、RPC 仅授权参与者、AC 才是最终性、on-demand 等待队列、无 tip VM。
- `implementations/archive-a` / `archive-b`：进程内 SSZ / QC / WAL / RS(7,4) / 5+2 生命周期；明确排除网络、钥匙、L1 客户端。
- `src/dle/*`：L1 UUPS 合约源码存在，**未部署**。
- 7 主机实验室：TCP 27101 7×7 HTTP 200；**P1 `archive` command 已替换旧 `agent.mjs`**（2026-08-14：`command:archive`、daemon probe、`eth_chainId=0x44c45`）。**2026-08-14：联网 BFT 在 27101 交换 prevote/precommit，Mode A 重放冻结 TradeOpened 候选，签发实验室 4-of-5 AC**（证据 `pilot/evidence/conet-dle-30d-lab-2026-08/bft-p1-accept.json`）。心跳 `lastQuorumOk` 仍不是 BFT。
- 用户目标：最终实现归档节点、ethers 对应 JSON 查询、on-demand 参与、给 block explorer 的接口。
- P4 explorer（2026-08-14）：`src/conet-layer2/explorer` 独立 Vite/React；协议常量本地拷贝；读 `27101` `/health` `/rpc` `/api/v2/dle`；失败保留上次可信快照；禁止 `setInterval` / 新域名 / archive-a·b import。**2026-08-15：** Home / Certificates 展示 P3 `waitingPool` + SelectionLog（`poolRoot` / 7+2 / attestors / `endorsed`）。首屏 seed 七主机验收 `ondemand-p3-accept.json`；仅可信 live `/ondemand/pool` `/ondemand/selection` 覆盖。SelectionLog **不是** AC。
- P3 on-demand（2026-08-15）：`runtime/src/shared/ondemand` 可复算 `poolRoot` / \(R_e\) / Fisher–Yates 7+2；`runtime/src/archive/ondemand` 钩、freeze、\(Q_A=4\) HMAC attest。实验室 beacon = `keccak256(utf8("dle.lab.beacon.afterFreeze.v1") || poolRoot || epoch || shardId)`，**不是** live CoNET CL RANDAO，也 **不**读 `publicrpc`。SelectionLog **不是**块、**不是** AC。DepositBundle 可附带 `selectionLogRef` / committee / standbys，**不**进入 Mode A `valueHash`。单节点 `endorsed=false`；七主机 5 active 背书后 `endorsed=true`。HMAC 可伪造，不是 30 天资格。七主机验收 `2026-08-15T06:14:24.034Z`：`poolRoot=0x1a0895b0…8def74`，同一 7+2，5 active attest，`endorsed=true`（证据 `pilot/evidence/conet-dle-30d-lab-2026-08/ondemand-p3-accept.json`）。
- P2 JSON-RPC（2026-08-14）：`jsonrpcFacade.ts` 提供 ethers 形状只读面；`l1Isolated=true`；**禁止**把 DLE `/rpc` 代理到 L1 `publicrpc`/`rpc1`。有实验室 AC 时 `dle_tip.finalized=true`、`eth_blockNumber=0x1`；无 BFT 的 `startArchiveNode` 仍诚实空。
- P1 BFT（2026-08-14）：独立包 `runtime/src/archive/bft`（自研 Keccak、Mode A Trade FSM、独立 Tendermint lock/valid、实验室 HMAC MAC、4-of-5 QC）。**禁止** import `implementations/archive-a` / `archive-b`。归档仍不出块、无 tip VM。L1 预检只用 DepositBundle 内嵌 `l1EscrowView`，不打 publicrpc。实验室 MAC 由公开 `domainId` 派生，**可伪造**，不得称为生产 secp256k1 / EIP-712 / corpus SSZ。

## 假设

- 实验室 MVP 在已放行的 **TCP 27101** 上复用健康检查、归档帧、JSON-RPC、等待 SSE，不新开公网端口、不新建子域。
- ethers JSON-RPC 是 **DLE tip 的以太坊形状门面**，不得把 `eth_chainId` 设成 224422。
- explorer 公开读必须附带可验证 AC；Cluster REST 不得覆盖链上 tip。

## 分期

| 阶段 | 交付 | 非目标 |
|---|---|---|
| P0 | corpus、双实现、L1 源码、27101 心跳 | 联网共识 |
| P1 | **归档 node**（Node.js WAL/HTTP）与 **daemon**（browser-safe `fetch` 客户端）分 command；**联网 Mode A + 4-of-5 实验室 AC**（独立包） | 归档出块；把 daemon 当归档全节点；把实验室 HMAC 当成生产签名 |
| P2 | `eth_*` 只读 + `dle_getArchiveCertificate` | tip VM / eth_call |
| P3 | 等待钩、poolRoot、7+2、DepositBundle | 全历史轻节点 |
| P4 | 独立 `explorer/` Web UI + 归档 `GET /api/v2/dle`（27101，无新域名） | 新子域；L1 Blockscout；eth_call 浏览器 |
| P5 | 授权后部署验证 + 30 天资格 | 未授权重启 EL/CL |

## 冻结结论

1. 归档是质检与最终性层，不是出块层。
2. **运行时拆成两个 command**：`archive` 只在 Node.js；`daemon` 核心可在 browser（`fetch`，无 `node:fs`）。
3. ethers 查询面服务钱包与 explorer indexer；写交易走 RequestPool，不是 L1 mempool。
4. on-demand 经 DePIN gossip（可加归档 SSE）；每组一条未完成钩。
5. explorer 双轨：L1 Blockscout 看 registry；DLE explorer（`src/conet-layer2/explorer`）看 eth 门面 + `/api/v2/dle` 证书 / WAL。禁止新公网域名。

## 替代关系

- 本快照不替代白皮书或 TLA+/corpus。
- 不把 27101 **心跳**实验室计为 P1 完成。实验室 HMAC 4-of-5 AC 是 P1 联网门，**不是**生产 EIP-712 / corpus SSZ，也不是 30 天资格。

## 未决项

- P1 以 archive-a 还是 archive-b 为运行时（须保持双实现差分，运行时另包）。
- 公开 explorer 是否只读副本 + 授权名单（当前仅本地 / 实验室 27101）。
- L1 部署需用户同条消息授权。

## 实现检查表

- [x] P1 脚手架：`npm run archive`（Node.js）/ `npm run daemon`（isomorphic，可 browser）；七主机 `lab-cli.js` 已部署并验收（证据 `pilot/evidence/conet-dle-30d-lab-2026-08/archive-runtime-accept.json`）
- [x] P1 联网归档 BFT / Mode A / 4-of-5 AC（独立包 `runtime/src/archive/bft`，无共享共识核；七主机证据 `pilot/evidence/conet-dle-30d-lab-2026-08/bft-p1-accept.json`。实验室 HMAC，非 EIP-712 / corpus SSZ，非 30 天资格）
- [x] P2 JSON-RPC 2.0 与 L1 publicrpc 隔离（`runtime/src/archive/jsonrpcFacade.ts`；`eth_chainId=0x44c45`；batch；拒绝 `eth_call` / `eth_getBalance`；不代理 L1 RPC。七主机验收见 `pilot/evidence/conet-dle-30d-lab-2026-08/jsonrpc-p2-accept.json`）
- [x] P3 on-demand 钩与可重算抽选（`shared/ondemand` + `archive/ondemand`；`dle_getWaitingPool` / `dle_getSelectionLog`。实验室 beacon ≠ L1 CL；HMAC 可伪造；SelectionLog 不是 AC；不改 P1 `valueHash`。七主机证据 `pilot/evidence/conet-dle-30d-lab-2026-08/ondemand-p3-accept.json`，`acceptedAt=2026-08-15T06:14:24.034Z`，`poolRoot=0x1a0895b0…8def74`，5-of-5 active attest）
- [x] P4 脚手架：`explorer/`（`npm run explorer:dev` / `explorer:build`）+ 归档 `GET /api/v2/dle`；无新域名，无 30 天资格宣称
- [x] P4 explorer 显现 P3 证据：Home / Certificates 画 waiting pool、`poolRoot`、7+2、`endorsed`；seed `0x1a0895b0…8def74`；live 成功才覆盖；诚实标注 lab beacon ≠ L1 CL、HMAC 可伪造、SelectionLog ≠ AC
- [ ] P5 部署当场验证；30 天资格未宣称
