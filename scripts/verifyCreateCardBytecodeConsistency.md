# createCard 链上失败与 bytecode 一致性验证

## 交易信息（BaseScan）

- **Tx**: [0xf266d56563b8ece189d9ceb7a6abc9a42e6fd72943ce53045ac8c56df208af59](https://basescan.org/tx/0xf266d56563b8ece189d9ceb7a6abc9a42e6fd72943ce53045ac8c56df208af59)
- **状态**: Fail（execution reverted）
- **From**: 0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1  
- **To**: 0x2EB245646de404b2Dce87E01C6282C131778bb05（Card Factory）
- **Gas**: 4,000,000 limit，3,890,729 used（97.27%）
- **内部交易**: 1 笔 — Deployer `0x6dEcDe360B84D6f75Ae2Ddf777A5B2A96Da1EeCa` 执行 CREATE，Gas Limit 3,397,598；CREATE 未成功（无新合约地址，revert）

## 结论

1. **BaseScan 显示**: 调用 `createCardCollectionWithInitCode`，内部由 Deployer 做 CREATE；CREATE 阶段 revert，故整笔交易失败。
2. **本地与链上 bytecode 一致**:
   - Hardhat 编译产物 `artifacts/.../BeamioUserCard.json` 与 x402sdk 使用的 `src/x402sdk/src/ABI/BeamioUserCardArtifact.json` 已通过 `node scripts/syncBeamioUserCardToX402sdk.mjs` 同步，**bytecode 完全一致**（长度 51646 字符，逐字相同）。
   - 该笔交易 Input Data 中的 initCode 开头与本地 artifact 的 bytecode 开头一致（`60a0604052346103c1576164de80380380610019816103c5565b92833981019060a0818303126103...`），说明链上使用的即为当前本地同一套 bytecode。
3. **revert 原因**: 并非“本地与链上 bytecode 不一致”，而是 **CREATE 执行时合约 constructor 或部署逻辑在链上 revert**（例如 constructor 内校验失败、或 gas 在 CREATE 内耗尽）。可进一步用 BaseScan 的 [Geth Debug Trace](https://basescan.org/vmtrace?txhash=0xf266d56563b8ece189d9ceb7a6abc9a42e6fd72943ce53045ac8c56df208af59) 查看具体 revert 位置，或在本地用 `scripts/diagnoseCreateCardFailure.ts` 配合 admin 私钥做 staticCall 复现。

## 本地复验命令

```bash
# 1) 编译并同步 artifact（保证 Hardhat 与 x402sdk 一致）
npm run compile
node scripts/syncBeamioUserCardToX402sdk.mjs

# 2) 比较 Hardhat 与 x402sdk bytecode
node -e "
const fs = require('fs');
const hh = JSON.parse(fs.readFileSync('artifacts/src/BeamioUserCard/BeamioUserCard.sol/BeamioUserCard.json','utf8'));
const x4 = JSON.parse(fs.readFileSync('src/x402sdk/src/ABI/BeamioUserCardArtifact.json','utf8'));
console.log('Bytecode match:', hh.bytecode === x4.bytecode);
"
```
