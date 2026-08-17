# CoNET-DLE MVP 分期实现（归档 / ethers JSON-RPC / on-demand / explorer）

- **Canvas 标识：** `dle-mvp-phased-runtime.canvas.tsx`
- **日期：** 2026-08-15
- **状态：** P1 已拆 `archive` / `daemon`；**P1 联网归档 BFT / Mode A / 4-of-5 AC 已落地**（独立 `runtime/src/archive/bft`，复用 TCP 27101；**2026-08-17 P16：** 新票为实验室 EIP-712 `ArchiveBftVote`，磁盘旧 HMAC 证书 keep-only；**不是**冻结 L1 wrapper / corpus SSZ）；**P2 JSON-RPC 2.0 只读 facade 已落地**；**P3 on-demand 钩 / poolRoot / 可重算 7+2 已落地**（实验室 beacon ≠ L1 CL RANDAO）；**P3 HTTP 排队演示：`70.35.205.77` 上 30 个 on-demand 客户端经 `http://<archive>:27101/ondemand/hook` 写入七台归档**（新 `poolRoot=0xafdf42e9…c3c2c4`，7 台同根、frozen、5 active attest、`endorsed=true`）；**P4 explorer 已在 `https://dle.conet.network` Home / Certificates 显现实验室 AC 与 P3 等待池 / 7+2 SelectionLog**；**P5 其余 DLE L1 UUPS 栈已部署到 CoNET 224422 并当场 Blockscout 验证（16/16）**，**不是** 30 天资格
- **规范优先级：** 英中白皮书 §5.4 / §7.8.5 / §8.1 / §8.3 / §15.19 与现有合约 / corpus > 本快照。**2026-08-15：** 组内等待钩逐归档投递、实验室 HTTP `POST /ondemand/hook`、实验室 beacon ≠ L1 CL 已写入英中白皮书。

## 事实来源

- 白皮书：归档全节点、RPC 仅授权参与者、AC 才是最终性、on-demand 等待队列、无 tip VM。
- `implementations/archive-a` / `archive-b`：进程内 SSZ / QC / WAL / RS(7,4) / 5+2 生命周期；明确排除网络、钥匙、L1 客户端。
- `src/dle/*`：L1 UUPS 合约源码存在。**P5（2026-08-15）**：其余 8 对 impl+`DLEERC1967Proxy` 已部署到 CoNET 224422（`deployBlock=847316`，记录 `deployments/conet-DLE-MVP.json`）。**未重部署**已上线的 `GlobalArchiveRoutingRegistry` `0x8B261eAECdFfeE9e7aC9fFe73386B0d6C9E76AfB`。canonical 业务地址 = 代理。`chainRegistryUri` = `https://mainnet.conet.network/dle/erc1155/metadata.json`（现有域名路径，HTTP 200）。Blockscout v2 **16/16** `is_verified` 且合约名匹配（impl 为本合约名，proxy 为 `DLEERC1967Proxy`）。**诚实边界：已部署验证 ≠ 30 天 5+2 资格。**

