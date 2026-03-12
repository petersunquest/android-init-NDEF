# BaseScan err_code_2 (Bytecode Mismatch) 排查指南

**注意**：Constructor 的 URI 参数必须以代码库为准（`beamioServer.ts`、`BeamioUserCard.sol`、Factory 部署脚本），不要从链上 bytecode 解析推断。

## 现象

验证 BeamioUserCard 时 BaseScan 返回：
```
Error! Unable to find matching Contract Bytecode and ABI
Bytecode (what we are looking for): 60a06040523461033e5761622d80...
vs what we got: 60a06040523461033e5761624980...
```

## 差异分析

| 位置 | 链上 (期望) | 本地编译 |
|------|-------------|----------|
| 前缀 | `61622d` | `616249` |
| 含义 | PUSH2 0x622d (25133) | PUSH2 0x6249 (25161) |
| 差异 | 本地多约 28 字节 | 可能来自 TotalSupplyStorage 等改动 |

## 可能原因

1. **Constructor 参数不一致**
   - 正确 URI 必须与 Factory metadataBaseURI 一致: `https://beamio.app/api/metadata/0x`
   - **禁止使用** `api.beamio.io`（域名已废弃）

2. **源码与部署时不同**
   - 链上实现可能是旧版（无 TotalSupplyStorage、旧 assembly 注释）
   - 当前源码已改动，编译产物与链上不一致

3. **evmVersion 必须为 cancun**
   - `Bytes.sol` 使用 `mcopy`，仅 Cancun 支持
   - 无法改用 paris/osaka

## 建议步骤

1. **确认 Constructor 参数**（必须与 Factory metadataBaseURI 一致）:
   ```bash
   # URI 必须为 https://beamio.app/api/metadata/0x（与 deployUserCardFactory 等脚本一致）
   CARD=<地址> URI="https://beamio.app/api/metadata/0x" CURRENCY=4 PRICE=1000000 \
   OWNER=<cardOwner> GATEWAY=0x46E8a69f7296deF53e33844bb00D92309ab46233 \
   npx hardhat run scripts/verifyBeamioUserCard.ts --network base
   ```

2. **使用 Standard JSON 手动验证**:
   - 上传 `deployments/base-BeamioUserCard-basescan-standard-input.json`
   - 或 `base-BeamioUserCard-basescan-minimal.json`
   - 在 BaseScan 选择 "Solidity (Standard-Json-Input)"

3. **若仍失败**:
   - 链上实现可能为旧部署，需用**部署时的源码**重新编译并验证
   - 或重新 createCard 部署新卡，再用当前 artifact 验证
