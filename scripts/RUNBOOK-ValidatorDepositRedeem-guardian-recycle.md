# ValidatorDepositRedeem：Guardian 空洞回收升级 — 步骤清单

> **目标**：Lab 矿池 136 台 `recordNodeValidatorExit` 后，341–476 仍占 `guardianIdBeneficiary` 导致新 redeem 从 478 起跳；升级后 redeem-admin 可 **释放** 空洞 id，分配器 **优先填洞**。  
> **代理地址不变**（`0xc71e246DD78B37C2fABc905D340932F28F503433`），**无需迁移** redeem/claim 历史 storage。

---

## 一、链上现状（升级前核对）

| 项 | 值 |
|---|---|
| `ValidatorDepositRedeem` 代理 | `0xc71e246DD78B37C2fABc905D340932F28F503433` |
| `ConetLabMiningPool` | `0x32bE583C8e778FFfC5107BF34820c2B225336201` |
| `guardianAllocStartId` | 100 |
| `nextGuardianAllocId` | 478 |
| 341–476 | beneficiary = 矿池；`validatorActive` = 0（已 `recordNodeValidatorExit`） |
| 477 | beneficiary = `0x300775172ae56f301988C6eF583A8Ef5427A0DE2`；validator **仍 active** |

```bash
# solc 版本（impl 尾字节应为 0.8.35）
curl -s https://publicrpc.conet.network -H 'content-type:application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_getCode","params":["0xc71e246DD78B37C2fABc905D340932F28F503433","latest"]}' \
  | python3 -c "import sys,json;c=json.load(sys.stdin)['result'];print('tail',c[-24:])"
```

---

## 二、合约变更摘要（本仓已实现）

| 变更 | 说明 |
|---|---|
| `ValidatorDepositRedeemReleaseLib` | `releaseOneGuardianId`：清 beneficiary、DePIN IP、计数（validator 须已 inactive） |
| `adminReleaseGuardianIds(from, ids)` | redeem-admin 批量释放 |
| `adminTransferGuardianIds(from, to, ids)` | redeem-admin 代转（矿池合约无法 EIP-712） |
| `_resolveNextFreeGuardianNodeId()` | claim 分配 **先扫** `[startId, nextAlloc)` 空洞，再扩展 `nextGuardianAllocId` |
| storage | **无新槽**；沿用现有 mapping，`__gap` 不变 |

**严禁**：对 207/74 矿池 VA 做 voluntary-exit（除非产品改口）。

---

## 三、升级前（本地）

```bash
cd /path/to/BeamioContract
npm run clean && npm run compile
```

确认 `src/mainnet/ValidatorDepositRedeemReleaseLib.sol` 与主合约编译通过。

---

## 四、UUPS 升级（CoNET mainnet）

**签名者**：代理 `contractAdmin`（与历史升级相同）。

```bash
npx hardhat run scripts/upgradeValidatorDepositRedeemImplConet.ts --network conet
```

脚本会：

1. 部署 **7** 个链接库（含新 `ValidatorDepositRedeemReleaseLib`）
2. 部署新 implementation
3. `upgradeToAndCall`（代理地址 **不变**）
4. 写入 `deployments/conet-ValidatorDepositRedeem.json` / `conet-addresses.json`

升级后 **当场验证**（`conet-deploy-verify-on-the-spot.mdc`）：

```bash
npm run clean && npm run compile
node scripts/exportStandardJsonFromBuildInfo.mjs ValidatorDepositRedeem --full   # 若 CONFIG 已登记
CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyValidatorDepositRedeemStackConet.ts ValidatorDepositRedeem
```

逐库验证（含 `ValidatorDepositRedeemReleaseLib`）：

```bash
CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyValidatorDepositRedeemStackConet.ts
```

验收（Blockscout v2）：

```bash
curl -s "https://mainnet.conet.network/api/v2/smart-contracts/<NEW_IMPL_ADDR>" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('is_verified'),d.get('is_partially_verified'))"
```

---

## 五、升级后链上验收（只读）

```bash
# 新 selector 存在（adminReleaseGuardianIds）
cast sig "adminReleaseGuardianIds(address,uint256[])"
# 应对 impl bytecode 可调用

# 分配逻辑：释放 341 后下一笔 claim 应优先用 341（可用小规模测试 redeem）
```

