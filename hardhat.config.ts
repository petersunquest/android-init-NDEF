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
    // 合约目录，只包含 BeamioAccount 和 contracts（排除 x402sdk 和 SilentPassUI）
    // 注意：BeamioAccount.sol 使用相对路径 ../contracts/ 引用 contracts 目录
    sources: "src",
  },
  solidity: {
    version: "0.8.33",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1  // 偏向部署体积，便于 BeamioUserCard 满足 EIP-170 24KB
      },
      viaIR: true  // 解决 "Stack too deep" 错误
    }
  },
  networks: {
    base: {
      type: "http",
      chainType: "l1",
      url: process.env.BASE_RPC_URL || "https://1rpc.io/base",
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
      url: "https://mainnet-rpc.conet.network",
      accounts: getConetAccounts(),
      chainId: 224400
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
    224400: {
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