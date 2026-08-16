# DLE 实验室：三类新链创世 + 随机用户 daemon（2026-08-16）

- **Canvas 标识：** 无独立交互 Canvas；本快照记录实验室 NewChain 平面与 `70.35.205.77` daemon 用户。
- **日期：** 2026-08-16
- **状态：** **身份 wipe 后已 keep 补路由并重新开链。** 资产 / 存储 / 交易创世 7/7 合格；daemon 已按 15–45s `setTimeout` 链随机开链（验收时已见第 4 条）。
- **规范优先级：** 英中白皮书 Mode A / 三类链语义 + 现役 NFT 42 BFT AC > 本快照。**本平面不是白皮书规范变更，也不是 L1 NFT mint。**

## 事实来源

- 现役 BFT 链仍是 NFT **42**，Group ID = `0x3076a806de71ab75b2d48063cc3f1e7d8f8e3d54cb1d45a7469c75c9276f2ad0`，EVM `eth_chainId=0x44c45`（281669），`chainName=CoNET-DLE Testnet`。
- 身份 wipe 后线上 `lab-cli` 一度没有 `/newchain/*`（404）。本轮 `npm run lab:deploy-archive-keep`（`START_ARCHIVE_KEEP_ALL`）补路由；**未 wipe** `bft-state.json` / `ondemand-state.json` / hash store。滚动发版时旧客户端写过不一致条目，已只删 `newchain-state.json` 后 keep 重启，再开新创世。
- 用户机：`70.35.205.77` `/home/peter/dle-newchain-user`（**独立于** `/home/peter/dle-ondemand-clients`）。PID `111957`。
- 部署证据：`src/conet-layer2/pilot/evidence/conet-dle-30d-lab-2026-08/newchain-user-deploy.json`（`acceptedAt=2026-08-16T10:20:20.337Z`）。
- 线上：`GET /newchain/chains` 7/7 一致；三类 `dle_route` → 本组 hash；`dle_getByHash(valueHash)` `status=hit`。

## 假设

- 新链走 **独立 HTTP 平面**（`POST /newchain/request` 写全部 7 台），**不**进 NFT 42 Tendermint / AC 投票。
- `chainNftId` 由 `requestId` 确定性派生（`1000 + keccak % 998_999_000`），避开 42。
- Hash 对象 `kind=ac` 只作实验室索引；证书正文写明 **不是** Archive Certificate。
- 周期只用 `setTimeout` 链；上一轮结束后再排 15–45s。
- 不得覆盖 on-demand 30 客户端，不得重启 leftover EL/CL。

## 公式 / 数据

| 项 | 值 |
|---|---|
| 用户 | `0xd1e0000000000000000000000000000000000001` |
| 类别 | asset=1，storage=2，trade=3 |
| requestId | `keccak256(utf8("dle.lab.newchain.request.v1") \|\| classId(1) \|\| user(20) \|\| nonce(8) \|\| salt(32))`；**不含** `createdAt` |
| 资产创世 | NFT `710292950`，`valueHash=0x9d4e71cb…3e35bc6e` |
| 存储创世 | NFT `170863806`，`valueHash=0xec8d4595…a30deeb9` |
| 交易创世 | NFT `975906027`，`valueHash=0x727ee3e7…efc19511` |
| 7 台同意 | 每条创世 `archiveOk=7/7`，`duplicate=false` |
| 随机续写（验收时） | 资产 NFT `13467352`，7/7 已见 |
| NFT 42 | `bftCertificateAvailable=true`，`route/42` = Group ID hash |
| on-demand | 用户机进程约 31（supervisor+30）未停 |

## 冻结结论

1. **三类创世合格**：Mode A replay 被 7 台接受；证书 `DleLabGenesisCertificateV1` 且 `labOnly` / `notL1Nft` / `notArchiveCertificate` / `height=0x1`；`dle_route` 与 `dle_getByHash` 命中本组。
2. **daemon 用户已部署**：先强制三类 smoke，再随机类别持续开链。入口 `newchain-user-cli.js`，状态 `/home/peter/dle-newchain-user/data/status.json`。
3. **诚实边界**：实验室 stub。**不是** L1 出生证、Treasury burn、Settlement escrow、或 30 天资格。
4. **未改白皮书**；未实现 M6 / 第二组 / 裂变 / 改 5+2。

## 替代关系

- **替代「再开一套 Tendermint 抢 NFT 42」**：新链不进现役 BFT engine。
- **不替代** NFT 42 现役 AC / on-demand 30 客户端 / explorer 已验收的身份平面。
- **不替代** L1 `DLEChainRegistry1155` mint。

## 未决项

- explorer 是否展示实验室新 NFT（非必须；`dle_chainsOf` 已能列出）。
- 随机开链长期速率与磁盘增长观察。
- 生产路径仍须 L1 NFT + Treasury / Settlement，本平面不得外推。

## 实现检查表

- [x] Mode A 三类创世 replay（归档 accept = replay 成功）
- [x] `POST /newchain/request` + persist `newchain-state.json`
- [x] `registerLabChainNft` 后 `dle_route` / `dle_getByHash` 命中
- [x] `lab:deploy-archive-keep` 7/7（AC 仍在；只清过不一致的 `newchain-state.json`）
- [x] `lab:deploy-newchain-user` → `70.35.205.77:/home/peter/dle-newchain-user`
- [x] 7/7 三类各 ≥1，hash hit，NFT 42 仍活，ondemand 进程未停
- [x] 调度为 `setTimeout` 链（禁 `setInterval`）；验收时已出现第 4 条随机链
- [ ] 未宣称 30 天资格 / L1 出生证
- [ ] 未改英中白皮书
