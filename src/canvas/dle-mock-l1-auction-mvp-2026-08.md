# DLE Mock-L1 拍卖撮合 MVP（2026-08）

- **Canvas 标识：** 无独立交互 Canvas（本页为架构快照）
- **日期：** 2026-08-21（MVP round 9 写回）
- **状态：** **代码已落地（mockL1Only）。** Round 1：本地 fixture + EventIngress + CLI + Explorer 只读。**Round 2：** Archive RPC/hook custody、`mock-auction-demo`、Explorer 会话密钥签名、根仓 `dle:deploy:mock-auction-local`。**Round 3：** Archive 真上链 `settle`（`mockL1Settle.ts`）、`mock-auction-e2e` / `dle:mock-auction-e2e`。**Round 4：** Explorer Settlement summary + `POST /trade/settle` CTA（authority 仍在 Archive）。**Round 5：** Archive `POST /trade/list` + Explorer **List NFT escrow**（卖家会话密钥入 escrow）。**Round 6：** Archive `POST /trade/approve` + Explorer **Approve quote**（买家会话密钥 ERC-20 approve）；e2e/demo 优先 Archive list + approve 后再 settle。**Round 7：** settle preflight（`listTxHash`/`approveTxHash` + 可选 RPC eth_call）；CLI `list`/`approve` + settle `--executeOnChain`；Explorer one-shot **List → Approve → Settle**。**Round 8：** 只读 `POST /trade/preflight` + 共享 `evaluateSettlePreflight`；CLI `preflight`；Explorer **Preflight** CTA + Settlement summary 费用拆分。**Round 9：** `MockDleAuctionSettlement.unlist` + Archive `POST /trade/unlist`；lab `outcome: 'failed'` → `settlement_failed` 后 unlist 回收；Explorer **Unlist escrow** / **Mark failed** / **Cancel sell order**；CLI `unlist`。**不是** CoNET 224422 现网接线，**不是** 生产 CL RANDAO / DePIN gossip。
- **规范优先级：** `runtime/RULES.md` / `docs/mock-l1-auction-mvp.md` / wire contract > 本快照。本页不是第二份规范，也未改白皮书协议结论。

## 事实来源

- 根仓：`src/dle/mocks/MockDleAuctionSettlement.sol`、`test/dle/fixtures.ts`（`deployAuctionFixture`）、`scripts/dle/deployMockL1AuctionLocal.ts`、`scripts/dle/mockAuctionE2eLocal.sh`
- Runtime：`shared/mockL1.ts`、`shared/mockL1Custody.ts`、`shared/mockL1Settle.ts`（含 `listMockL1Auction` / `unlistMockL1Auction` / `approveMockL1AuctionQuote` / `preflightMockL1AuctionSettle`）、`shared/tradeMatch.ts`、`archive/mockL1/engine.ts`、`archive/trade/engine.ts`（`evaluateSettlePreflight` / `/trade/preflight` / `/trade/unlist`）、`archive/bft/modeA.ts`（`replayTradeMatchModeA`）
- Client：`daemon/mock-l1-auction-cli.ts`（含 Round 9 `unlist`、Round 8 `preflight`、Round 7 `list`/`approve`/`--executeOnChain`/`--skipSettlePreflight`）、`daemon/mock-l1-auction-demo.ts`、`daemon/mock-l1-auction-e2e.ts`；Explorer `/mock-auction` + `explorer/src/lib/mockAuctionWire.ts` + Unlist / Mark failed / Cancel + Preflight / List / Approve / one-shot List→Approve→Settle / Settlement summary（含 fee / unlist） / Archive settle CTA

## 假设

- 仅本地 EVM；CoNET 现网虽可能已有 `DLEChainRegistry1155V1`，本阶段 **不** 绑定主网地址
- WaitingPool / `POST /ondemand/hook` **不是** trade mempool
- `beaconSource: labInstantKeccakAfterFreeze` 仅实验室随机源标识
- Web/CLI 可签名订单；**不得**自称 Archive 已通过。配置 `MOCK_L1_RPC_*` 时 Archive **忽略** 客户端 custody flags
- Round 3：卖家须先 `list`；仅 `certificateAuthority` 可 `settle`；demo 假 txHash ≠ e2e 真上链 hash
- Round 4：Explorer 可请求 Archive settle，**不得**在浏览器持有 authority 私钥
- Round 5：Explorer 可带卖家会话私钥请求 Archive `list`（请求作用域；**不**落盘 Archive）；须与 sell `maker` 一致
- Round 6：Explorer 可带买家会话私钥请求 Archive `approve`；须与 buy `maker` 一致；allowance 已足够时可幂等跳过
- Round 7：无 list/approve 的 on-chain settle → 400 且 phase 仍为 `match_certified`；`skipSettlePreflight` 仅实验室绕过
- Round 8：`/trade/preflight` **只读**，不改 phase；与 settle 共用 `evaluateSettlePreflight`
- Round 9：unlist 成功清 `listTxHash`、写 `unlistTxHash`、**不**改 phase；仅卖家可 unlist；已 settled 不可 unlist

