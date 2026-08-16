# 实验室 M7：typed tip / membership 根（2026-08-16）

- **Canvas 标识：** 无独立交互 Canvas
- **日期：** 2026-08-16
- **状态：** 方案 C 已 keep 发版 + 公开 Explorer 目视 pills；`tipStateRoot` / `membershipRoot` 为一等 `HashObjectKind` + typed 对象；**不是** AC 字段别名；**不是** L1 登记；**不是** 30 天资格
- **规范优先级：** 英中白皮书 §5.2.0e > runtime `RULES.md` §Archive M7 > 本快照。本页不是第二份规范。

## 事实来源

- 白皮书原先把这两个 32 字节根列为「在各自拥有独立 kind 之前不是热 locate 键」。M7 关闭该缺口。
- Runtime：`hashLookup.ts` `HASH_OBJECT_KINDS` 含 `tipStateRoot` / `membershipRoot`；`hashPipe.ts` `indexLabTypedRoot` / `indexLabCertificateRoots`；BFT `indexCertificate` 与 newchain `indexRecord` 做 side-index。
- 对象：`DleLabTipStateRootV1` / `DleLabMembershipRootV1`（`labOnly: true`，`notAcFieldAlias: true`）。
- Explorer：`HashLookupPage.tsx` pills **Tip state root** / **Membership root**。
- 测试：`runtime/test/hash-lookup.test.ts`（独立 height，避免共享 freezer 槽污染）。

## 假设

- 不把 M5 `HashIndexTree` 写入 AC。
- 不把 HMAC / HTTP `:27101` 写成生产 DePIN。
- 不擅自做 G2 L1 `registerLiveGroup`。
- G2 `enableBft: false`，因此 live M7 对象主要出现在 G1 NFT 42 AC（及 G1 newchain `tipStateRoot`）。

## 公式 / 数据

```text
kind ∈ { ac, prevoteQc, tipStateRoot, membershipRoot, block, tx, daRootProof }
same (kind, nft, hash) later height → first-write-wins
ZERO32 / invalid → skip (not catalogued)
kind/nft conflict → skipped:'conflict' (parent AC still ok)
side-index fail → MUST NOT fail parent AC
```

## 冻结结论

1. **热 locate 键。** 客户端可用 `dle_locateHash` / `dle_getByHash` 直接查这两个根；命中返回 typed 对象，不是 AC。
2. **禁止别名。** `boundField` 不得把这些 hash 编目成 `kind=ac`。
3. **Membership 稳定。** 组内 `membershipRoot` 常跨 height 不变 → first-write-wins。
4. **诚实口径。** 完成本里程碑仍不是 30 天资格，也不是生产裂变。

## 替代关系

- 替代 `dle-mvp-hash-lookup-fix-2026-08.md` 里「M7 仍开放 / 现在不编目」口径。
- 不替代 M6 跨组 gather，也不替代 §5.2.1 上 `membershipRoot` 作为 AC 投票字段的共识语义。

## 未决项

- G2 L1 `registerLiveGroup` — 已由 `dle-lab-g2-l1-register-2026-08.md` 关闭。
- 生产 DePIN 传输替换实验室 HTTP。
- 是否把 M5 树写入 AC（仍开放）。

## 实现检查表

- [x] `HASH_OBJECT_KINDS` 含 tip / membership
- [x] typed 对象 + first-write-wins + ZERO32
- [x] BFT / newchain side-index 不 fail 父 AC
- [x] hash-lookup 单测全绿
- [x] 英中白皮书 §5.2.0e / §15.20 / 附录 A
- [x] runtime / explorer RULES + GitBook Lab gather
- [x] Keep 发版 G1/G2 + Explorer live smoke（tip `0x08c83980…b9ca01e1` / membership `0xdeb200a9…79e22241`；pills Hit + kind + `chainNftId 42`）
