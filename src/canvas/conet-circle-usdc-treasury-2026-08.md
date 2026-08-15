# CONET 外部 USDC 国库迁 Circle 轨道

- **Canvas 标识：** `conet-circle-usdc-treasury.canvas.tsx`
- **日期：** 2026-08-14
- **状态：** 调研结论（未改生产合约 / 未部署）
- **主要用途：** 评估「外部原生 USDC 只锁在 Circle 轨道，CoNET 只做 canonical mint/burn」是否成立

## 事实来源

- 现役国库：`TreasuryBridgeV3` `0xa208982212978550594A7FEEB70a61665d129003`（`beamio-treasury-v3-only.mdc`）
- 现役入金：Base 原生 USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` + x402 settle + `initiateLockMint`
- Circle CCTP 支持链 / domain：https://developers.circle.com/cctp/concepts/supported-chains-and-domains（2026-08-14 抓取）
- Circle Gateway：https://developers.circle.com/gateway ；主网含 ETH/Base/Arb/OP/Polygon/Avalanche/Solana 等；**不含 CoNET**
- Arc 公开主网：2026-09-16（Circle 新闻稿）；CCTP 域表现仅 **Arc testnet = domain 26**
- Circle 官方聚合文：CCTP Fast → Arc → Gateway deposit 形成统一余额（testnet 示例）

## 假设

- 「Circle 链」在产品上指 **Arc + CCTP + Gateway**，不是再发明一条 CONET 侧链。
- CoNET 224422 **不会**被 Circle 列为原生 USDC / CCTP 域。
- 用户出金目标限于 Circle 已发行原生 USDC 的链。

## Circle 可跨链代币（2026-08-14 补研）

**结论：CCTP 官方 Supported tokens 只有 USDC 与 USYC。Gateway 只有 USDC。EURC / cirBTC 是多链原生发行或 Mint 申赎，不是 CCTP burn-and-mint。**

| 代币 | 产品 | 跨链范围 |
|---|---|---|
| **USDC** | CCTP V2 | 全部 CCTP 域，**除** BNB Smart Chain |
| **USYC** | CCTP V2 | **仅** Ethereum ↔ BNB Smart Chain（BNB 域标 USYC only） |
| USDC | Gateway | 主网统一余额；只存/只 mint USDC |
| EURC | 原生发行 + Circle Mint | ETH/Base/AVAX/SOL/XLM/World/Cronos/Arc testnet；**不在** CCTP 代币表 |
| cirBTC | Circle Mint | Ethereum + Arc testnet；**不在** CCTP 代币表 |
| USDT / DAI / 包装 USDC | — | Circle 无 mint 权；CCTP/Gateway 不支持 |

- CCTP 域表：https://developers.circle.com/cctp/concepts/supported-chains-and-domains
- Arc 原生（非桥接）：USDC（gas）+ EURC + USYC；主网 CCTP 仍未正式列入（现为 Arc testnet domain 26）
- USYC 有机构资格门槛（非美国人士等），不能当 CONET 国库替代轨

## Circle USDC mint/burn（2026-08-14 补研）

**结论：原生 USDC 合约不向第三方国库开放 mint/burn；国库可用的是 CCTP/Gateway 的公开 burn-and-mint 入口。**

| 层 | 指令 | CONET 国库 |
|---|---|---|
| FiatToken `mint` / `burn` | `onlyMinters`；`masterMinter` 只配置 Circle 储备 minter 与 CCTP TokenMinter | 不能直调 |
| CCTP TokenMinter | `onlyLocalTokenMessenger` | 不能直调 |
| TokenMessengerV2 `depositForBurn` / `WithHook` | 任意已 approve 的持币地址 | **能**（跨链 burn） |
| MessageTransmitterV2 `receiveMessage` | 任意或指定 caller + Circle attestation | **能**（触发目标链 mint） |
| Gateway deposit / spend | 存款人签名 + attestation | **能**（统一余额出金 mint） |

- FiatToken 设计：https://github.com/circlefin/stablecoin-evm/blob/master/doc/tokendesign.md
- CCTP 接口：https://developers.circle.com/cctp/references/contract-interfaces
- 单笔 CCTP burn 上限 **$10M**；hook 由目标合约/relayer 解释，CCTP 核心不执行 hook。
- 普通用户也不能对 USDC 调 `burn`；跨链销毁只经 TokenMessenger → TokenMinter。

## 冻结结论

1. **方向成立：** 外部原生 USDC 锁仓面应收敛为 1（Circle 枢纽），不要在 ETH/Solana/Arb 等链部署 CONET USDC 国库。
2. **CoNET 国库不能删：** `conet-USDC` 只能由 `TreasuryBridgeV3` 增发；Circle 不在 224422 mint。
3. **推荐形态：** Gateway 作外部统一余额 +（Arc 主网 CCTP 就绪后）Arc 作锁仓锚；CoNET 只保留 LockMint / BurnRelease。
4. **不要等 Arc 才验证出金：** Gateway 主网已含 Base，可先做「一处库存、多链 spend」。
5. **生产锁仓迁 Arc 的门：** 公开主网已上，且 CCTP/Gateway **正式列出 Arc mainnet 域**。

## 公式 / 数据

- 枢纽可释放原生 USDC ≤ 历史已锁且未释放数量（Gateway 不凭空 mint）。
- CCTP Fast：约 8–20s；Gateway spend：余额建立后 &lt;500ms。
- Gateway 信任中断：7 天 `initiateWithdrawal` → `withdraw`。

## 替代关系

- 取代：「每条用户出金链部署一套 USDC 国库并预充」。
- 不取代：CoNET 上 V3、conet-USDC、Master Conet pool 的 LockMint。
- 现役 Base 锁仓面在 P2 完成前仍是生产锚，不可与 Arc 双锁并存。

## 未决项

- Arc mainnet 的 CCTP domain id 与 Gateway 是否 day-one 上线。
- x402 是否继续只在枢纽链收 USDC，还是 UI 先 CCTP 再 settle。
- 合规：Arc 未宣称 NYDFS 审查；长期金库用 Gateway 主网 vs 锁在 Arc。

## 实现检查表

- [ ] 外部锁仓面数量 = 1
- [ ] 其它链只调 Circle TokenMessenger / Gateway Wallet
- [ ] CoNET mint 只经 V3
- [ ] Circle 侧与 CoNET LockMint 拆 Master 占用池
- [ ] 不可信 CCTP/Gateway 结果不覆盖已有 LockMint / burn 状态
- [ ] Arc 锁仓适配器若部署须 UUPS、地址稳定