| 合约（canonical = 代理） | 代理 | 实现 |
|---|---|---|
| OperatorDomainRegistryV1 | `0x80BB7639B6C23A9660a49461f517F92dfce2fc00` | `0x97e6D06B78F94e37c2bE9755A1D2A9F9487Ed2C3` |
| ArchiveGroupRegistryV1 | `0x12b3A568439411fD90ede5A853ee728D40918C70` | `0x4D94aEda052d2379A23f51f5Eb7707651C145C57` |
| ArchiveCertificateVerifierV1 | `0xdA06E6d06eB2816795102B18171a079E3bEA948f` | `0xCC98f0d4De8972F9154870C0eC5a8D18a5B4ca48` |
| DLEChainRegistry1155V1 | `0x100DC8f0Ff5Fce2D0be3974a5E797dF3627E0989` | `0xFe0587AcED519C5964Fa38B8942334EA1bA6C3B6` |
| AssetAdmissionRegistryV1 | `0xa7F2a53a7f5a18aa6cc7CCDbBADbc071a47EF1AE` | `0x47D47F4E0541EBB3caA7e88D8E384C7a23DeEeDD` |
| DLEArchiveDisputeManagerV1 | `0x10F0000727933D6718Fc5269BEC137c86464Bb41` | `0x5E26f1b0A3aD81526F124FA690377c0d347b4d49` |
| AssetBurnMintGateway | `0x87fB2d6337A320223471c671e9f4C6bd331d85B2` | `0x4A1d0766EbEf8E2BDC9f6CbD8fEe3e6E5ec3Cf0A` |
| L1QueueAccumulatorV1 | `0xf5e12f2153A1BD59Cafb946B97248708A78ed00A` | `0x9d8c5c09386a5052E49bfb22C9Fdf95B16eA6AE9` |
- 7 主机实验室：TCP 27101 7×7 HTTP 200；**P1 `archive` command 已替换旧 `agent.mjs`**（2026-08-14：`command:archive`、daemon probe、`eth_chainId=0x44c45`）。**2026-08-14：联网 BFT 在 27101 交换 prevote/precommit，Mode A 重放冻结 TradeOpened 候选，签发实验室 4-of-5 AC**（证据 `pilot/evidence/conet-dle-30d-lab-2026-08/bft-p1-accept.json`）。心跳 `lastQuorumOk` 仍不是 BFT。
- 用户目标：最终实现归档节点、ethers 对应 JSON 查询、on-demand 参与、给 block explorer 的接口。
- P4 explorer（2026-08-15）：`src/conet-layer2/explorer` 独立 Vite/React；协议常量本地拷贝；读 `27101` `/health` `/rpc` `/api/v2/dle` `/ondemand/pool` `/ondemand/selection`；失败保留上次可信快照；禁止 `setInterval` / 新域名 / archive-a·b import。公开 host `https://dle.conet.network` Home / Certificates 展示 P3 `waitingPool` + SelectionLog（`poolRoot` / 7+2 / attestors / `endorsed`）。首屏 seed 七主机验收 `ondemand-p3-accept.json`；仅可信 live 覆盖。nginx 只反代 GET `/ondemand/pool` `/ondemand/selection`，不暴露 hook/freeze POST。SelectionLog **不是** AC。
- P3 on-demand（2026-08-15）：`runtime/src/shared/ondemand` 可复算 `poolRoot` / \(R_e\) / Fisher–Yates 7+2；`runtime/src/archive/ondemand` 钩、freeze、\(Q_A=4\) attest。实验室 beacon = `keccak256(utf8("dle.lab.beacon.afterFreeze.v1") || poolRoot || epoch || shardId)`，**不是** live CoNET CL RANDAO，也 **不**读 `publicrpc`。SelectionLog **不是**块、**不是** AC。DepositBundle 可附带 `selectionLogRef` / committee / standbys，**不**进入 Mode A `valueHash`。单节点 `endorsed=false`；七主机 5 active 背书后 `endorsed=true`。2026-08-15 验收当时为 HMAC attest（证据 `pilot/evidence/conet-dle-30d-lab-2026-08/ondemand-p3-accept.json`）。**P17（2026-08-17）** 新 ingest 改为 EIP-712 `ArchiveOnDemandAttest`；当时 beacon 仍 keccak after freeze。**P19（2026-08-17）** on-demand beacon 改为先冻后绑（默认 honest-wait `labOnDemandBeaconAfterFreeze`；即时 `labBeaconAfterFreeze(poolRoot)` 仅 contrast），**不是** live CL RANDAO。**P20（2026-08-17）** 引擎拒绝 miner/hook ingest（`ERR_ONDEMAND_HOOK_NOT_GOSSIP`）并标 fan-out 诚实；实验室 HTTP 钩 **不是** 生产 DePIN gossip。不是 30 天资格。七主机验收 `2026-08-15T06:14:24.034Z`：`poolRoot=0x1a0895b0…8def74`，同一 7+2，5 active attest，`endorsed=true`。
- P3 HTTP 30 客户端排队（2026-08-15）：客户端机 `70.35.205.77` `/home/peter/dle-ondemand-clients`（supervisor + 30 子进程，pattern `dle-ondemand-clients/`）。每个 miner `0xb110…0001`–`0xb110…001e` 对 **全部 7 台** `http://<ip>:27101` POST `/ondemand/hook`（钩不 gossip，必须逐台写）。**P20（2026-08-17）** 引擎拒绝把 miners/hooks 经 `/ondemand/message` ingest，daemon 标 `fanoutComplete` / `singleArchiveAcceptNotGroupPool`；**不是**生产 DePIN gossip。开池时只清 `ondemand-state.json`、保留 `bft-state.json`；`autoSeedLabMiners=false` / `autoFreeze=false`。验收 `2026-08-15T08:00:24.090Z`：七台 `minerCount=30`、同一 `poolRoot=0xafdf42e9625961ce16f2403f509835d79bba94b144bba9606346c9adf0c3c2c4`、frozen、5 active attest、`endorsed=true`，BFT AC 仍在。证据 `pilot/evidence/conet-dle-30d-lab-2026-08/ondemand-http-queue-30.json`。**这是 HTTP 等待钩演示，不是 30 天资格。** 新 `poolRoot` 会覆盖 explorer 首屏旧 seed（仅可信 live 覆盖）。未新建域名；未走 `https://dle.conet.network` hook；未重启 leftover EL/CL。
- 实验室 NewChain 用户（2026-08-15）：同机独立目录 `/home/peter/dle-newchain-user` 对 7 台 `POST /newchain/request`。先测资产/存储/交易各一条创世（NFT `354630060` / `21554398` / `384111170`），再 15–45s 随机开链。**不**进 NFT 42 BFT；证书标明不是 AC。证据 `pilot/evidence/conet-dle-30d-lab-2026-08/newchain-user-deploy.json`。详见 `src/canvas/dle-lab-newchain-genesis-user-2026-08.md`。**P18（2026-08-17）** 新 \(Q_V\) 改为 EIP-712 `ArchiveValidatorQuorumAttest`；new-chain-user HTTP 仍只查 `schema === 'DleLabValidatorQuorumV1'`。**不是** L1 出生证。
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
| P5 | **L1 栈已部署并当场验证**；30 天资格仍未宣称 | 未授权重启 EL/CL；不得把验证当资格 |

