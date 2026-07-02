# ConetTreasury 去中心化验证者（Relayer / Miner）编程说明

> **UI / API 产品协议（跨链模式、汇率、事件字段、USDC 流动性）**：[`src/b-unit/conet-treasury-cross-chain-usage.md`](../src/b-unit/conet-treasury-cross-chain-usage.md)  
> 本文档侧重 **Relayer daemon** 实现与运维。

本文档描述 **各链监听 BridgeOut 事件 → 目标链 miner 投票 mint** 的完整链下流程，供实现 relayer daemon 使用。

## 架构概览

```
源链 (chainId = S)                         目标链 (chainId = D)
─────────────────                         ─────────────────
用户 burn                                   miner 2/3 投票
  │                                           │
  ▼                                           ▼
ConetTreasuryPeer                           ConetTreasuryPeer
  burn*ForBridge(...)                         voteMintFromPeerDeposit(
  emit *BridgeOut(...)                          burnTxHash,   ← 源链 burn tx hash
                                                S,            ← sourceChainId（源链，不是目标链）
                                                peerToken,
                                                recipient,
                                                amount)
                                                │
                                                ▼
                                              达 requiredVotes() 后自动执行:
                                              - wCNET/USDC: mintFactoryToken → wrapped 或 canonical usdcErc20
                                              - B-Units: buint.mintPaid（canonical 或 legacy B001）
                                              - GB: gbTokenErc20.mintPaid（canonical paidPool）或 conetGB1155.issueGB（legacy B002）
```

| 合约 | 角色 |
|------|------|
| **ConetTreasury** | miner 治理、FactoryERC20 minter、airdrop/GB 链上投票（非跨链 burn） |
| **ConetTreasuryPeer** | 跨链 burn、peer 注册、**voteMintFromPeerDeposit** |
| **FactoryERC20** | wCNET / wrapped USDC 等同 CREATE2 包装代币 |

**CREATE2 同址（Nick factory `0x4e59…4956C`）**

| 合约 | CoNET / Base 预测地址 |
|------|----------------------|
| ConetTreasury | `0xc6e615431BC0c0c65E09e04877a08AC927A30242` |
| ConetTreasuryPeer (v2) | `0x79e76ECC54eb5E78d4927F6B0193C54134E9FB43` |
| ConetTreasuryPeerWrappedLib | `0xCED9De89917eB957aF6371a3c9b45af21d68A0Ed` |
| ConetTreasuryPeer (v1 legacy) | `0xCF26c1686aC5E01e37B72017E575511C42cad29f` |
| wCNET | `0x429FBf063d6deAbA08a8Ca2566c9b6797ea9Eb39` |
| BeamioBUnits | `0xf5484F11b7De647E17aea1089e3CbD6BF15dfC0f` |
| ConetGB1155 | `0xcA423EEBC09d09834dC9CA28861798B3321893ab` |

常量见 `scripts/conetTreasuryDeployConstants.ts`、`scripts/predictCrossChainAssets.ts`。

---

## Peer Token 键（voteMintFromPeerDeposit 第 3 参）

### ERC20 canonical 原生 trio（推荐，CREATE2 同址）

| 资产 | 各链 token 地址（`peerToken` = 此地址） | 精度 | 用户出桥 |
|------|----------------------------------------|------|----------|
| **GB** | `0xC3EF02DaE632b4C10abB66e07d92a387c10838D8` | 9 | `bridgeNativeAsset(1, …)` 或 `burnGBForBridge` |
| **B-Unit** | `0x54ac4672cE75EC5ACebaeF1a7aFC6F49E77Ae9Ae` | 6 | `bridgeNativeAsset(2, …)` 或 `burnBUintForBridge` |
| **wCNET** | CREATE2 同址（见 `WRAPPED_CONET_CREATE2_PREDICTED` / `wrappedConet()`） | 18 | `bridgeNativeAsset(3, …)` 或 `burnWrappedConetForBridge` |

**无痛跨链 UX**：用户只需选 `destinationChainId` + `recipient`，调用：

```solidity
peer.bridgeNativeAsset(NATIVE_ASSET_GB, amount, destChainId, recipient);
// NATIVE_ASSET_GB=1, NATIVE_ASSET_BUINT=2, NATIVE_ASSET_WCNET=3
```

源链 burn → relayer 监听 `NativeAssetBridgeOut`（及 legacy `*BridgeOut`）→ 目标链 `voteMintFromPeerDeposit(burnTxHash, sourceChainId, peerToken, recipient, amount)`，`peerToken` 为**上表同址 token**。

