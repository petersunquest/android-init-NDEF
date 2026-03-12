# 0x82ceE96dB45933fE4b71D36fa8904508f929027C BaseScan 验证指南

## Constructor 参数（已确认）

| 参数 | 值 |
|------|-----|
| URI | `https://beamio.app/api/metadata/0x` |
| currency | 0 (CAD) |
| price | 1000000 |
| owner | 0x513087820Af94A7f4d21bC5B68090f3080022E0e |
| gateway | 0x46E8a69f7296deF53e33844bb00D92309ab46233 |

## 当前状态

`npx hardhat verify` 返回 **bytecode 不匹配**（链上合约与当前编译产物不一致）。可能原因：链上为旧版本或不同编译设置。

## 手动验证步骤（Standard JSON）

1. 打开 https://basescan.org/address/0x82ceE96dB45933fE4b71D36fa8904508f929027C#code
2. 点击 "Verify and Publish"
3. 选择 **"Solidity (Standard-Json-Input)"**
4. 上传 `deployments/base-BeamioUserCard-basescan-standard-input.json`
5. Compiler: 0.8.33+commit.64118f21，Optimization: enabled, runs: 1，evmVersion: cancun
6. Contract: `project/src/BeamioUserCard/BeamioUserCard.sol:BeamioUserCard`
7. Constructor Arguments: 使用 ABI-encoded 格式

### Constructor 编码

```bash
node -e "
const { AbiCoder } = require('ethers');
const encoded = AbiCoder.defaultAbiCoder().encode(
  ['string','uint8','uint256','address','address'],
  ['https://beamio.app/api/metadata/0x', 0, '1000000', '0x513087820Af94A7f4d21bC5B68090f3080022E0e', '0x46E8a69f7296deF53e33844bb00D92309ab46233']
);
console.log(encoded.slice(2));
"
```

将输出的 hex 粘贴到 BaseScan 的 "Constructor Arguments (ABI-encoded)" 框。

## 若仍失败

链上 bytecode 可能与当前源码不匹配，需用**部署时的源码**重新编译并验证，或接受该合约无法验证。
