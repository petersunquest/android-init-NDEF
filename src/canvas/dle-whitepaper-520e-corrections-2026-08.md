# 白皮书 §5.2.0e 新增修正如何落到上一轮（2026-08-15）

- **Canvas 标识：** `dle-whitepaper-520e-corrections-2026-08.canvas.tsx`
- **日期：** 2026-08-15
- **状态：** 审查完成；三分状态 + 方案 C 已在同一组实验室 keep 落地；旧 freezer 投影泄漏已修并 keep 发版
- **规范优先级：** 英中白皮书 §5.2.0e > 本快照。本页不是第二份规范。

## 事实来源

- 英中白皮书 Revision 2026-08-15：hash RPC 事实核查三分状态；PrevoteQC 一等 `kind=prevoteQc`（方案 C）；新 kind 必须 typed `HashObjectKind`，禁止 AC 字段别名。
- 上一轮：清零后 M0–M5 hash 管道（`99af251`）+ `1f3fe14` PrevoteQC / `notFound`。
- 本轮 live smoke（keep 后，7/7 + `https://dle.conet.network/rpc`）：
  - 未知 `0xdeadbeef×8` → `notFound` `scope=thisGroup` `planeWideNull=false`
  - tip AC `0x79e9732d…625e` → `hit` `kind=ac` `chainNftId=42`
  - `prevoteQCRef` `0x7e03f8cb…f560` → `hit` `kind=prevoteQc` `DleLabPrevoteQcV1`
  - `tipStateRoot` / `membershipRoot` → `notFound`
  - `dle_proveHash(未知)` → `non-inclusion` `planeWideNull=false` `notHotGet=true`
  - `hashIndexRoot=0xad5de3cb…0b38` `leafCount=2` `committedInAc=false`
- `lab:accept-archive`：`ok` / `meshOk` / `protectedOk` / `bftOk`
- `npm run runtime:test`：51/51（含 `legacy freezer body must not alias as prevoteQc`）

## 假设

- 「上一轮」= 清零后已上线的同一组 7 归档，不是第二实验室组。
- 发版只用 `lab:deploy-archive-keep`；禁止 `START_ARCHIVE` wipe。
- 不改 `DLE_ARCHIVE_CLIENT_VERSION`（仍 `0.2.0`）。
- hop-1 仍按 `(nft, height)` 取整槽；投影在 `getByHash`。

## 公式 / 数据

```text
hit         = 本组已承诺语料含 hash → locator + project(kind)
notFound    = 本组目录已完整检索且不在语料；planeWideNull=false；scope=thisGroup
unavailable = 核查未完成（超时 / hop 失败无回落 / hint 冲突 / adapter 未挂 / 非法输入）

freezerKey  = (chainNftId, height)
slot        = DleLabFreezerSlotV1 { objects: { ac?, prevoteQc?, … } }
legacy raw  = 仅当 kind=ac 才投影；其它 kind 不得 alias
```

## 冻结结论

1. 白皮书新增修正是对上一轮 M0–M5 的语义收紧，不是新里程碑。
2. 本组查完 miss **必须** `notFound`，不得再回 `unavailable` 或 JSON-RPC `null`。
3. `prevoteQCRef` **必须** 独立 `kind=prevoteQc` 对象；`tipStateRoot` / `membershipRoot` 在未有独立 kind 前 **不是** 热 locate 键。
4. 滚动 keep 时，旧裸 AC freezer **不得** 被投影成 PrevoteQC。
5. M6 / 30 天资格仍未开。

## 替代关系

- 收紧 `dle-mvp-hash-lookup-fix-2026-08.md` 的 M0。
- 补 `dle-hash-rpc-fact-check-2026-08.md`：方案 C 已上线，并记录投影泄漏修复。
- 不推翻 hop-1 / `chainNftId` / HashIndexTree 热路径分工。

## 未决项

- `tipStateRoot` / `membershipRoot` 何时各自成为独立 `HashObjectKind`。
- M6 第二组 + 跨组证据。
- 实验室 HTTP / HMAC / lab beacon 仍不是生产 DePIN。

## 实现检查表

- [x] 白皮书三分状态对照上一轮初版 `unavailable`
- [x] `prevoteQc` 一等对象；tip/membership 不编目
- [x] `projectHashObject` 旧裸 AC 不得 alias 其它 kind
- [x] `runtime:test` 51/51
- [x] `lab:deploy-archive-keep` 7/7（不清零）
- [x] `lab:accept-archive` mesh / protected / bft
- [x] 公开 RPC smoke：notFound / prevoteQc / leafCount=2