---

## 六、运维：释放矿池 341–476 空洞

**前提**：136 台均已 `recordNodeValidatorExit`（`validatorActive=false`）。

```bash
# 干跑
DRY_RUN=1 node scripts/releaseMiningPoolGuardianDePIN207.mjs

# 执行（默认 342–476；341 留给 477 修复流程）
node scripts/releaseMiningPoolGuardianDePIN207.mjs
```

每批 `adminReleaseGuardianIds(矿池, ids)`；gas 大时分批（脚本内置 chunk）。

释放后核对：

- `guardianIdBeneficiary(342..476) == 0x0`
- 矿池 `validatorNodeCountOf` 应降为 **1**（若仅保留 341）或 **0**（若 341 已转出）

---

## 七、运维：477 → 真实用户占用 341（产品语义）

> **341 与 477 是不同 DePIN IP/validator**，不是改数字别名。目标是：用户应持有 **341 对应 IP**，释放误占的 **477**。

**推荐顺序**（升级 + 释放能力就绪后）：

| 步 | 动作 | 说明 |
|---|---|---|
| 1 | `adminTransferGuardianIds(矿池, 0x3007…, [341])` | 把 341（207 矿池 IP）转给真实 redeem 用户 |
| 2 | `adminReleaseGuardianIds(矿池, [342..476])` | 清空矿池空洞 |
| 3 | `recordNodeValidatorExit(477)` | 477 上 validator 须先 inactive |
| 4 | `adminReleaseGuardianIds(0x3007…, [477])` | 释放误分配 id |

```bash
DRY_RUN=1 node scripts/remediateGuardian477To341.mjs
node scripts/remediateGuardian477To341.mjs
```

**链下**：用户 DePIN 节点仍跑 477 IP 时，须运维协调改指向 341 IP（Guardian 登记 / 节点配置），链上只改 beneficiary 绑定。

---

## 八、回滚与风险

| 风险 | 缓解 |
|---|---|
| 释放时 validator 仍 active | 先 `recordNodeValidatorExit` |
| 误释放用户正常 id | 仅 redeem-admin；脚本白名单 id |
| impl bytecode > 24KB | 逻辑在 ReleaseLib；升级前本地 `hardhat compile` 已测 |
| 新 redeem 仍跳 478 | 确认 `adminRelease` 已把 beneficiary 清 0 |

**回滚**：UUPS 可再 `upgradeToAndCall` 回旧 impl（旧 impl **无** release API，空洞仍在）；已释放的 id **不可** 自动恢复 beneficiary，须从备份状态重放或人工 `adminTransfer`。

---

## 九、相关文件

| 文件 | 用途 |
|---|---|
| `src/mainnet/ValidatorDepositRedeemReleaseLib.sol` | 释放库 |
| `src/mainnet/ValidatorDepositRedeem.sol` | 主合约 + 填洞分配器 |
| `scripts/upgradeValidatorDepositRedeemImplConet.ts` | UUPS 升级 |
| `scripts/verifyValidatorDepositRedeemStackConet.ts` | Blockscout 验证 |
| `scripts/releaseMiningPoolGuardianDePIN207.mjs` | 批量释放 342–476 |
| `scripts/remediateGuardian477To341.mjs` | 477/341 修复编排 |
| `scripts/releaseMiningPool136RedeemBindings207.mjs` | 仅 `recordNodeValidatorExit`（已完成） |
| `deployments/conet-ConetLabMiningPool-136validators-207.json` | 136 台 guardian id 列表 |

---

## 十、检查清单（打勾再上线）

- [ ] `npm run clean && npm run compile` 通过
- [ ] 升级 tx 成功，代理地址未变
- [ ] impl + 7 库 Blockscout 验证通过
- [ ] `adminReleaseGuardianIds` / `adminTransferGuardianIds` selector 在链上 impl 可读
- [ ] 136 台 `validatorActive` 均为 0
- [ ] 释放 342–476 后 `guardianIdBeneficiary` 为 0
- [ ] 477 修复四步按序完成（若本期要做）
- [ ] **未**对 207 VA 做 voluntary-exit
