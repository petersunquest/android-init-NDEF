# 同步 BeamioUserCard 合约到 x402sdk（独立项目）

x402sdk 是独立项目，创建卡等逻辑依赖 BeamioUserCard 的 ABI 与 bytecode。这些文件需从 **BeamioContract** 仓库本地编译后**同步进 x402sdk**，再在 x402sdk 里提交推送，服务器才能通过 `git pull x402sdk` 拿到新合约。

## 让服务器拉取到新 BeamioUserCard 的完整流程

**重要**：只改 BeamioContract 并 push，不会更新 x402sdk；x402sdk 里必须**先执行同步**，才会有文件变更可提交。

1. **在 BeamioContract 仓库**（你改合约的那个仓库）：
   ```bash
   cd /path/to/BeamioContract
   npm run compile
   X402SDK_ROOT=/path/to/x402sdk node scripts/syncBeamioUserCardToX402sdk.mjs
   ```
   把 `/path/to/x402sdk` 换成你本机 x402sdk 仓库的路径（例如 `~/x402sdk` 或 `/Users/peter/x402sdk`）。

2. **在 x402sdk 仓库**：
   ```bash
   cd /path/to/x402sdk
   git status   # 应看到 src/ABI/BeamioUserCard.json 等被修改
   git add src/ABI/BeamioUserCard.json src/ABI/BeamioUserCardArtifact.json src/ABI/BeamioUserCardFactoryPaymaster.json "scripts/API server/ABI/BeamioUserCardArtifact.json" "scripts/API server/ABI/BeamioUserCardFactoryPaymaster.json"
   git commit -m "chore: sync BeamioUserCard and factory ABI/artifact from BeamioContract"
   git push
   ```

3. **在服务器上**：
   ```bash
   cd /path/to/x402sdk && git pull
   ```

若在第 2 步出现 **「nothing to commit, working tree clean」**，说明第 1 步的同步没有执行或 `X402SDK_ROOT` 指错了目录，x402sdk 里的 JSON 没被覆盖。请回到 BeamioContract 执行第 1 步，确认 `X402SDK_ROOT` 指向当前这个 x402sdk 仓库根目录。

## 依赖关系说明

- **x402sdk 不依赖 BeamioContract 根目录**：运行时和部署时都不需要拉取或挂载 BeamioContract。合约的 ABI 与编译产物（bytecode）以 **已提交的 JSON 文件** 形式存在于 x402sdk 仓库内（如 `src/ABI/BeamioUserCard.json`、`src/ABI/BeamioUserCardArtifact.json` 等）。
- **服务器获取合约更新的方式**：在服务器上只需 **`git pull` x402sdk 项目**，即可获得当前依赖的合约 ABI 和 bytecode，无需克隆或引用 BeamioContract。
- **“自动更新”流程**：在 BeamioContract 中更新并编译合约后，由开发或 CI 执行同步脚本，将新生成的 JSON 写入 x402sdk 并 **commit/push 到 x402sdk 仓库**；之后服务器 pull x402sdk 即得到最新依赖。

## 同步内容

| 源（BeamioContract） | 目标（x402sdk 项目内） |
|----------------------|------------------------|
| `artifacts/.../BeamioUserCard.json` | `src/ABI/BeamioUserCardArtifact.json`（完整 artifact） |
| 同上（仅 abi 部分） | `src/ABI/BeamioUserCard.json`（仅 ABI） |
| `artifacts/.../BeamioUserCardFactoryPaymasterV07.json` | `src/ABI/BeamioUserCardFactoryPaymaster.json`（完整 factory artifact） |
| 同上（完整 artifact） | `scripts/API server/ABI/BeamioUserCardArtifact.json` |
| 同上（完整 artifact） | `scripts/API server/ABI/BeamioUserCardFactoryPaymaster.json` |

## 操作步骤（在 BeamioContract 仓库）

1. 编译合约（在 BeamioContract 根目录）：
   ```bash
   npm run compile
   ```

2. 同步到 **本仓库内的 x402sdk**（`BeamioContract/src/x402sdk`）：
   ```bash
   npm run sync:card-artifact
   ```
   或一步完成编译+同步：
   ```bash
   npm run sync:card-artifact:full
   ```

3. 若 x402sdk 是**独立仓库**（例如 `~/x402sdk`），指定其根目录再同步，然后 **在 x402sdk 中提交并推送**，服务器 pull 即可拿到更新：
   ```bash
   # 在 BeamioContract 目录执行
   X402SDK_ROOT=/path/to/x402sdk node scripts/syncBeamioUserCardToX402sdk.mjs

   # 在 x402sdk 目录提交并推送
   cd /path/to/x402sdk
   git add src/ABI/BeamioUserCard.json src/ABI/BeamioUserCardArtifact.json src/ABI/BeamioUserCardFactoryPaymaster.json "scripts/API server/ABI/BeamioUserCardArtifact.json" "scripts/API server/ABI/BeamioUserCardFactoryPaymaster.json"
   git commit -m "chore: sync BeamioUserCard and factory ABI/artifact from BeamioContract"
   git push
   ```
   服务器上更新依赖：
   ```bash
   cd /path/to/x402sdk && git pull
   ```

## 说明

- `sync:card-artifact` 和 `sync:card-artifact:full` 是 **BeamioContract** 的 npm 脚本，需在 BeamioContract 目录下执行。
- x402sdk 自身不依赖 BeamioContract 路径；更新合约后把同步得到的 `BeamioUserCard` 与 `BeamioUserCardFactoryPaymasterV07` JSON 一并提交进 x402sdk 仓库，服务器只要 pull x402sdk 即可获得最新 ABI 和编译码。
