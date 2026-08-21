# DLE Mock-L1 拍卖撮合 MVP（2026-08）

- **Canvas 标识：** 无独立交互 Canvas（本页为架构快照）
- **日期：** 2026-08-20
- **状态：** **代码已落地（mockL1Only）。** 本地 Hardhat/Anvil + runtime EventIngress + Explorer `/mock-auction` + CLI。**不是** CoNET 224422 现网接线，**不是** 生产 CL RANDAO / DePIN gossip。
- **规范优先级：** `runtime/RULES.md` / `docs/mock-l1-auction-mvp.md` / wire contract > 本快照。本页不是第二份规范，也未改白皮书协议结论。

## 事实来源

- 根仓：`src/dle/mocks/MockDleAuctionSettlement.sol`、`test/dle/fixtures.ts`（`deployAuctionFixture`）、`test/dle/mock-auction-*.test.ts`
- Runtime：`shared/mockL1.ts`、`shared/tradeMatch.ts`、`archive/mockL1/engine.ts`、`archive/trade/engine.ts`、`archive/bft/modeA.ts`（`replayTradeMatchModeA`）
- Client：`daemon/mock-l1-auction-cli.ts`（`npm run mock-auction-cli`）、`explorer` 路由 `/mock-auction`
- Lab 旁路仍存在：`POST /newchain/request` + `notL1Nft`；本 MVP **并行** `MockL1ChainRegistrationV1`，禁止升格 lab 请求

## 假设

- 仅本地 EVM；CoNET 现网虽可能已有 `DLEChainRegistry1155V1`，本阶段 **不** 绑定主网地址
- WaitingPool / `POST /ondemand/hook` **不是** trade mempool
- `beaconSource: labInstantKeccakAfterFreeze` 仅实验室随机源标识
- Web/CLI 只签名与查询；**不得**自称 Archive 已通过

## 公式 / 数据

```text
feeAmount        = clearingPrice / 10_000          // 1 bps
scannerReward    = feeAmount / 2
committeeReward  = feeAmount - scannerReward       // 50/50
assignmentStatus BOUND = 2
classId          ASSET=1 STORAGE=2 TRADE=3
Mode A           Open → MatchProposed → MatchCertified
                 → SettlementSubmitted → Settled | SettlementFailed
```

## 冻结结论

1. **双轨：** lab `notL1Nft` 与 mock-L1 真实 `tokenId` 不得混用或升格。
2. **撮合：** Scanner 只提交 `MatchCandidate`；Archive 复查后才 freeze-then-draw；证书驱动结算。
3. **费用：** 成交额 1 bps，scanner / committee 各半；settlement 合约与 Mode A 同口径。
4. **诚实口径：** mockL1Only / non-production beacon；未宣称生产 DePIN。

## 替代关系

- 扩展既有 Mode A `TradeOpened`，不替换 genesis Open 回放。
- 不替代白皮书生产 L1 / CL RANDAO 章节。

## 未决项

- 接真实 CL RANDAO / 生产 DePIN gossip（明确超出本 MVP）
- 接 CoNET 224422 现网 registry（明确超出本 MVP）

## 实现检查表

- [x] 本地 fixture + mock settlement
- [x] MockL1 注册 adapter（拒 lab 升格）
- [x] Trade EventIngress + certificate 路径
- [x] Mode A match/settle 状态
- [x] CLI + Explorer `/mock-auction` + RULES
- [x] runtime 单元测试 + Canvas / docs 快照
- [ ] （可选）根仓 Hardhat 全量 dle 测试在 CI 绿
