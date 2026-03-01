# BeamioUserCard 关联合约依赖检查

本仓库内 **BeamioUserCard** 及其关联合约均通过相对路径 `"./xxx.sol"` 引用同目录（`src/BeamioUserCard/`）下的文件，**不存在多版本或旧版引用**。

## 依赖关系一览

| 合约 | 引用 | 结论 |
|------|------|------|
| **BeamioUserCard.sol** | `./BeamioERC1155Logic.sol`, `./BeamioCurrency.sol`, `./Errors.sol`, `./RedeemStorage.sol` | ✅ 均同目录，使用新合约 |
| **BeamioUserCardFactoryPaymasterV07.sol** | `./BeamioUserCard.sol`, `./BeamioCurrency.sol`, `./BeamioERC1155Logic.sol`, `./Errors.sol`；Deployer 通过接口 `IBeamioDeployerV07` 调用 | ✅ 使用新合约 |
| **BeamioUserCardRedeemModuleVNext**（RedeemModule.sol） | `./Errors.sol`, `./RedeemStorage.sol` | ✅ 使用新合约 |
| **RedeemStorage.sol** | 无其他 Beamio 合约引用 | ✅ 独立库 |
| **BeamioUserCardDeployerV07.sol** | `./Errors.sol` | ✅ 使用新合约 |
| **BeamioERC1155Logic.sol** | `./BeamioCurrency.sol`, `./Errors.sol` | ✅ 使用新合约 |

## 说明

1. **BeamioUserCard** 仅使用 **BeamioERC1155Logic** 的常量（`POINTS_ID`, `POINTS_DECIMALS`, `NFT_START_ID`, `ISSUED_NFT_START_ID`），未使用该库的 `Layout` 或 `Tier[]` 存储。
2. **BeamioUserCard** 自行定义 `struct Tier`（含 `upgradeByBalance`）和 `Tier[] public tiers`，tier 逻辑与存储均在主合约内。
3. **BeamioERC1155Logic** 库内仍保留旧版 `struct Tier`（无 `upgradeByBalance`）和 `Layout.tiers`，供库内逻辑使用；当前 **BeamioUserCard** 不依赖该库的 tier 存储，故无冲突。若将来有合约通过该库的 `Layout` 使用 tiers，再考虑在库的 `Tier` 中增加 `upgradeByBalance` 以与 **BeamioUserCard.Tier** 对齐。
4. **BeamioUserCardFactoryPaymasterV07** 仅使用 **BeamioERC1155Logic** 的 `NFT_START_ID` 常量；Deployer 通过接口调用，未直接 import 部署器合约。
5. 所有上述合约的 import 均为 `"./..."`，指向 `src/BeamioUserCard/` 下唯一一份实现，无“旧版”或重复文件。

**结论：BeamioUserCard、BeamioUserCardFactoryPaymasterV07、BeamioUserCardRedeemModuleVNext（RedeemModule.sol）、RedeemStorage、BeamioUserCardDeployerV07、BeamioERC1155Logic 均引用同目录下的新合约，无需替换或更新引用路径。**
