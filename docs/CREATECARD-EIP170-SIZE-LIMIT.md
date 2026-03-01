# BeamioUserCard 部署失败与 EIP-170 合约大小限制

## 两大嫌疑速查

| 嫌疑 | 表现/关键字 | 处理 |
|------|-------------|------|
| **1) 合约代码 size 超过 24,576 bytes** | `Contract code size ... exceeds 24576`、`initcode size exceeds`、EIP-3860、`max code size exceeded`、CREATE 返回 0 → BM_DeployFailed | 开 optimizer + viaIR；**本合约需 runs=1 才能压进 24k**（runs=200 会更大）；仍超则拆模块 |
| **2) 构造函数直接 revert** | `UC_GlobalMisconfigured`、`BM_ZeroAddress` | 检查部署参数：`initialOwner` 非 0；`gateway_` 为**已部署合约**（有 code），且实现 FactoryPaymaster/Oracle 等接口 |
| **3) EIP-3860 initcode 超限 / OOG** | initcode 超 49152 bytes 或 initcode 计费导致 out-of-gas；部分节点只报 DeployFailed | 看 creation bytecode 长度；把 gasLimit 拉高试一次，若高 gas 能过则为 OOG |

---

## EIP-3860：initcode 大小与计费（runtime 没超仍失败时优先查）

- **Shanghai 后**：initcode（creation bytecode，含 constructor + 初始化 + metadata）有上限，常见 **49152 bytes**。超限会部署失败（报错可能是 initcode size exceeded、max initcode size exceeded，或仅 DeployFailed）。
- **initcode 计费**：initcode 越长，CREATE 消耗 gas 越多；若 gas limit 不足会 **out-of-gas**，表现也可能是 DeployFailed。
- **立刻验证**：
  - 在诊断脚本或编译产物中看 **creation bytecode 长度**（即发给 Factory 的 initCode 的字节数 = hex 长度/2），是否 ≤ 49152。
  - 部署时把 **gasLimit 拉高**（如 6M）试一次：若高 gas 能成功，多半是 initcode OOG；若仍失败，再查 constructor revert / initcode 超限 / 库链接。

---

## 现象

- **增加 `upgradeByBalance` 之前**：部署 BeamioUserCard 正常。
- **增加 `struct Tier.upgradeByBalance` 及相关逻辑之后**：CREATE 失败，链上 revert `BM_DeployFailed`（0x6890d236）。

## 根本原因：EIP-170 合约大小限制

EVM 规定：**部署后的 runtime 字节码不得超过 24 KB（24576 字节）**（EIP-170）。超过时 `CREATE` 会失败并返回 0，Deployer 因此抛出 `BM_DeployFailed`。

当前编译结果（增加 `upgradeByBalance` 后）：

| 项目 | 大小 | 限制 |
|------|------|------|
| Creation bytecode | 25822 bytes | - |
| **Runtime / deployed bytecode** | **24799 bytes** | **24576 bytes (24 KB)** |
| 结论 | 超出 223 bytes | CREATE 失败 |

因此不是“逻辑错误”或“配置错误”，而是 **runtime 合约体积超限**，导致 CREATE 被 EVM 拒绝。

## 为何增加 upgradeByBalance 会超限？

增加 `upgradeByBalance` 后，合约中多了：

1. **struct Tier** 新字段及所有使用该 struct 的代码（编码/解码、存储布局）。
2. **appendTier(..., bool upgradeByBalance)** 的签名与实现。
3. **TierAppended** 事件多一个参数。
4. **setTiers**、**getTierAt** 等对 Tier 的读写。
5. **_tryUpgradeByNextTier** 等新逻辑（`nextTier.upgradeByBalance` 分支）。

这些都会增加 runtime 字节码。原来已接近 24 KB，增加后超过 24576 字节，触发 EIP-170，CREATE 失败。

## 解决方案（思路）