登记：`registerPeerNativeBridgeAssets` + `registerPeerStableSwapAssets`（脚本 `registerPeerBridgeAssets.ts`）。

### 稳定币 ↔ GB / B-Unit 跨链兑换（`bridgeStableSwap`）

用户 **一条调用** 完成：源链 burn 输入资产 → 目标链按汇率 mint 输出资产（任意链、任意方向）。

| kind | 常量 | 精度 |
|------|------|------|
| GB | `CANONICAL_GB_ERC20 = 1` | 9 |
| USDC | `CANONICAL_USDC_ERC20 = 2` | 6 |
| B-Unit | `CANONICAL_BUINT_ERC20 = 3` | 6 |

**汇率（链上）**

| 对 | 规则 |
|----|------|
| USDC ↔ B-Unit | 固定 `1 USDC = 100 B-Unit`（与 Treasury `USDC_TO_BUNIT_RATE` 一致） |
| USDC ↔ GB | `usdc6PerFullGb`：每 **1 整 GB**（1e9 最小单位）的 USDC6 标价；miner `setUsdc6PerFullGb` |
| GB ↔ B-Unit | 经 USDC  hub 换算 |

**用户调用**

```solidity
// 例：Base 烧 10 USDC → CoNET 收 GB
uint256 credit = peer.quoteStableSwap(2, 10_000_000, 1); // 2=USDC, 1=GB
peer.bridgeStableSwap(2, 10_000_000, 224422, recipient, 1);

// 例：同资产跨链（等价 bridgeStableSwap(2, amt, dest, recv, 2)）
peer.bridgeStableSwap(2, amount, destChainId, recipient, 2);
```

**源链事件**

```solidity
event StableSwapBridgeOut(
    address indexed user,
    uint8 indexed burnAssetKind,
    uint256 burnAmount,
    uint8 indexed creditAssetKind,
    uint256 creditAmount,
    uint256 destinationChainId,
    address recipient
);
```

**Relayer 目标链投票**（兑换路径用 **credit** 字段，勿用 1:1 同资产投票）：

```solidity
peer.voteMintFromPeerCredit(
    burnTxHash,           // 源链 bridgeStableSwap tx hash
    sourceChainId,        // 源链 chainId
    sourcePeerToken,      // 源链被 burn 的 token 地址（见下表）
    recipient,
    creditAmount,         // 事件 creditAmount
    creditAssetKind       // 事件 creditAssetKind（1/2/3）
);
```

| 源链 burn kind | `sourcePeerToken`（CoNET / Base 同址或各链 USDC） |
|----------------|--------------------------------------------------|
| GB (1) | `0xC3EF02DaE632b4C10abB66e07d92a387c10838D8` |
| USDC (2) | CoNET: `0x2975…aDBdC`；Base: `0x833589…2913` |
| B-Unit (3) | `0x54ac4672cE75EC5ACebaeF1a7aFC6F49E77Ae9Ae` |

同资产跨链仍可用 `voteMintFromPeerDeposit`（`creditAssetKind=0` 默认）。

### CoNET 跨出 USDC 流动性（`usdcOutboundBalance`）

**仅 CoNET 链 Peer** 维护 `usdcOutboundBalance[destinationChainId]`（USDC6）：表示该目标链上仍可为用户兑现的跨出 USDC 额度。miner 须与对端链 Treasury / Circle USDC 储备定期对账：

```solidity
peer.setUsdcOutboundBalance(8453, availableUsdc6);       // 全量覆盖
peer.replenishUsdcOutboundBalance(8453, addedUsdc6);       // 增量补充
```

**出桥前检查（CoNET 源链，burn 之前 revert）**

| 入口 | 条件 |
|------|------|
| `burnUsdcForBridge` | `amount <= availableOutboundUsdc(dest)` |
| `bridgeStableSwap(..., creditKind=USDC)` | `creditAmount <= availableOutboundUsdc(dest)`（**含 GB/B-Unit burn → 对端 USDC**） |

`availableOutboundUsdc(dest) = min(usdcOutboundBalance[dest], Treasury.conet-USDC.balanceOf)`。

失败：`InsufficientOutboundUsdc()`，**不 burn、不 emit**。

**CoNET 出桥 GB / B-Unit → 对端 USDC**（须 `bridgeStableSwap`，勿用 `bridgeNativeAsset` + 目标链 `voteMintFromPeerCredit(USDC)`，后者会绕过额度守卫）：

```solidity
// CoNET 烧 GB → Base 收 USDC（creditAmount 由汇率算出，burn 前扣 usdcOutboundBalance[8453]）
uint256 credit = peer.quoteStableSwap(1, gbAmount9, 2);
peer.bridgeStableSwap(1, gbAmount9, 8453, recipient, 2);

// CoNET 烧 B-Unit → Base 收 USDC
peer.bridgeStableSwap(3, bunitAmount6, 8453, recipient, 2);
```

