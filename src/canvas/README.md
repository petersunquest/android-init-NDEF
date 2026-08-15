# Canvas 开发思路归档

> **Git 可版本控制归档。** 交互式 `.canvas.tsx` 由 Cursor 管理并保持唯一运行副本；本目录保存其 Markdown 思路快照，供白皮书、协议实现、测试与后续审查引用。快照不是第二份可执行 Canvas，也不是协议规范真相来源。

**归档基线：** 2026-08-13
**规范优先级：** 当前代码与英中白皮书 / 独立规范 > 本目录 Canvas 快照 > 历史讨论。
**全局守则：** `.cursor/rules/conet-layer2-whitepaper-bilingual-sync.mdc` 的 “Canvas Git 归档（强制）”。

## 归档清单

| Canvas 快照 | 交互 Canvas 标识 | 状态 | 主要用途 |
| --- | --- | --- | --- |
| [DLE MVP 分期运行时](./dle-mvp-phased-runtime-2026-08.md) | `dle-mvp-phased-runtime.canvas.tsx` | **当前归档/RPC/on-demand/explorer 分期** | P0–P3 实验室已落地；**P4 公开 `https://dle.conet.network` 已显现 AC 与 P3 7+2**；P5 待书面授权 |
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