1. **把部分逻辑移到 library**  
   将 tier 相关逻辑（如 `_tierFromPointsBalance`、`_nextTierIndexAbove`、`_tryUpgradeByNextTier` 等）抽到 `BeamioERC1155Logic` 或新 library，在主合约中 `using ... for` 或 `delegatecall`。Library 的代码不计入主合约的 24 KB，可显著减小主合约体积。

2. **删减或合并功能**  
   若暂时不需要某些 tier 功能，可先移除或合并，使 runtime 回到 24 KB 以内再部署。

3. **用 Diamond/代理模式**  
   将 BeamioUserCard 拆成多个 facet，通过代理调用，每个 facet 单独部署，各自受 24 KB 限制但总体功能可保留。改动较大，适合长期架构调整。

4. **编译器优化**  
   将 Hardhat 的 `optimizer.runs` 从 50 降为 **1**，可显著减小部署体积（runtime 从 24799 降至 24466 字节，满足 24 KB）。代价是运行时 gas 可能略增；若需兼顾运行 gas，可尝试 runs=10 等折中值。

   **注意**：建议里常见的 `runs: 200` 是偏向**运行时代码效率**，会生成**更大**的 bytecode；BeamioUserCard 要满足 EIP-170 必须用 **runs: 1**（或较小值）。`viaIR: true` 已开启。

**建议优先**：把 tier 升级、tier 查询等逻辑迁到现有 `BeamioERC1155Logic` 库（或新库），主合约只保留存储和对外接口，使 runtime 降到 24 KB 以下后再部署。

## 验证命令

```bash
# 查看当前 runtime 大小
node -e "
const fs = require('fs');
const art = JSON.parse(fs.readFileSync('src/x402sdk/src/ABI/BeamioUserCardArtifact.json','utf8'));
const runtime = (art.deployedBytecode || '').length;
const bytes = (runtime - 2) / 2;
console.log('Runtime bytecode:', bytes, 'bytes, limit 24576, over:', bytes > 24576);
"
```

## 构造函数与 gateway 检查（嫌疑 2）

Constructor 中有硬校验：

- `initialOwner == address(0)` → revert `BM_ZeroAddress`
- `gateway_ == address(0) || gateway_.code.length == 0` → revert `UC_GlobalMisconfigured`

因此部署时：

- **initialOwner** 必须非 0（createCCSA 传的是 cardOwner，如 `0xe5f4...F27E`）。
- **gateway_** 必须是**已部署的合约地址**（有 code），且通常为 FactoryPaymaster，需实现 `IBeamioFactoryOracle`、`IBeamioUserCardFactoryPaymasterV07` 等（constructor 内未直接调这些，但后续逻辑会通过 `factoryGateway()` 调用）。部署时只要该地址有 code 即可通过 constructor；若后续调用时接口不匹配会在执行时 revert，不在部署瞬间报错。

## 10 分钟内定位（最短路径）

1. **拿到真实 revert data**  
   - 用 factory 部署时：让 factory 在失败时把 returndata 冒泡或 emit；或用 ethers/hardhat 抓 `error.data` / receipt / trace。
2. **同时看两个长度**  
   - **Runtime bytecode**：≤ 24576（EIP-170）。  
   - **Creation bytecode / initCode**：≤ 49152（EIP-3860），且若接近上限或 gas 吃紧，优先拉高 gasLimit 再试。
3. **部署时 gasLimit 拉高试一次**  
   - 若高 gas 直接成功 → 多为 initcode 计费/OOG。  
   - 若仍失败 → 多为 constructor revert、initcode 超限或库链接占位符未填。
4. **部署前脚本检查**  
   - `provider.getCode(gateway_)` 长度 > 2（有 code）。  
   - `initialOwner != 0`。  

诊断脚本已输出：Runtime / initCode 长度、EIP-170/49152 是否 OK、gateway 是否有 code、initialOwner 是否非零。