UI 可读：`previewStableSwapOutbound(burnKind, burnAmount, destChainId, creditKind)` → `(creditAmount, availableUsdc6, sufficient)`。

**入站回补**：对端链 USDC 跨入 CoNET 并成功 `voteMint*` mint USDC 时，自动 `usdcOutboundBalance[peerChainId] += amount`（`peerChainId` 为对端链，与出桥扣减同一 key）。

### Legacy phantom（v1 / `USE_ERC20_CANONICAL=0`）

| 资产 | `peerToken` | `peerChainId`（第 2 参） | `amount` 精度 |
|------|-------------|--------------------------|---------------|
| **wCNET** | `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` (NATIVE) | **224422**（CoNET 固定） | 18 decimals |
| **B-Units** | `0x000000000000000000000000000000000000B001` | **源链 burn 所在 chainId** | 6 decimals |
| **GB 1155** | `0x000000000000000000000000000000000000B002` | **源链 burn 所在 chainId** | 18 decimals (amountGB18) |

目标链须已登记对应 `(peerChainId, peerToken)`（ERC20 canonical 或 legacy）。

### 出桥（CoNET 源链）

| 资产 | 函数 | 事件 |
|------|------|------|
| GB ERC20 | `burnGBForBridge`（`gbTokenErc20` 已设时 `burnPaidFrom`，仅 paidPool） | `GBBridgeOut` |
| USDC | `burnUsdcForBridge` | `UsdcBridgeOut` |
| B-Unit | `burnBUintForBridge` | `BUintBridgeOut` |

---

## 源链：须监听的事件

**合约地址**：本链 **ConetTreasuryPeer**（CREATE2 同址）。

### 1. Wrapped CoNET（wCNET）

```solidity
event WrappedConetBridgeOut(
    address indexed user,
    uint256 amount,
    uint256 destinationChainId,
    address indexed recipient
);
```

- **触发**：`burnWrappedConetForBridge(amount, destinationChainId, recipient)`
- **CoNET 特有**：用户也可先 `depositNative()` 再 burn；relayer 只关心 burn tx 的 `WrappedConetBridgeOut`
- **投票参数**：
  - `depositTxHash` = 该 burn 交易 hash
  - `peerChainId` = **224422**
  - `peerToken` = NATIVE_PEER_TOKEN
  - `recipient` = 事件 `recipient`
  - `amount` = 事件 `amount`

### 2. B-Units

```solidity
event BUintBridgeOut(
    address indexed user,
    uint256 amount,
    uint256 destinationChainId,
    address indexed recipient
);
```

- **触发**：`burnBUintForBridge` / `bridgeStableSwap` burn B-Unit（内部 **`consumePaidFuel`**，仅 paidPool；免费池不可跨链）
- **投票参数**：
  - `peerChainId` = **源链 chainId**（burn 所在链）
  - `peerToken` = BUINT_PEER_TOKEN (`…B001`)
  - `amount` = 6 decimals

### 3. GB

```solidity
event GBBridgeOut(
    address indexed user,
    uint256 amountGB18,
    uint256 destinationChainId,
    address indexed recipient
);
```

- **触发**：`burnGBForBridge(amount, destinationChainId, recipient)`
  - **ERC20 canonical**：Peer 为 GBToken admin，调用 `burnPaidFrom(user, amount)`（**仅 paidPool**；无需用户 approve）；`amount` = **9 decimals**
  - **Legacy**：`conetGB1155.revokeTotalOnly`；`amount` = 18 decimals
- **投票参数**：
  - `peerChainId` = **源链 chainId**
  - `peerToken` = **GBToken 地址**（canonical）或 `GB_PEER_TOKEN` (`…B002`)（legacy）

### 4. USDC（CoNET canonical）

```solidity
event UsdcBridgeOut(
    address indexed user,
    uint256 amount,
    uint256 destinationChainId,
    address indexed recipient
);
```

- **触发**：`burnUsdcForBridge(amount, destinationChainId, recipient)`（Treasury `burnFactoryFrom(usdcErc20, …)`）
- **投票参数**：`peerToken` = 对端 USDC（Base `0x833589…` 或 CoNET `0x2975…`），`amount` = 6 decimals

### 5. Wrapped ERC20（非 canonical 登记）

