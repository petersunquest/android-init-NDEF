# Beamio B-Units ERC-20 智能合约实现架构 (CoNET L1)

**文档状态**: 技术架构草案 (Technical Draft)

**目标**: 在完全兼容 ERC-20 接口标准的前提下，实现「不可转账」、「双水池记账」与「节点分润计算」。

## 0. 权限模型 (Admin Group)

合约采用统一的 Admin Group 权限模型，替代传统的 owner / treasury / facilitator 分离角色：

- `mapping(address => bool) public admins`：管理员地址集合
- 部署时 `msg.sender` 自动成为首个 admin
- `addAdmin(address)` / `removeAdmin(address)`：由现有 admin 管理成员（不可移除自身）
- 铸币（mintReward / mintPaid / mintCombo）与核销（consumeFuel）均需 `onlyAdmin`

## 1. 核心数据结构改造：从「单余额」到「双极结构」

在标准的 ERC-20 合约（如 OpenZeppelin 的实现）中，用户的余额是一个简单的映射：

```solidity
mapping(address => uint256) private _balances;
```

为了实现「免费池」和「付费池」，我们必须重写底层数据结构，引入 Struct（结构体）：

```solidity
// 重构余额结构体
struct FuelBalance {
    uint128 freePool; // 免费池 (染色 A：无分润)
    uint128 paidPool; // 付费池 (染色 B：触发 5% 分润)
}

// 核心状态变量
mapping(address => FuelBalance) private _fuelBalances;
```

### 1.1 完美兼容前端与钱包 (重载 balanceOf)

为了让钱包前端（如 MetaMask 或 Beamio App）依然能直接读取总余额，我们重写原生的 balanceOf 函数：

```solidity
function balanceOf(address account) public view override returns (uint256) {
    // 前端读取时，将双水池合并为一个总数展示
    return _fuelBalances[account].freePool + _fuelBalances[account].paidPool;
}
```

技术价值：前端无需做任何特殊适配，依然把它当成普通的 ERC-20 币来显示余额（例如显示 852 Units），但合约底层清清楚楚地隔离着两笔账。

## 2. 铸币权限与资产染色 (Minting with DNA)

合约不再对外暴露普通的 mint，而是根据充值来源，由 Admin Group 中的任一管理员拆分为两个铸币函数：

- **mintReward(address to, uint256 amount)**
  - 逻辑：仅增加目标账户的 freePool
  - 场景：发红包奖励、新用户注册空投

- **mintPaid(address to, uint256 amount)**
  - 逻辑：仅增加目标账户的 paidPool
  - 场景：商户 USDC 大宗批发充值、用户 $5 兑换

> 注：像 CashTree 五折大宗采购的「买赠模式」，财库合约会在一笔交易内同时调用这两个函数，各铸币 50 万。

## 3. 阻断灰产：灵魂绑定与防转移 (Soulbound Override)

为了彻底切断羊毛党的刷号归集路径，我们必须「阉割」标准 ERC-20 的转账功能，使其变成一种介于 ERC-20 和 SBT (灵魂绑定代币) 之间的资产。

```solidity
// 重写转账函数，直接阻断 C 端用户之间的转账
function transfer(address to, uint256 amount) public override returns (bool) {
    revert("B-Units: Peer-to-peer transfers are locked for security.");
}

function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
    revert("B-Units: Delegated transfers are locked.");
}
```

## 4. 核心引擎：瀑布流核销与分润触发 (The Waterfall Burn)

这是整个合约最精妙的函数。当用户在 L2 发起交易，Admin Group 中的网关节点会调用这个函数来扣除用户的燃料。

### 4.1 逻辑工作流 (伪代码示例)

```solidity
// 仅允许 Admin Group 成员调用的专属扣费函数
function consumeFuel(address user, uint256 amount) external onlyAdmin {
    FuelBalance storage bal = _fuelBalances[user];
    require(bal.freePool + bal.paidPool >= amount, "Insufficient B-Units");

    uint256 paidBurned = 0; // 用于记录触发了多少分润

    // 瀑布流逻辑开始：优先抽干免费池
    if (bal.freePool >= amount) {
        // 情况 1: 免费池足够，全额从免费池扣除
        bal.freePool -= uint128(amount);
        // paidBurned = 0，不触发分润
    } else {
        // 情况 2: 免费池不够，抽干免费池，剩下的从付费池扣
        uint256 remaining = amount - bal.freePool;
        bal.freePool = 0; // 抽干
        bal.paidPool -= uint128(remaining); // 扣除付费池
        paidBurned = remaining; // 记录真实燃烧的付费燃料！
    }

    // 更新 ERC-20 总供应量
    _totalSupply -= amount;

    // 触发分润核心逻辑！
    if (paidBurned > 0) {
        // 抛出链上事件，跨链桥或预言机监听到此事件后，
        // 将通知 L2 的 Treasury 释放相应的 USDC 给节点分红池
        emit NodeYieldGenerated(user, paidBurned, paidBurned * 5 / 100);
    }

    // 记录常规的消费明细日志供前端读取
    emit FuelConsumed(user, amount);
}
```

## 5. 跨链结算架构 (L1 -> L2 Settlement)

既然 B-Units 合约部署在 CoNET L1 上，而真金白银的 USDC 存放在 Base L2 的金库（Treasury）中，协议分润的闭环需要跨链通信：

| 步骤 | 描述 |
|------|------|
| **L1 燃烧** | CoNET L1 上 Admin 调用 consumeFuel 成功执行，并抛出 NodeYieldGenerated(paidBurned: 500, yield: 25) 事件 |
| **预言机监听** | Beamio 的去中心化预言机/跨链桥（Relayer）监听到 CoNET 上的该事件 |
| **L2 释放法币** | Relayer 向 Base L2 的 Treasury 合约发送指令 |
| **法币记账** | Base L2 Treasury 收到指令，内部记账：NodeDividendPool += 0.25 USDC（因为 25 Units = $0.25） |
| **节点提现** | 全球的创世节点随时可以通过调用 Base L2 Treasury 的 claimYield()，提取属于自己的 USDC 现金流 |
