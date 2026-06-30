# GBToken 去中心化投票跨链桥 — relayer / validator 运维守则

GBToken（9 位 ERC20 GB）在 CoNET(224422) 与 Base(8453) 等任意 L1 上 **同址**
`0xbeEbE03943b55e67373796ddc7314fC76f5b5911`（CREATE2，salt `beamio.gb.erc20.v1`）。

桥是 **对称** 的：任意链 `bridgeOut`（焚烧）→ relayer 监听 → 目标链 validators 投票 `voteBridgeMint`（铸造）。
没有单点 mint 权限；铸造须 **2/3 validators** 投同一 `(srcTxHash, srcChainId, recipient, amount)`。

## 一、角色

| 角色 | 谁 | 权限 |
|------|----|------|
| admin | `0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1`（初始） | 加/减 admin、加/减 validator、`mint`/`airdrop`、`setBridgePaused` |
| bridge validator | 由 admin `addValidator` 加入（建议 ≥3，奇数） | `voteBridgeMint` / `executeBridgeMint` |
| 持有人 | 任意地址 | `transfer` / `burn` / `bridgeOut` / EIP-2612 permit / EIP-3009 授权转账 |

> validators 是 **链上状态**（非 constructor 参数），各链可独立增减，不影响 CREATE2 同址。
> 阈值 `requiredVotes() = ceil(2/3 * validatorCount)`。

## 二、用户出桥（源链）

```
gb.bridgeOut(amount, destChainId, recipient)
```

- 焚烧 `msg.sender` 的 `amount`（最小单位，1 GB = 1e9）
- emit `BridgeOut(from, recipient, amount, srcChainId, destChainId, nonce)`
- `destChainId` 须 ≠ 当前链；桥未暂停

## 三、relayer 监听 → validators 投票（目标链）

1. relayer 订阅每条链的 `BridgeOut` 事件，过滤 `destChainId == 本链`。
2. 取该事件的 **交易哈希 `srcTxHash`**、`srcChainId`、`recipient`、`amount`。
3. 每个 validator（各自独立的私钥/进程）在目标链调用：

```
gb.voteBridgeMint(srcTxHash, srcChainId, recipient, amount)
```

4. 第一个投票创建提案；后续投票必须 **四元组完全一致**，否则 `ProposalMismatch`。
5. 票数达到 `requiredVotes()` 时 **自动** `_mint(recipient, amount)`；
   若达标但未触发，任何人可 `gb.executeBridgeMint(srcTxHash)` 兜底。

### 防重放 / 安全

- `srcTxHash` 跨链唯一 + `executed` 标志 → 同一笔源链 burn 只能铸造一次。
- validator 重复投票 → `AlreadyVoted`。
- 不同 validator 报告不一致金额/接收人 → `ProposalMismatch`（需人工核对源链事件）。
- 紧急情况 admin `setBridgePaused(true)` 冻结 `bridgeOut` 与 `voteBridgeMint`。

## 四、最小 relayer 伪代码（ethers v6）

```ts
const SRC = new ethers.Contract(GB, ABI, srcProvider)
const DST = new ethers.Contract(GB, ABI, dstWalletForValidator) // 同地址，不同链

SRC.on("BridgeOut", async (from, recipient, amount, srcChainId, destChainId, nonce, ev) => {
  if (destChainId !== DST_CHAIN_ID) return
  const srcTxHash = ev.log.transactionHash
  // 可选：等待 N 个确认 + 重新 eth_getTransactionReceipt 校验事件真实性
  const tx = await DST.voteBridgeMint(srcTxHash, srcChainId, recipient, amount)
  await tx.wait()
})
```

> 生产建议：每个 validator 独立部署，等待源链 finality 后再投票；relayer 仅“喂事件”，
> 真正的信任来自 **多 validator 独立校验源链 receipt** 后各自签名上链。

## 五、运维命令（configureGBToken.ts）

```bash
# 加 validators
GB_ACTION=add-validators GB_VALIDATORS=0xa..,0xb..,0xc.. \
  npx hardhat run scripts/configureGBToken.ts --network conet
GB_ACTION=add-validators GB_VALIDATORS=0xa..,0xb..,0xc.. \
  npx hardhat run scripts/configureGBToken.ts --network base

# 查询
GB_ACTION=status npx hardhat run scripts/configureGBToken.ts --network base

# admin 空投（gb-airdrop.json: [{"to":"0x..","gb":"12.5"}]）
GB_ACTION=airdrop GB_AIRDROP_JSON=./gb-airdrop.json \
  npx hardhat run scripts/configureGBToken.ts --network conet

# 暂停/恢复桥
GB_ACTION=pause GB_PAUSED=true  npx hardhat run scripts/configureGBToken.ts --network base
GB_ACTION=pause GB_PAUSED=false npx hardhat run scripts/configureGBToken.ts --network base
```

## 六、与现有 1155 / Treasury 桥的关系

- **ConetGB1155**（`0x3Dc53e…`）保持不变，继续作为 **CoNET DePIN miner 记账**（小时/天/周期发行索引）。
- GBToken 是 **独立可转账 ERC20**，自带桥，**不** 复用 ConetTreasuryPeer 的 `GB_PEER_TOKEN(0x..B002)` 轨道。
- 若要把 1155 记账额度兑成可转账 ERC20 GB，由 admin/issuer 在 CoNET 用 `mint`/`airdrop` 投放（业务侧自定义兑换比，注意两者精度：1155=18 位，ERC20=9 位）。
