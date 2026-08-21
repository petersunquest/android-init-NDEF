import { defineConfig } from "hardhat/config"
import hardhatToolboxMochaEthers from "@nomicfoundation/hardhat-toolbox-mocha-ethers"
import * as dotenv from "dotenv"
import * as fs from "fs"
import * as path from "path"
import { homedir } from "os"

dotenv.config()

function getConetAccounts(): string[] {
  const setupPath = path.join(homedir(), ".master.json")
  if (!fs.existsSync(setupPath)) return []
  try {
    const master = JSON.parse(fs.readFileSync(setupPath, "utf-8"))
    const key = master?.settle_contractAdmin?.[0]
    return key ? [key.startsWith("0x") ? key : "0x" + key] : []
  } catch {
    return []
  }
}

export default defineConfig({
  plugins: [hardhatToolboxMochaEthers],
  paths: {
    // 合约目录，排除 x402sdk（含 .tmp-op-reth-rc3 等 forge-std 依赖）
    // 注意：BeamioAccount.sol 使用相对路径 ../contracts/ 引用 contracts 目录
    sources: [
      "src/BeamioUserCard",
      "src/BeamioAccount",
      "src/contracts",
      "src/CoNETIndexTaskdiamond",
      "src/b-unit",
      "src/mainnet",
      "src/dle",
    ],
  },
  solidity: {
    // New deployments compile with the repository-wide canonical compiler.
    // Historical verification scripts keep their deployment-time compiler.
    version: "0.8.35",
    settings: {
      metadata: {
        bytecodeHash: "none",
      },
      debug: {
        revertStrings: "strip",
      },
      optimizer: {
        enabled: true,
        runs: 0  // 偏向部署体积，便于 BeamioUserCard 满足 EIP-170 24KB
      },
      viaIR: true  // 解决 "Stack too deep" 错误
      , evmVersion: "cancun"  // 必须：Bytes.sol 使用 mcopy (Cancun)
    }
  },
  networks: {
    // Local Hardhat node for mock-L1 auction E2E (never CoNET 224422).
    localhost: {
      type: "http",
      chainType: "l1",
      url: process.env.MOCK_L1_RPC_URL || "http://127.0.0.1:8545",
      // Hardhat/Anvil well-known local keys (authority/seller/buyer for auction fixture).
      // mnemonic: test test test test test test test test test test test junk (local only)
      accounts: [
        "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
        "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
        "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
        "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
        "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
        "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
        "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e",
        "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356",
        "0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97",
        "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6",
        "0xf214f2b2cd398c806f84e317254e0f0b801d0643303237d97a22a48e01628897",
        "0x701b615bbdfb9de65240bc28bd21bbc0d996645a3dd57e7b12bc2bdf6f192c82",
        "0xa267530f49f8280200edf313ee7af6b827f2a8bce2897751d06a843f644967b1",
        "0x47c99abed3324a2707c28affff1267e45918ec8c3f20b8aa892e8b065d2942dd",
        "0xc526ee95bf44d8fc405a158bb884d9d1238d99f0612e9f33d006bb0789009aaa",
        "0x8166f546bab6da521a8369cab06c5d2b9e46670292d85c875ee9ec20e84ffb61",
        "0xea6c44ac03bff858b476bba40716402b03e41b8e97e276d1baec7c37d42484a0",
        "0x689af8efa8c651a91ad287602527f3af2fe9f6501a7ac4b061667b5a93e037fd",
        "0xde9be858da4a475276426320d5e9262ecfc3ba460bfac56360bfa6c4c28b4ee0",
        "0xdf57089febbacf7ba0bc227dafbffa9fc08a93fdc68e1e42411a14efcf23656e",
      ],
      chainId: 31337,
    },
    base: {
      type: "http",
      chainType: "l1",
      url: process.env.BASE_RPC_URL || "https://base-rpc.conet.network",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      chainId: 8453
    },
    baseSepolia: {
      type: "http",
      chainType: "l1",
      url: process.env.BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      chainId: 84532
    },
    conet: {
      type: "http",
      chainType: "l1",
      url: process.env.CONET_RPC_URL || "https://rpc1.conet.network",
      accounts: getConetAccounts(),
      chainId: 224422
    }
  },
  verify: {
    etherscan: {
      apiKey: process.env.BASESCAN_API_KEY || process.env.ETHERSCAN_API_KEY || "dummy",
    },
  },
  chainDescriptors: {
    8453: {
      name: "Base",
      blockExplorers: {
        etherscan: {
          name: "Basescan",
          url: "https://basescan.org",
          apiUrl: "https://api.basescan.org/api",
        },
      },
    },
    84532: {
      name: "Base Sepolia",
      blockExplorers: {
        etherscan: {
          name: "Basescan",
          url: "https://sepolia.basescan.org",
          apiUrl: "https://api-sepolia.basescan.org/api",
        },
      },
    },
    224422: {
      name: "CoNET",
      blockExplorers: {
        etherscan: {
          name: "CoNET Explorer",
          url: "https://mainnet.conet.network",
          apiUrl: "https://mainnet.conet.network/api",
        },
        blockscout: {
          name: "CoNET Explorer",
          url: "https://mainnet.conet.network",
          apiUrl: "https://mainnet.conet.network/api",
        },
      },
    },
  },
})