## 公式 / 数据

```text
feeAmount        = clearingPrice / 10_000          // 1 bps
scannerReward    = feeAmount / 2
committeeReward  = feeAmount - scannerReward       // 50/50
assignmentStatus BOUND = 2
classId          ASSET=1 STORAGE=2 TRADE=3
Mode A           Open → MatchProposed → MatchCertified
                 → SettlementSubmitted → Settled | SettlementFailed
custody (RPC)    NFT ownerOf + approve*; ERC20 balance + allowance
on-chain path    list(escrow) → approve(quote) → authority.settle(…)
                 | settlement_failed → seller.unlist(reclaim)
Explorer R4      POST /trade/settle { candidateHash, outcome, executeOnChain }
Explorer R5      POST /trade/list { candidateHash, sellerPrivateKey } → listTxHash
Explorer R6      POST /trade/approve { candidateHash, buyerPrivateKey, amount? } → approveTxHash
Explorer R7      list+approve required before executeOnChain; preflightMockL1AuctionSettle eth_call
                 skipSettlePreflight bypass; one-shot List→Approve→Settle CTA
Explorer R8      POST /trade/preflight { candidateHash } → checks + fees (read-only)
                 evaluateSettlePreflight shared with settle gate
Explorer R9      POST /trade/unlist { candidateHash, sellerPrivateKey } → unlistTxHash; clear listTxHash
                 POST /trade/settle { outcome: 'failed' } → settlement_failed
                 POST /trade/cancel (EIP-191) → cancel sell
```

## 冻结结论

1. **双轨：** lab `notL1Nft` 与 mock-L1 真实 `tokenId` 不得混用或升格。
2. **撮合：** Scanner 只提交 `MatchCandidate`；Archive 复查后才 freeze-then-draw；证书驱动结算。
3. **费用：** 成交额 1 bps，scanner / committee 各半；settlement 合约与 Mode A 同口径。
4. **诚实口径：** mockL1Only / non-production beacon；未宣称生产 DePIN。
5. **Round 2 custody：** Archive-side eth_call/hook；Explorer 会话密钥不落盘。
6. **Round 3 settle：** Archive 提交真实 local-RPC `settle`；真 `settlementTxHash` ≠ demo 假 hash。
7. **Round 4 UI：** Explorer 展示 settle 摘要并 HTTP 触发 Archive；authority 不进浏览器。
8. **Round 5 list：** Explorer / Archive 补齐 escrow `list`；无 list 则 on-chain settle 失败属预期。
9. **Round 6 approve：** 买家 ERC-20 approve 与卖家 list 对称；e2e/demo 优先走 Archive `/trade/list` + `/trade/approve`。
10. **Round 7 preflight：** settle 前强制 list+approve 记录（及可选链上 eth_call）；失败不写 `settlement_failed`；CLI/Explorer 可一键跑完整链。
11. **Round 8 read-only preflight API：** `POST /trade/preflight` + CLI/Explorer CTA；返回 fee 拆分；不改 phase。
12. **Round 9 unlist recovery：** list 后 escrow 可经 `unlist` 回收；`settlement_failed` 后同样可 unlist；取消卖单走既有 `/trade/cancel`。

## 替代关系

- 扩展既有 Mode A `TradeOpened`，不替换 genesis Open 回放。
- 不替代白皮书生产 L1 / CL RANDAO 章节。
- `mock-auction-demo`（可假 hash）与 `mock-auction-e2e`（真上链）并列，勿混验收口径。

## 未决项

- 接真实 CL RANDAO / 生产 DePIN gossip（明确超出本 MVP）
- 接 CoNET 224422 现网 registry（明确超出本 MVP）
- 根仓 Hardhat 全量 dle 测试在 CI 绿（可选）

## 实现检查表

- [x] 本地 fixture + mock settlement
- [x] MockL1 注册 adapter（拒 lab 升格）
- [x] Trade EventIngress + certificate 路径
- [x] Mode A match/settle 状态
- [x] CLI + Explorer `/mock-auction` + RULES
- [x] runtime 单元测试 + Canvas / docs 快照
- [x] Round 2：RPC/hook custody + demo + Explorer 签名 + local deploy script
- [x] Round 3：`mockL1Settle` + Archive `executeOnChain` + e2e shell / npm scripts
- [x] Round 4：Explorer Settlement summary + Archive settle CTA
- [x] Round 5：Archive `/trade/list` + Explorer List NFT escrow CTA + `listTxHash`
- [x] Round 6：Archive `/trade/approve` + Explorer Approve quote CTA + e2e/demo list+approve
- [x] Round 7：settle preflight + CLI list/approve + Explorer List→Approve→Settle one-shot
- [x] Round 8：`POST /trade/preflight` + CLI `preflight` + Explorer Preflight CTA + fee summary
- [x] Round 9：`unlist` + Archive `/trade/unlist` + Explorer Unlist / Mark failed / Cancel + CLI `unlist`
- [ ] （可选）根仓 Hardhat 全量 dle 测试在 CI 绿