- **Burn 路径**：用户 burn 目标链上由 `registerPeerToken(8453, USDC, …)` 创建的 wrapped token（经 Treasury `burnFactoryFrom`）
- **Relayer 键**：`peerChainId=8453`, `peerToken=0x833589…2913`
- 若仅有 `Transfer(to=0)` + 无专用事件，以 **burn 交易 hash** + 链上 log 解析 `amount`/`recipient`（须与首票 miner 提交参数一致）

---

## 目标链：投票与执行

### 入口函数（miner EOA）

```solidity
function voteMintFromPeerDeposit(
    bytes32 depositTxHash,
    uint256 peerChainId,
    address peerToken,
    address recipient,
    uint256 amount
) external;
```

```solidity
function executePeerDepositMint(bytes32 depositTxHash) external;
```

### 治理规则

- **谁可投票**：`ConetTreasury.isMiner(miner) == true`（Peer 通过 `treasury.isMiner` 委托）
- **阈值**：`requiredVotes() = ceil(minerCount * 2 / 3)`（与 Treasury 其它提案相同）
- **首票**创建提案并锁定 `(peerChainId, peerToken, recipient, amount)`；后续票必须 **完全一致**，否则 `ProposalMismatch`
- **同一 miner 同一 depositTxHash 只能投一次**
- 达阈值后 **同一交易内** 自动 `_executePeerDepositMint`

### 执行结果（链上）

| peerToken | 动作 |
|-----------|------|
| BUINT_PEER_TOKEN | `IBeamioBUnits(buint).mintPaid(recipient, amount)` |
| GB_PEER_TOKEN | `IConetGB1155(conetGB).issueGB(recipient, amount)` |
| 其它（含 NATIVE / USDC） | `_ensureWrappedToken` + `Treasury.mintFactoryToken(wrapped, recipient, amount)` |

### 目标链事件（确认完成）

```solidity
event PeerDepositProposalCreated(bytes32 indexed depositTxHash, ...);
event PeerDepositVoted(bytes32 indexed depositTxHash, address indexed miner, uint256 voteCount);
event PeerDepositExecuted(bytes32 indexed depositTxHash, address indexed mintTarget, address recipient, uint256 amount);
```

查询：`getPeerDepositProposal(depositTxHash) → (peerChainId, peerToken, recipient, amount, voteCount, executed)`

---

## Relayer 实现检查清单

### 索引（源链）

1. 订阅 **ConetTreasuryPeer** 的 `WrappedConetBridgeOut` / `BUintBridgeOut` / `GBBridgeOut`
2. 记录：`burnTxHash`、`sourceChainId`、`destinationChainId`、`recipient`、`amount`、`peerToken`
3. 可选：等待源链 **N 个确认** 再发起目标链投票（产品策略，链上无硬性要求）
4. **不可信失败 ≠ 无 burn**：RPC 失败时保留队列，勿删已见 burn（见 `beamio-trusted-vs-untrusted-fetch.mdc`）

### 中继（目标链）

1. 对每个 `(burnTxHash, destinationChainId)` 仅 **一条** canonical 提案参数
2. 各 miner 独立调用 `voteMintFromPeerDeposit`（或协调谁投首票）
3. 投票前检查：
   - `isPeerTokenRegistered(peerChainId, peerToken)` 在目标链为 true
   - `getPeerDepositProposal(burnTxHash).executed == false`
   - `hasVotedPeerDeposit(burnTxHash, myMiner) == false`
4. 若已有部分投票但未执行，可只补投；或任何人调用 `executePeerDepositMint`（当 `voteCount >= requiredVotes()`）

### 权限前置（部署 / 运维，非 relayer 日常）

| 链 | 操作 |
|----|------|
| 各链 | `deployConetTreasuryStackCreate2` → `setPeerModule` |
| 各链 | `configureConetTreasuryPeerBridge`：`Peer.setBUint/setConetGB`，`BUint.addAdmin(Peer)`，`GB.grantRole(ISSUER_ROLE, Peer)` |
| 各链 miner | `registerPeerBridgeAssets` / `registerWrappedConetNative` |

---

## TypeScript 伪代码

