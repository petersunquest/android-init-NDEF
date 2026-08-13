# 版权内容访问协议

> **单语开发参考，无对等译本。** 原交互 Canvas：`copyright-content-protocol.canvas.tsx`。该设计属于 Beamio 内容交付协议，不是 CoNET-DLE 共识规范；实现时以当前 `beamio-copyright-content-access-protocol.mdc`、Card/Module 边界与 Cluster/Master 协议为准。

**快照日期：** 2026-08-13
**状态：** 提案级设计。

## 1. 设计边界

- 新业务逻辑放入 `CopyrightContentModuleV1`。
- 普通版权业务不修改 Factory bytecode。
- 链上只保存 hash、授权、期限、winner 和费用状态。
- 明文 index、内容与节点私钥不得写入链、API DB、Indexer 或日志。
- CoNET DePIN 节点只处理 owner 明确授权的内容。

## 2. 系统分层

| 层 | 组件 | 职责 |
| --- | --- | --- |
| Card module | `CopyrightContentModuleV1` | 配置内容、授权节点、购买、first-completer、期限和费用状态 |
| Cluster | 预检与读 API | 校验 issued NFT、buyer 签名/PGP、节点授权、hash、期限和支付状态 |
| Master | 写队列 | 经按链 settle pool 执行配置、购买、完成和费用写链 |
| DePIN node | 内容交付 worker | 解密 owner index、组装 fragments、加密给 buyer、保存并竞速完成 |
| IPFS fragment | 加密 blob | 保存 owner-encrypted index 与 buyer-encrypted package |
| DB/Indexer | 搜索与审计 | 缓存列表、访问日志、短期 URL 元数据和交易展示；链仍是真相 |

## 3. 链上最小状态

| 字段 | 语义 |
| --- | --- |
| `contentIndexHash` | owner 创建的加密 index fragment hash |
| `authorizedNodeKeyHash[tokenId][nodeKeyHash]` | owner 授权节点 key |
| `purchaseId` | `card + tokenId + buyer + nonce/counter` 派生的购买 ID |
| `buyerPgpKeyHash` | 购买签名绑定的 buyer PGP key/hash |
| `accessExpiresAt` | 用户访问截止时间 |
| `storagePaidUntil` | 完成节点已获付保存/服务费截止时间 |
| `completedByNodeKeyHash` | 首个有效完成节点 |
| `buyerEncryptedContentHash` | 加密给 buyer 的内容包 fragment hash |

链上不得存 URL / 评论 / 访问记录数组、明文 PGP key、明文 index 或明文内容。

## 4. 状态机

```text
Configured
  -> Purchased
  -> Delivering
  -> Completed
  -> Expired
```

1. **Configured：** owner 提交加密 index hash、授权节点、有效期和费用策略。
2. **Purchased：** buyer 支付成功，签名绑定 buyer、tokenId、PGP key hash、deadline 与 nonce。
3. **Delivering：** 授权节点链下解密、组装并重新加密给 buyer。
4. **Completed：** 第一个有效节点原子锁定 winner 与 delivery hash。
5. **Expired：** 到期后 API / 节点停止签发访问。

`CopyrightDeliveryCompleted` 的 first-completer 只确定候选 winner。大额内容最终费用结算应等待 buyer 可访问确认、短挑战窗或 heartbeat，避免假 hash 抢跑。

## 5. API

| Endpoint | Actor | 语义 |
| --- | --- | --- |
| `POST /api/copyrightContent/configure` | Owner | 设置 index hash、节点集、访问期和费用策略 |
| `POST /api/copyrightContent/purchase` | Buyer | 支付并绑定 buyer PGP key |
| `POST /api/copyrightContent/complete` | Node | 授权节点提交交付 hash |
| `GET /api/copyrightContent/access` | Buyer | 验签并检查链上期限后返回短期 URL |
| `POST /api/copyrightContent/renewStorage` | Owner | 续费 `storagePaidUntil` |
| `GET /api/copyrightContent/status` | Any | 读链上状态并合并非真相索引信息 |

所有写操作必须 Cluster 完整预检后转发 Master；Master 不重复业务校验。

## 6. 节点交付流程

1. 监听 `CopyrightPurchaseOpened`；
2. 读链确认自身 node key 被授权；
3. 拉取并用节点 PGP private key 解密 index；
4. 拉取、组装 fragments；
5. 用 buyer PGP public key 加密交付包；
6. 保存并取得 `buyerEncryptedContentHash`；
7. 调 complete API；
8. 获胜节点在有效期内签发短期 URL；
9. 到期停止服务，续费须更新链上期限。

## 7. 主要风险

| 风险 | 强制缓解 |
| --- | --- |
| 假完成抢跑 | 节点签名 + hash 可取回性 + buyer confirm/heartbeat/challenge 后结算 |
| 授权节点泄露 index | allowlist、轮换、水印、每节点独立加密 index |
| Buyer PGP 被替换 | buyer 签名绑定 PGP hash、tokenId、deadline、nonce |
| URL 重放 | 短期 HMAC URL、buyer 签名、链上 expiry、节点撤销 |
| 节点收保存费但不服务 | 周期结算、heartbeat、争议与未来任务限制 |
| 链上无限数组 | 只存 mapping/hash/count/winner，列表留 DB/Indexer |
| Fragment hash 不匹配 | 统一 `keccak256(utf8(payload))` 并校验可取回性 |
| 非 Guardian 节点 | 配置前验证 node key |
| 购买隐私泄漏 | 默认公开链模型明确披露；隐私版另设计 |

## 8. 实现阶段

1. **链上最小协议：** module storage、configure、purchase、first-completer、expiry views。
2. **节点 pipeline：** listener、PGP decrypt、fragment assembly、buyer encryption、storage、completion、access URL。
3. **费用与争议：** 周期 B-Unit 保存费、heartbeat、challenge、延迟 payout、惩罚与故障演练。

## 9. 开发红线

- 不得为该业务新增 Factory 专用入口。
- 不得把内容或 index 明文写入 IPFS。
- 不得把长期裸 fragment URL 交给 buyer。
- 不得一次性预付永久保存费。
- 不得仅凭“第一个提交 hash”立即支付全部奖励。
- 不得让中间 entry 节点解密业务内容。
