# 重新部署 BeamioUserCard（CCSA 卡）并更新依赖

BeamioUserCard 的**单张实例**（CCSA 卡）通过工厂 `createCardCollectionWithInitCode` 发行。重发卡后需在库内更新地址，以下为统一流程。

## 1. 发行新卡（二选一）

在**仓库根目录**已安装依赖的前提下：

**方式 A：x402sdk**

```bash
cd src/x402sdk && npx ts-node src/createCCSA.ts
```

**方式 B：API server（与 MemberCard 同源配置）**

```bash
cd "scripts/API server" && npx ts-node createCCSA.ts
```

成功后会打印新卡地址，例如：`CCSA card created: 0x...`

## 2. 全库替换为新地址

将上一步得到的地址写入配置（x402sdk、SilentPassUI、deployments），在**仓库根目录**执行：

```bash
NEW_CCSA_ADDRESS=0x<新地址> node scripts/replace-ccsa-address.js
```

或：

```bash
node scripts/replace-ccsa-address.js 0x<新地址>
```

## 3. 被更新的文件与依赖关系

| 文件 | 说明 |
|------|------|
| `src/x402sdk/src/chainAddresses.ts` | `BASE_CCSA_CARD_ADDRESS`，x402sdk 与 MemberCard 唯一数据源 |
| `src/SilentPassUI/src/config/chainAddresses.ts` | `BeamioCardCCSA_ADDRESS`，前端 contracts 使用 |
| `deployments/base-UserCard-0xEaBF0A98.json` | 部署记录 |

- **MemberCard**（`src/x402sdk/src/MemberCard.ts`、`scripts/API server/MemberCard.ts`）从 `chainAddresses.BASE_CCSA_CARD_ADDRESS` 读取，无需再改。
- **SilentPassUI**（`src/SilentPassUI/src/utils/contracts.ts`）从 `BASE_MAINNET_FACTORIES.BeamioCardCCSA_ADDRESS` 读取，无需再改。

## 4. 工厂与 Gateway 地址

- **Card Factory**：见 `chainAddresses.BASE_CARD_FACTORY`、`config/base-addresses.ts`（当前 Base 主网为 `0xE091a0A974a40bCee36288193376294a19a293aE`）
- **Gateway**：AA Factory 地址（与 `config/base-addresses.ts` `AA_FACTORY` 一致，当前为 `0xD86403DD1755F7add19540489Ea10cdE876Cc1CE`，仅在 MemberCard 内使用）

重发卡只改**卡实例地址**；UI 与 API 均从上述配置读取，跑完步骤 2 即生效。若工厂已切到新的共享 modules，后续新发卡会自动跟随工厂当前 module 能力。

## 5. 若 createCCSA 链上 revert

若执行 createCCSA 时出现 `missing revert data` / `execution reverted`：

1. **确认 Deployer 已绑定新工厂**（仅在新工厂重部署后做一次）：
   ```bash
   DEPLOYER_ADDRESS=0x<Deployer地址> USER_CARD_FACTORY_ADDRESS=0x<新Factory地址> npx hardhat run scripts/setDeployerFactory.ts --network base
   ```
2. 检查 `src/x402sdk/src/ABI/BeamioUserCardArtifact.json` 与链上 BeamioUserCard 版本一致（constructor 参数、bytecode）。
3. 发卡成功后，务必执行步骤 2 更新 CCSA 地址，UI 与 API 会自动使用新卡。

## 6. 重新部署 Factory 后必须核对 Oracle / QuoteHelper 链

**BeamioUserCardFactoryPaymasterV07**（Card Factory）和 **BeamioFactoryPaymasterV07**（AA Factory）在**重新部署后**，必须确保以下链正确，否则购卡会 revert（如 UC_PriceZero）：

| 合约 | 配置项 | 说明 |
|------|--------|------|
| **BeamioUserCardFactoryPaymasterV07** | `quoteHelper` | 构造时传入，或部署后由 **owner** 调用 `setQuoteHelper(BeamioQuoteHelperV07 地址)` |
| **BeamioQuoteHelperV07** | `oracle` | 构造时传入，或由 **owner** 调用 `setOracle(BeamioOracle 地址)` |
| **BeamioOracle** | `rates[currency]` | 由 **owner** 配置各币种汇率（如 CAD：`npm run set:oracle-cad:base`）。**禁止重新部署**，仅使用已有地址。 |

- **Card Factory** 的 `quoteHelper` 必须指向正确的 **BeamioQuoteHelperV07**（该 Helper 内部会调 Oracle）。若重新部署 Card Factory 时传错了 `quoteHelper_`，部署后需调用 `cardFactory.setQuoteHelper(正确 QuoteHelper 地址)`。
- **QuoteHelper** 的 `oracle` 必须指向正确的 **BeamioOracle**。若曾重新部署 QuoteHelper，需调用 `quoteHelper.setOracle(正确 Oracle 地址)`。
- **BeamioFactoryPaymasterV07**（AA Factory）也有 `quoteHelper`，用于其模块逻辑；若重新部署 AA Factory，同样需保证 constructor 或 `setQuoteHelper` 指向正确 QuoteHelper。

**检查命令**（从 `deployments/base-FullAccountAndUserCard.json` 读期望地址并核对链上）：

```bash
npx hardhat run scripts/checkOracleQuoteHelperChain.ts --network base
```

若脚本报「与期望不一致」，按提示对对应合约的 owner 调用 `setQuoteHelper` / `setOracle`；若报 Oracle 未配置 CAD，执行 `npm run set:oracle-cad:base`。

## 7. CCSA 购卡仍 revert UC_PriceZero 时

若两个 Factory 的 QuoteHelper/Oracle 链已正确、Oracle 已配置 CAD，但购卡仍报 `UC_PriceZero()`，可跑 CCSA 卡检查：

```bash
npx hardhat run scripts/checkCCSACardOnChain.ts --network base
```

脚本会检查：卡地址、`factoryGateway`、`currency`、`pointsUnitPriceInCurrencyE6`、Oracle 的 CAD/USDC 汇率、以及 `Factory.quoteUnitPointInUSDC6(卡)` 的返回值。

- **若「直接传 (CAD, 1e6) 也返回 0」**：链上 **BeamioQuoteHelperV07** 很可能与当前源码**参数顺序不一致**（链上为「先 price 后 currency」），Factory 传 `(currency=0, priceE6=1000000)` 被读成 `price=0` 导致返回 0。
- **修复**：用**当前源码**重新部署 **BeamioQuoteHelperV07**（构造函数：`oracle`、`owner`，不重部署 Oracle），然后在两个 Factory 上分别调用 **setQuoteHelper(新 QuoteHelper 地址)**（Card Factory 需 owner，AA Factory 需 admin）。部署与更新脚本可参考或使用 `scripts/deployQuoteHelperV07AndSetFactories.ts`（需由 Factory owner/admin 执行）。