## 冻结结论

1. 归档是质检与最终性层，不是出块层。
2. **运行时拆成两个 command**：`archive` 只在 Node.js；`daemon` 核心可在 browser（`fetch`，无 `node:fs`）。
3. ethers 查询面服务钱包与 explorer indexer；写交易走 RequestPool，不是 L1 mempool。
4. on-demand **生产路径**经 DePIN gossip（可加归档 SSE）；每组一条未完成钩。**组内钩不 gossip**：miner/daemon 必须把同一钩投到该组每一台活跃归档（白皮书 §5.4 / §8.1）。实验室 HTTP `POST /ondemand/hook`（27101）是 MVP 控制面，**不是**生产 gossip，也 **不是** explorer HTTPS。实验室抽选走 §7.8.5，不是生产 §7.8.1。
5. explorer 双轨：L1 Blockscout 看 registry；DLE explorer（`src/conet-layer2/explorer`）看 eth 门面 + `/api/v2/dle` 证书 / WAL。禁止新公网域名。

## 替代关系

- 本快照不替代白皮书或 TLA+/corpus。
- 不把 27101 **心跳**实验室计为 P1 完成。实验室 HMAC 4-of-5 AC 是 P1 联网门，**不是**生产 EIP-712 / corpus SSZ，也不是 30 天资格。

## 未决项

- P1 以 archive-a 还是 archive-b 为运行时（须保持双实现差分，运行时另包）。
- 公开 explorer 是否只读副本 + 授权名单（当前仅本地 / 实验室 27101）。
- 30 天 5+2 资格计数、Placement / Burn-Mint 生产接线仍未宣称。
- P5 其余 L1 栈已获同条消息授权并完成部署+验证（2026-08-15）。

## 实现检查表

- [x] P1 脚手架：`npm run archive`（Node.js）/ `npm run daemon`（isomorphic，可 browser）；七主机 `lab-cli.js` 已部署并验收（证据 `pilot/evidence/conet-dle-30d-lab-2026-08/archive-runtime-accept.json`）
- [x] P1 联网归档 BFT / Mode A / 4-of-5 AC（独立包 `runtime/src/archive/bft`，无共享共识核；七主机证据 `pilot/evidence/conet-dle-30d-lab-2026-08/bft-p1-accept.json`。实验室 HMAC，非 EIP-712 / corpus SSZ，非 30 天资格）
- [x] P2 JSON-RPC 2.0 与 L1 publicrpc 隔离（`runtime/src/archive/jsonrpcFacade.ts`；`eth_chainId=0x44c45`；batch；拒绝 `eth_call` / `eth_getBalance`；不代理 L1 RPC。七主机验收见 `pilot/evidence/conet-dle-30d-lab-2026-08/jsonrpc-p2-accept.json`）
- [x] P3 on-demand 钩与可重算抽选（`shared/ondemand` + `archive/ondemand`；`dle_getWaitingPool` / `dle_getSelectionLog`。实验室 beacon ≠ L1 CL；HMAC 可伪造；SelectionLog 不是 AC；不改 P1 `valueHash`。七主机证据 `pilot/evidence/conet-dle-30d-lab-2026-08/ondemand-p3-accept.json`，`acceptedAt=2026-08-15T06:14:24.034Z`，`poolRoot=0x1a0895b0…8def74`，5-of-5 active attest）
- [x] P3 HTTP 30 客户端排队演示（`70.35.205.77` → 七台 `http://:27101/ondemand/hook`；证据 `ondemand-http-queue-30.json`，`poolRoot=0xafdf42e9…c3c2c4`。**不是** 30 天资格）
- [x] P4 脚手架：`explorer/`（`npm run explorer:dev` / `explorer:build`）+ 归档 `GET /api/v2/dle`；无新域名，无 30 天资格宣称
- [x] P4 explorer 显现 P3 证据：Home / Certificates 画 waiting pool、`poolRoot`、7+2、`endorsed`；seed `0x1a0895b0…8def74`；live 成功才覆盖；诚实标注 lab beacon ≠ L1 CL、HMAC 可伪造、SelectionLog ≠ AC
- [x] P5 其余 DLE L1 栈部署到 CoNET 224422 并当场 Blockscout 验证（8 impl + 8 `DLEERC1967Proxy`；独立复核 16/16 `is_verified` + name match；记录 `deployments/conet-DLE-MVP.json`，`verification.blockscoutV2.completedAt=2026-08-15T07:36:16.070Z`）
- [ ] 30 天 5+2 资格未宣称（部署验证不构成资格）
