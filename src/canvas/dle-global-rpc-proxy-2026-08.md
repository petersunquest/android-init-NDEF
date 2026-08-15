# DLE 全局 RPC 真相与跨组代理（2026-08-14）

- **Canvas 标识：** 无独立交互 `.canvas.tsx`（白皮书规范冻结快照）
- **日期：** 2026-08-14
- **状态：** 已写入英中白皮书 §5.2.0d；非运行时验收项
- **事实来源：** 用户产品冻结；既有 L1 `route` / `historyProviders` / `archivesOf`；既有跨组只读副本规则
- **假设：** 每个 live archive 可被客户端当作全平面 RPC 入口；托管组仍是权威 origin
- **公式 / 数据：** 无新数值。判定：`route(chainNftId) =? self.groupId`
- **冻结结论：**
  1. 任一活跃归档必须暴露同一套全局 DLE RPC 面。
  2. 非本组查询必须代理到 `historyProviders(chainNftId)` = `archivesOf(targetGroupId)`。
  3. 本地跨组副本不得作为 RPC 真相；失败须 unavailable，不得本地拼凑成功。
  4. 代理不授予外组共识/写权；客户端终局仍是 AC。
- **替代关系：** 取代「带证明包即可用本地副本直接应答公开 RPC」的旧读法。
- **未决项：** 代理超时、扇出、重试次数、计费；实验室 27101 心跳 mesh 仍不是本规则的生产实现。
- **实现检查表：**
  - [ ] runtime `/rpc` 按 `route()` 分流
  - [ ] 外组请求转发至 L1 名册钱包，禁止改写 AC
  - [ ] 托管组无应答 → 错误而非本地 replica 200
