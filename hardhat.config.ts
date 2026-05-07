import { defineConfig } from "hardhat/config"
import hardhatToolboxMochaEthers from "@nomicfoundation/hardhat-toolbox-mocha-ethers"
import * as dotenv from "dotenv"
import * as fs from "fs"
import * as path from "path"
import { homedir } from "os"

dotenv.config()

/** 与 Base 上 0x291B… BeamioQuoteHelperV07 部署时一致：runs=50 + 默认 metadata（ipfs）+ 不 strip revert（旧 hardhat 无此两项） */
const beamioSolcVerifyQuoteHelperV07 = process.env.BEAMIO_SOLC_VERIFY_QUOTEHELPER_V07 === "1"

/** CoNET 部署私钥：合并 settle_contractAdmin、beamio_Admins、admin（均为私钥 hex 列表，去重） */
function getConetAccounts(): string[] {
  const setupPath = path.join(homedir(), ".master.json")
  if (!fs.existsSync(setupPath)) return []
  try {
    const master = JSON.parse(fs.readFileSync(setupPath, "utf-8"))
    const settle = Array.isArray(master?.settle_contractAdmin) ? master.settle_contractAdmin : []
    const beamioAdmins = Array.isArray(master?.beamio_Admins) ? master.beamio_Admins : []
    const extra = Array.isArray(master?.admin) ? master.admin : []
    const raw: string[] = [...settle, ...beamioAdmins, ...extra]
    const keys = raw
      .filter((k): k is string => typeof k === "string" && k.length > 0)
      .map((k) => (k.startsWith("0x") ? k : "0x" + k))
    return [...new Set(keys)]
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
    ],
  },
  solidity: {
    version: "0.8.33",
    settings: {
      ...(beamioSolcVerifyQuoteHelperV07
        ? {}
        : {
            metadata: {
              bytecodeHash: "none",
            },
            debug: {
              revertStrings: "strip",
            },
          }),
      optimizer: {
        enabled: true,
        runs: beamioSolcVerifyQuoteHelperV07
          ? 50
          : Number(process.env.BEAMIO_SOLC_OPTIMIZER_RUNS || 0) || 0,
      },
      viaIR: true, // 解决 "Stack too deep" 错误
      evmVersion: "cancun", // 必须：Bytes.sol 使用 mcopy (Cancun)
    },
  },
  networks: {
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