# Beamio Cross-Chain Gateway

Beamio Cross-Chain Gateway（简称 **BCG**）是一个面向 AAC（Atomic Asset
Container）的跨链资产锁定、证明与铸造协议设计项目。

本目录目前是**设计与 MVP 规格**，不代表主网已经部署了无投票的跨链轻客户端、
Base 状态证明验证器或 permissionless mint gateway。所有主网资金路径在实现和
审计完成前保持关闭。

## 文档

- [AAC 跨链资产确权白皮书](./WHITEPAPER.zh-CN.md)
- [MVP 阶段与验收标准](./MVP.zh-CN.md)

## 设计结论

1. AAC 的 `isReserved` 只能表达目标资产的状态机状态，不能代替来源链最终性证明。
2. Merkle inclusion proof 只能证明“某状态承诺下存在某记录”；必须额外验证来源
   链区块头、状态根和最终性，才能作为无信任铸造依据。
3. MVP 先采用受限资产、受限调用者和可暂停网关，先证明“锁定 → 证明 → 预留 →
   铸造/释放”的确定性状态机，再逐步开放开发者权限。
4. LayerZero 可以作为可插拔消息传输适配器，但不是本项目的状态证明或最终性真相
   来源。BCG 的安全核心是来源链证明验证器与目标链状态机。

## 目录边界

- 本阶段只新增规格文档，不修改既有 `TreasuryBridgeV3`、
  `ConetTreasuryPeer`、`GBTokenV2` 或生产部署配置。
- 后续实现应作为独立的 Card/Account extension 或 gateway 模块评审，不能直接
  绕过现有 Treasury 权限模型开放铸造。
