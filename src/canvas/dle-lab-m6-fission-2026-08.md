# 实验室 M6：第二归档组裂变（2026-08-16）

- **Canvas 标识：** 无独立交互 Canvas
- **日期：** 2026-08-16
- **状态：** 用 7 台绿场主机落地实验室第二归档组 + 跨组 hash 证据；**不是** 生产 DePIN，**不是** 30 天资格。当时 G2 Group ID 是实验室 keccak（诚实占位）。**随后**由 `dle-lab-g2-l1-register-2026-08.md` 补 L1 `registerLiveGroup`（tx `0xf781f2c2…876d5153`）；本页不改写成「当时已有 L1 tx」。
- **规范优先级：** 英中白皮书 §5.2.0e > runtime `RULES.md` §Archive > 本快照。本页不是第二份规范。

## 事实来源

- 用户指定 7 台新机：`170.205.39.135`、`167.254.243.162`、`212.52.0.166`、`212.52.0.165`、`212.52.0.164`、`212.52.0.160`、`212.52.0.149`。SSH 盘点：无 geth/beacon/validator，27101 空闲，无既有 `dle-30d-lab`。
- 第一组 7 台归档、on-demand 30、newchain-user、NFT 42 BFT **保持运行**。G1 只允许 keep 滚动重启（不 wipe）。禁止重启遗留 EL/CL。
- Runtime：`labRoute.ts` `planeDirectory`；`hashPipe.ts` `locatePlane`；`hop1.ts` 外组无本地 fallback；`jsonrpcFacade.ts` 仅 `planeWideNull` 返回 JSON-RPC `null`。
- Pilot：`pilot/lab/hosts-m6-g2.json`、`pilot/inventories/conet-dle-m6-g2-2026-08.json`、`pilot/src/m6.ts`。目录 `/home/peter/dle-m6-g2`，端口 27101。
- Explorer：Clusters = \(G_e\)；Chain ID 下 Group ID 胶囊仍只链第一组 bootstrap tx；第二组 hash **无** Blockscout `/tx/`。
- Git：CoNET-DLE `ba141c4`；docs `bc10ad1`（开发文案 `gitbook/developers/l2.md` § Lab gather (2026-08-16)）。

## 假设

- 第二组 Group ID 在 L1 登记前使用实验室 hash，不得假装成 register tx。
- G2 **关闭** BFT 与 on-demand，避免与 NFT 42 AC / waiting pool 竞争。
- 跨组 gather 走 `planeDirectory` 钱包，**不**把 G2 写入第一组 BFT `peers`。

## 公式 / 数据

```text
G1 Group ID = 0x3076a806de71ab75b2d48063cc3f1e7d8f8e3d54cb1d45a7469c75c9276f2ad0
             = L1 bootstrap register tx
G2 Group ID = keccak256(utf8("dle.lab.group.m6.g2.v1"))
             = 0x7b3b8eb959dcc0f75a309fcc16e7f840efe76dc27f2ef0d4eca8b8617f9b1a07
Marker NFT  = 6000000006
Marker hash = keccak256(utf8("dle.lab.fission.marker.v1|" + canonicalGroupId))
Ge          = distinct liveGroupIds (canonical)
plane null  = every live group trusted this-group notFound
timeout     = unavailable  (never JSON-RPC null)
```

## 冻结结论

1. **裂变只加 Group ID，不加实验室新链。** 第一组上新开的 lab 链继续复制 NFT 42 的 Group ID，Clusters 不因此 +1。
2. **全平面 `null` 是最严证据。** `Ge === 1` 或 `thisGroupOnly` 仍是本组 `notFound`。一组超时或缺少 plane wallets → `unavailable`。
3. **hop-1 只打托管组。** locate 得到 `chainNftId` 后只问 `historyProviders` / 该组 `planeDirectory`。外组 hop 失败不得用本地副本当 RPC 真相。
4. **诚实口径。** G2 hash ≠ L1 tx；HMAC / HTTP / lab beacon ≠ 生产 DePIN；完成本里程碑 **不** 开始 30 天资格。

## 替代关系

- 替代旧快照「M6 仍开放」口径：`dle-mvp-hash-lookup-fix-2026-08.md`。
- 不替代 §5.2.0d 生产跨组 proxy（仍须 L1 routing registry + DePIN 传输）。
- 不替代第一组 NFT 42 BFT / on-demand 30。

## 未决项

- G2 L1 `registerLiveGroup` — 已由 `dle-lab-g2-l1-register-2026-08.md` 关闭。
- 生产 DePIN 传输替换实验室 HTTP `:27101`。

## 实现检查表

- [x] G2 独立 hosts / inventory / labDir，不改坏第一组 loader
- [x] `planeDirectory` + `locatePlane` + `thisGroupOnly`
- [x] G2 `enableBft=false` / `enableOndemand=false` / `seedFissionMarker=true`
- [x] 测试 `runtime/test/m6-plane.test.ts`
- [x] CLI `lab:deploy-m6` / `lab:accept-m6`
- [x] runtime / explorer / daemon RULES 写回
- [x] 英中白皮书 Revision 2026-08-16
- [x] 七台 G2 部署 + G1 keep + accept 证据 JSON（`pilot/evidence/conet-dle-m6-g2-2026-08/m6-plane-accept.json`）
- [x] Explorer 公网 SPA 发版 `https://dle.conet.network`（Clusters=2 + 无 `/tx/` 的 Lab Group ID 胶囊）
- [x] GitBook `l2/explorer.md` 与开发文案 `developers/l2.md` 诚实写 `liveGroupCount: 2` / G2 非 L1 tx
