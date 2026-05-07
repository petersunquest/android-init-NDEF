import { defineConfig } from "hardhat/config"
import hardhatToolboxMochaEthers from "@nomicfoundation/hardhat-toolbox-mocha-ethers"
import * as dotenv from "dotenv"
dotenv.config()
export default defineConfig({
  plugins: [hardhatToolboxMochaEthers],
  paths: { sources: "src" },
  solidity: {
    version: "0.8.33",
    settings: {
      optimizer: { enabled: true, runs: 1 },
      viaIR: false  // 尝试不用 viaIR
    }
  },
  networks: { conet: { url: "https://rpc1.conet.network", chainId: 224422 } },
})
