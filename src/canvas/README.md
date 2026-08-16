# Canvas 开发思路归档

> **Git 可版本控制归档。** 交互式 `.canvas.tsx` 由 Cursor 管理并保持唯一运行副本；本目录保存其 Markdown 思路快照，供白皮书、协议实现、测试与后续审查引用。快照不是第二份可执行 Canvas，也不是协议规范真相来源。

**归档基线：** 2026-08-13
**规范优先级：** 当前代码与英中白皮书 / 独立规范 > 本目录 Canvas 快照 > 历史讨论。
**全局守则：** `.cursor/rules/conet-layer2-whitepaper-bilingual-sync.mdc` 的 “Canvas Git 归档（强制）”。

## 归档清单

| Canvas 快照 | 交互 Canvas 标识 | 状态 | 主要用途 |
| --- | --- | --- | --- |
| [归档同步资格：追块不是席位](./dle-archive-sync-qualification-2026-08.md) | `dle-archive-sync-qualification-2026-08.canvas.tsx` | **2026-08-16 规范冻结；实验室门面已落地抽检 + 从零加入** | IdentityEligible ≠ SyncQualified；`SYNCING` 无席位；随机抽检全部托管链；\(Q_A=4/5\)（禁 3/5）；不是 30 天门 |
| [为何随机 test 等于「已有该组信息」](./dle-archive-sync-qualification-2026-08.md) | `dle-archive-sync-possession-soundness-2026-08.canvas.tsx` | **2026-08-16 可靠性论证已入 §5.2.0f** | 承诺根绑定库存；不可预测本地打开；分层覆盖 \(C_G\)；禁 hop/proxy；每链 1 样本只是覆盖 |
| [Testnet EIP-155 vs Group ID = 登记 hash](./dle-testnet-chainid-group-hash-2026-08.md) | 无独立交互 Canvas | **2026-08-16 7 台归档已 wipe+重启，Explorer 已发** | `0x44c45` = CoNET-DLE Testnet；Group ID = 引导组 L1 register tx；uint `1` 只是存储键 |
| [§5.2.0e 新增修正落到上一轮](./dle-whitepaper-520e-corrections-2026-08.md) | `dle-whitepaper-520e-corrections-2026-08.canvas.tsx` | **2026-08-15 审查 + keep 落地** | 白皮书三分状态 / 方案 C 如何收紧上一轮 M0–M5；旧 freezer 投影不得 alias PrevoteQC |
| [Hash RPC 事实核查 + 方案 C PrevoteQC](./dle-hash-rpc-fact-check-2026-08.md) | 无独立交互 Canvas | **2026-08-15 方案 C 已上线（keep + live smoke）** | 三分 `hit` / 本组 `notFound` / `unavailable`；`prevoteQc` 一等对象；禁止 tip/membership alias |
| [实验室 M6 第二归档组裂变](./dle-lab-m6-fission-2026-08.md) | 无独立交互 Canvas | **2026-08-16 七台绿场 + 跨组证据；Explorer/GitBook 已写 Clusters=2** | \(G_e: 1 \to 2\)；当时 G2 用实验室 hash；随后由 G2 L1 canvas 补登记；`locatePlane`；全平面 `null` 仅全组可信 notFound；非 30 天资格 |
| [实验室 P6 创世协议化](./dle-lab-p6-genesis-protocol-2026-08.md) | 无独立交互 Canvas | **2026-08-16 live keep 已过：7/7 独立 AC；NFT 42 tip 仍 0x1** | 新链补 5/7 验证人 HMAC 与 4-of-5 AC；不抢 NFT 42；不是 L1 出生证 / 30 天资格 |
| [实验室 G2 L1 登记](./dle-lab-g2-l1-register-2026-08.md) | 无独立交互 Canvas | **2026-08-16 已登记：tx `0xf781f2c2…876d5153` block 868793** | 第二组 `registerLiveGroup`；用户可见 Group ID = 登记 tx；实验室 keccak 为别名；不是 30 天资格 |
| [实验室 G2 主机 emit 登记 tx](./dle-lab-g2-own-groupid-register-tx-2026-08.md) | 无独立交互 Canvas | **2026-08-16 keep-deploy + accept 已过** | G2 `hop1.ownGroupId` / `liveGroupIds` 换成 L1 登记 tx；marker 仍用实验室 keccak 播种；不是 30 天资格 |
| [实验室 M7 typed tip/membership 根](./dle-lab-m7-typed-roots-2026-08.md) | 无独立交互 Canvas | **2026-08-16 已 keep 发版 + Explorer 目视** | `tipStateRoot` / `membershipRoot` 独立 kind + typed 对象；禁止 AC 别名；first-write-wins；非 30 天资格 |
| [修正 MVP：Hash 检索管道](./dle-mvp-hash-lookup-fix-2026-08.md) | `dle-mvp-hash-lookup-fix-2026-08.canvas.tsx` | **2026-08-15 实验室 M0–M5 已落地；M6/M7 见独立快照** | M0–M5：停错误 null + 本组 KV/freezer + locate/getByHash + hop-1 historyProviders + 每组证明树 |
| [Hash 必须击中某条链](./dle-hash-must-hit-chain-2026-08.md) | `dle-hash-must-hit-chain-2026-08.canvas.tsx` | **已入白皮书 §5.2.0e** | 多链聚合：locate 必须返回 chainNftId；组只是 route() 派生；freezer 键为 (nft, height) |
| [Archive geth hash 快路径 vs DLE](./dle-geth-archive-hash-lookup-2026-08.md) | `dle-geth-archive-hash-lookup-2026-08.canvas.tsx` | **已入白皮书 §5.2.0e** | 组内照搬 geth `H`/`l` 热 KV + freezer；locator 须带 chainNftId；本地 miss 不得直接 null |
| [每组 Hash 索引树](./dle-hash-index-tree-2026-08.md) | `dle-hash-index-tree-2026-08.canvas.tsx` | **实验室 M5 已落地（独立检查点，非 AC 投票）** | 每组 `hashIndexRoot` 做包含 / 不包含证明；不是热 Get，也不是第二套真相 |
| [DLE RPC hash 跨组 proxy](./dle-rpc-hash-proxy-2026-08.md) | `dle-rpc-hash-proxy-2026-08.canvas.tsx` | **已入白皮书 §5.2.0e** | hash-only 检索必须 locate 后单跳 proxy；禁止本组未命中直接 null；禁止 payload 全组扇出 |
| [DLE MVP 里程碑评估](./dle-mvp-milestone-assessment-2026-08.md) | `dle-mvp-milestone-assessment-2026-08.canvas.tsx` | **2026-08-15 审查：实验室门已闭环 / 资格未开** | P0–P4 实验室完成、P5 16/16 验证；HMAC/HTTP/lab beacon 不得外推生产；warmup ~24/72h；`pilotStartedAt=null` |
| [实验室三类新链创世 + daemon 用户](./dle-lab-newchain-genesis-user-2026-08.md) | 无独立交互 Canvas | **2026-08-16 身份 wipe 后已重开：三类创世 7/7 合格，随机开链已跑** | 资产/存储/交易 Mode A 创世；`70.35.205.77` `/home/peter/dle-newchain-user` 随机开链；**不是** L1 NFT / 30 天资格；未改白皮书 |
| [DLE MVP 分期运行时](./dle-mvp-phased-runtime-2026-08.md) | `dle-mvp-phased-runtime.canvas.tsx` | **当前归档/RPC/on-demand/explorer/L1 分期** | P0–P4 实验室已落地；**P3 HTTP 30 客户端已在 `70.35.205.77` 排队**（`poolRoot=0xafdf42e9…c3c2c4`）；**规范已入白皮书 §5.4 / §7.8.5 / §8.1 / §15.19**；**P5 其余 DLE L1 栈已部署 224422 并当场验证（16/16）**；30 天资格未宣称 |
| [DLE 30 天隔离实验室主机](./dle-30d-isolated-lab-hosts-2026-08.md) | 无独立交互 Canvas | **当前 30 天验收主机分配** | 7 台独立主机、5+2、TCP 27101 quorum、USD 4/月不限流量 |
| [DLE 全局 RPC 跨组代理](./dle-global-rpc-proxy-2026-08.md) | 无独立交互 Canvas | **当前 RPC 路由冻结** | 任一归档全局 RPC 入口；非本组必须 proxy 到托管组 `historyProviders` |
| [DLE P1 真实成本实测报告](./dle-p1-real-cost-measurement-report.md) | `dle-p1-real-cost-measurement-report.canvas.tsx` | **当前 P1 经济证据门** | 区分真实实测、现役组件代理数据、确定性公式与尚不可测项 |
| [DLE P0/P1 形式化补正评估](./dle-p0-p1-formalization-review.md) | `dle-p0-p1-formalization-review.canvas.tsx` | **当前安全发布门参考** | Burn/mint 守恒、Tendermint/WAL/动态名册向量、OperatorDomain 边界 |
| [经济费率压力模型](./dle-economic-fee-stress-model.md) | `dle-economic-fee-stress-model.canvas.tsx` | **当前配套模型** | 调整成本、流量、预算和流入区间，观察覆盖率与盈亏边界 |
| [5+2 P1 修正评估](./dle-5plus2-p1-corrections.md) | `dle-5plus2-p1-corrections.canvas.tsx` | **部分被后续白皮书替代** | 5+2/4-of-5、L1 队列、Tendermint 与费用拆账演进 |
| [归档平面 P0/P1 安全评估](./archive-plane-p0-p1-security-review.md) | `archive-plane-p0-p1-security-review.canvas.tsx` | **历史评估，核心控制已采纳** | 自适应腐化、运营者相关性、DA 编码与全局队列 |
| [Archive BFT 与裂变安全审查](./archive-bft-fission-security-review.md) | `archive-BFT-fission-security-review.canvas.tsx` | **历史评估，参数已演进** | BFT 基线、五人组风险、非重叠裂变与 Placement |
| [版权内容访问协议](./copyright-content-protocol.md) | `copyright-content-protocol.canvas.tsx` | **跨项目设计参考** | Card Module、PGP 内容交付、first-completer、IPFS 与访问期限 |
| [CONET 外部 USDC 迁 Circle](./conet-circle-usdc-treasury-2026-08.md) | `conet-circle-usdc-treasury.canvas.tsx` | **调研结论，未部署** | CCTP 可跨链代币仅 USDC + USYC；Gateway 仅 USDC；EURC 非 CCTP |

## 使用与更新

1. 交互计算只修改 Cursor 管理目录中的唯一 `.canvas.tsx`。
2. 新建或修改 Canvas 时，必须在同一任务更新本目录对应 Markdown 快照和本索引。
3. 快照至少记录日期、状态、目标、事实来源、假设、公式、结论、替代关系和实现检查项。
4. Canvas 形成白皮书规范结论时，必须同任务同步英中白皮书；历史 Canvas 参数不得直接复制为当前规范。
5. 不在白皮书目录、文档目录或其它位置维护平行 Canvas 快照。
6. 根仓 `src/canvas/` 与独立 `src/conet-layer2` Git 仓同时变更时，须分别提交并在同一归档批次完整 push。