```typescript
import { Contract, JsonRpcProvider, id as keccakId } from "ethers";

const PEER_ABI = [
  "event WrappedConetBridgeOut(address indexed user, uint256 amount, uint256 destinationChainId, address indexed recipient)",
  "event BUintBridgeOut(address indexed user, uint256 amount, uint256 destinationChainId, address indexed recipient)",
  "event GBBridgeOut(address indexed user, uint256 amountGB18, uint256 destinationChainId, address indexed recipient)",
  "function voteMintFromPeerDeposit(bytes32,uint256,address,address,uint256) external",
  "function getPeerDepositProposal(bytes32) view returns (uint256,address,address,uint256,uint256,bool)",
  "function hasVotedPeerDeposit(bytes32,address) view returns (bool)",
  "function isPeerTokenRegistered(uint256,address) view returns (bool)",
];

const NATIVE = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";
const BUINT_PEER = "0x000000000000000000000000000000000000B001";
const GB_PEER = "0x000000000000000000000000000000000000B002";
const CONET_CHAIN_ID = 224422n;
const PEER_ADDRESS = "0xCF26c1686aC5E01e37B72017E575511C42cad29f"; // 各链同址

type BridgeJob = {
  burnTxHash: string;
  sourceChainId: bigint;
  destChainId: bigint;
  peerToken: string;
  recipient: string;
  amount: bigint;
};

async function indexSourceChain(rpcUrl: string, sourceChainId: bigint, fromBlock: number) {
  const provider = new JsonRpcProvider(rpcUrl);
  const peer = new Contract(PEER_ADDRESS, PEER_ABI, provider);

  peer.on(
    peer.filters.WrappedConetBridgeOut(),
    (user, amount, destinationChainId, recipient, ev) => {
      enqueue({
        burnTxHash: ev.log.transactionHash,
        sourceChainId: CONET_CHAIN_ID, // wCNET 键固定 CoNET
        destChainId: destinationChainId,
        peerToken: NATIVE,
        recipient,
        amount,
      });
    }
  );

  peer.on(
    peer.filters.BUintBridgeOut(),
    (user, amount, destinationChainId, recipient, ev) => {
      enqueue({
        burnTxHash: ev.log.transactionHash,
        sourceChainId,
        destChainId: destinationChainId,
        peerToken: BUINT_PEER,
        recipient,
        amount,
      });
    }
  );

  // GBBridgeOut 同理，peerToken = GB_PEER
}

async function voteOnDestination(
  destRpcUrl: string,
  minerWallet: Wallet,
  job: BridgeJob
) {
  const provider = new JsonRpcProvider(destRpcUrl);
  const peer = new Contract(PEER_ADDRESS, PEER_ABI, minerWallet.connect(provider));

  const [, , , , , executed] = await peer.getPeerDepositProposal(job.burnTxHash);
  if (executed) return;

  const voted = await peer.hasVotedPeerDeposit(job.burnTxHash, minerWallet.address);
  if (voted) return;

  const ok = await peer.isPeerTokenRegistered(job.sourceChainId, job.peerToken);
  if (!ok) throw new Error("peer not registered on destination");

  await peer.voteMintFromPeerDeposit(
    job.burnTxHash,
    job.sourceChainId,
    job.peerToken,
    job.recipient,
    job.amount
  );
}
```

---

## 典型跨链流向

| 方向 | 源链用户操作 | 源链事件 | 目标链 mint |
|------|-------------|---------|-------------|
| CoNET → Base | `burnWrappedConetForBridge` | `WrappedConetBridgeOut` | Base Peer：`peerChainId=224422`, NATIVE → mint Base wCNET |
| Base → CoNET | 同上（Base 上 wCNET burn） | 同上 | CoNET Peer：mint CoNET wCNET |
| CoNET → Base | `burnBUintForBridge` | `BUintBridgeOut` | Base：`peerChainId=224422`, BUINT_PEER → `mintPaid` |
| Base → CoNET | `burnBUintForBridge` | `BUintBridgeOut` | CoNET：`peerChainId=8453`, BUINT_PEER → `mintPaid` |

---

## 相关脚本

| 脚本 | 用途 |
|------|------|
| `predictCrossChainAssets.ts` | 预测 CREATE2 同址 |
| `deployConetTreasuryStackCreate2.ts` | Treasury + Peer + link |
| `configureConetTreasuryPeerBridge.ts` | BUint/GB 角色授权 |
| `registerPeerBridgeAssets.ts` | 登记 BUint/GB peer 键 |
| `registerWrappedConetNative.ts` | 部署/登记 wCNET |
| `verifyConetTreasuryStackOnScan.ts` | [scan.conet.network](https://scan.conet.network/) 验证 |

---

## 严禁

- ❌ 在 **Treasury** 上监听/调用已迁移的 `burn*ForBridge` / `voteMintFromPeerDeposit`（已移至 **Peer**）
- ❌ `voteMintFromPeerDeposit` 的 `peerChainId` 填 **目标链**（必须为 **源链 burn 所在 chainId**）
- ❌ 不同 miner 对同一 `depositTxHash` 提交不同的 `recipient` / `amount`
- ❌ 未登记 peer 键就投票（`PeerTokenNotRegistered`）
