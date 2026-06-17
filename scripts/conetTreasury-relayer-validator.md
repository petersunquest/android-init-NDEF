# ConetTreasury 去中心化验证者（Relayer / Miner）编程说明

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
                                              - wCNET/USDC: mintFactoryToken → wrapped
                                              - B-Units: buint.mintPaid
                                              - GB: conetGB.issueGB
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
| ConetTreasuryPeer | `0xCF26c1686aC5E01e37B72017E575511C42cad29f` |
| wCNET | `0x429FBf063d6deAbA08a8Ca2566c9b6797ea9Eb39` |
| BeamioBUnits | `0xf5484F11b7De647E17aea1089e3CbD6BF15dfC0f` |
| ConetGB1155 | `0xcA423EEBC09d09834dC9CA28861798B3321893ab` |

常量见 `scripts/conetTreasuryDeployConstants.ts`、`scripts/predictCrossChainAssets.ts`。

---

## Peer Token 键（voteMintFromPeerDeposit 第 3 参）

| 资产 | `peerToken` | `peerChainId`（第 2 参） | `amount` 精度 |
|------|-------------|--------------------------|---------------|
| **wCNET** | `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` (NATIVE) | **224422**（CoNET 固定） | 18 decimals |
| **B-Units** | `0x000000000000000000000000000000000000B001` | **源链 burn 所在 chainId** | 6 decimals |
| **GB** | `0x000000000000000000000000000000000000B002` | **源链 burn 所在 chainId** | 18 decimals (amountGB18) |
| **Base USDC → CoNET wrapped** | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | **8453** | 6 decimals |

目标链须已 `registerPeerToken` / `registerPeerBridgeAssets` / `registerWrappedConetNative` 登记对应 `(peerChainId, peerToken)`。

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

- **触发**：`burnBUintForBridge(amount, destinationChainId, recipient)`（内部 `consumeFuel`）
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

- **触发**：`burnGBForBridge(amountGB18, destinationChainId, recipient)`（内部 `revokeTotalOnly`）
- **投票参数**：
  - `peerChainId` = **源链 chainId**
  - `peerToken` = GB_PEER_TOKEN (`…B002`)
  - `amount` = `amountGB18`

### 4. Wrapped ERC20（如 Base USDC → 对端 wrapped USDC）

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
