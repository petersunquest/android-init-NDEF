# createCCSA / 诊断脚本 使用的 Base RPC

**Beamio 标准**：项目内 Base RPC 统一使用 CoNET：`https://base-rpc.conet.network`（HTTP）、`wss://base-rpc.conet.network/ws`（WebSocket）。

## 两处 RPC 来源（可能不一致）

| 场景 | RPC 来源 | 默认值 |
|------|----------|--------|
| **createCCSA**（x402sdk） | `~/.master.json` 的 **base_endpoint** | 未配置时为 `https://base-rpc.conet.network` |
| **diagnoseCreateCardFailure**（Hardhat） | 环境变量 **BASE_RPC_URL**（如 `.env`） | 未设置时为 `https://base-rpc.conet.network` |

因此：**发卡**与**诊断**均默认使用同一 RPC（base-rpc.conet.network）。若在 ~/.master.json 或 .env 中另行指定，则以指定为准。

## 如何统一

- 默认已统一为 **https://base-rpc.conet.network**。若需改用其他 RPC：
  - 在 **~/.master.json** 中设置 **base_endpoint**，和/或在 **.env** 中设置 **BASE_RPC_URL** 为同一 URL。

## 运行时查看当前使用的 RPC

- **createCCSA**：运行时会打印 `Base RPC (x402sdk): <url>`。
- **diagnoseCreateCardFailure**：运行时会打印 `Base RPC (Hardhat): <url>`。

对比两处输出即可确认是否一致。
