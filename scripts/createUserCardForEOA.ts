// scripts/createUserCard.ts
// ESM + Hardhat v2.22+ style (network.connect())
// Units: ALL 1e6 for "price" (currency 6dec), and currency enum is uint8
// - USER_CARD_PRICE_6: price per 1e6 points, in card currency "6 decimals"
// - USER_CARD_CURRENCY: BeamioCurrency enum index (CAD=0, USDC=4, ...)

import { network as networkModule } from "hardhat"
import * as fs from "fs"
import * as path from "path"
import { fileURLToPath } from "url"
import { verifyContract } from "./utils/verifyContract.js"
import { deployBeamioUserCardLibraries, beamioUserCardFactoryLibraries } from "./beamioUserCardLibraries.js"

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

const E6 = 10n ** 6n

function mustAddress(ethers: any, v: string, label: string) {
  if (!v) throw new Error(`${label} 为空`)
  if (!ethers.isAddress(v)) throw new Error(`${label} 非法地址: ${v}`)
  return v
}

function toBigint6(v: string | number | bigint) {
  if (typeof v === "bigint") return v
  if (typeof v === "number") return BigInt(Math.trunc(v))
  // string
  if (v.trim() === "") return 0n
  // allow "1000000" only (no decimals)
  if (!/^\d+$/.test(v)) throw new Error(`需要整数(6dec)，但收到: ${v}`)
  return BigInt(v)
}

function fmt6(v: bigint) {
  const whole = v / E6
  const frac = v % E6
  const fracStr = frac.toString().padStart(6, "0")
  return `${whole.toString()}.${fracStr}`
}

// best-effort: parse CardDeployed(card, owner, ...) or similar
function findCardDeployedLog(ethers: any, iface: any, logs: any[]) {
  for (const log of logs) {
    try {
      const parsed = iface.parseLog(log)
      if (parsed?.name === "CardDeployed") return parsed
    } catch {}
  }
  return null
}

async function main() {
  const { ethers } = await networkModule.connect()
  const [signer] = await ethers.getSigners()
  const networkInfo = await ethers.provider.getNetwork()

  const TARGET_EOA = mustAddress(ethers, process.env.TARGET_EOA || "", "TARGET_EOA")

  console.log("=".repeat(70))
  console.log("Create BeamioUserCard (units = 1e6)")
  console.log("=".repeat(70))
  console.log("Target EOA:", TARGET_EOA)
  console.log("Deployer:", signer.address)
  console.log("Deployer balance:", ethers.formatEther(await ethers.provider.getBalance(signer.address)), "ETH")
  console.log("Network:", networkInfo.name, `(chainId=${networkInfo.chainId.toString()})`)
  console.log()

  // 1) Resolve factory address
  let USER_CARD_FACTORY_ADDRESS = process.env.USER_CARD_FACTORY_ADDRESS || ""

  if (!USER_CARD_FACTORY_ADDRESS) {
    const deploymentsDir = path.join(__dirname, "..", "deployments")
    const fullSystemFile = path.join(deploymentsDir, `${networkInfo.name}-FullSystem.json`)
    if (fs.existsSync(fullSystemFile)) {
      const deploymentData = JSON.parse(fs.readFileSync(fullSystemFile, "utf-8"))
      const fromFile = deploymentData.contracts?.beamioUserCardFactoryPaymaster?.address
      if (fromFile) {
        USER_CARD_FACTORY_ADDRESS = fromFile
        console.log("✅ Loaded factory from deployments:", USER_CARD_FACTORY_ADDRESS)
      }
    }
  }

  USER_CARD_FACTORY_ADDRESS = mustAddress(ethers, USER_CARD_FACTORY_ADDRESS, "USER_CARD_FACTORY_ADDRESS")

  // 2) Read params (IMPORTANT: price is 6-decimals integer)
  const USER_CARD_URI = process.env.USER_CARD_URI || "https://beamio.app/api/metadata/0x"
  const USER_CARD_CURRENCY = Number.parseInt(process.env.USER_CARD_CURRENCY || "0", 10) // default CAD=0
  if (!Number.isFinite(USER_CARD_CURRENCY) || USER_CARD_CURRENCY < 0 || USER_CARD_CURRENCY > 255) {
    throw new Error(`USER_CARD_CURRENCY 非法: ${process.env.USER_CARD_CURRENCY}`)
  }

  // ✅ 价格：单位 1e6（currency 6dec）。默认 1.000000
  const USER_CARD_PRICE_6 =
    process.env.USER_CARD_PRICE_6 != null
      ? toBigint6(process.env.USER_CARD_PRICE_6)
      : 1n * E6

  if (USER_CARD_PRICE_6 <= 0n) throw new Error("USER_CARD_PRICE_6 必须 > 0")

  console.log("Config:")
  console.log("  Factory:", USER_CARD_FACTORY_ADDRESS)
  console.log("  URI:", USER_CARD_URI)
  console.log("  Currency enum:", USER_CARD_CURRENCY)
  console.log("  Price (6dec int):", USER_CARD_PRICE_6.toString(), `(${fmt6(USER_CARD_PRICE_6)})`)
  console.log("  Owner:", TARGET_EOA)
  console.log()

  // 3) Basic on-chain sanity checks
  const gatewayCode = await ethers.provider.getCode(USER_CARD_FACTORY_ADDRESS)
  if (gatewayCode === "0x") throw new Error(`Factory/Gateway ${USER_CARD_FACTORY_ADDRESS} has no code`)
  console.log("✅ Factory/Gateway code exists")

  const userCardFactory = await ethers.getContractAt(
    "BeamioUserCardFactoryPaymasterV07",
    USER_CARD_FACTORY_ADDRESS
  )

  // Paymaster permission
  const isPaymaster = await userCardFactory.isPaymaster(signer.address)
  console.log("Is paymaster:", isPaymaster)
  if (!isPaymaster) throw new Error("Signer is not paymaster; cannot create usercard")

  // existing cards
  const oldCards: string[] = await userCardFactory.cardsOfOwner(TARGET_EOA)
  console.log("Existing cards:", oldCards.length)
  if (oldCards.length) {
    for (const c of oldCards) {
      const reg = await userCardFactory.isBeamioUserCard(c)
      console.log(`  - ${c} (registered=${reg})`)
    }
  }
  console.log()

  // 4) Build initCode for BeamioUserCard constructor:
  // constructor(string uri_, CurrencyType currency_, uint256 pointsUnitPriceInCurrencyE6_, address initialOwner, address gateway_)
  // 价格单位 E6（与购买时 1e6 一致），例如 1 CAD = 1 token 传 1e6
  const priceForConstructor = USER_CARD_PRICE_6

  console.log("Prepare initCode...")
  const cardLibs = await deployBeamioUserCardLibraries(ethers, signer)
  const BeamioUserCard = await ethers.getContractFactory("BeamioUserCard", beamioUserCardFactoryLibraries(cardLibs))

  const deployTx = await BeamioUserCard.getDeployTransaction(
    USER_CARD_URI,
    USER_CARD_CURRENCY,
    priceForConstructor,
    TARGET_EOA,
    USER_CARD_FACTORY_ADDRESS,
    0,
    false
  )

  const initCode = deployTx.data
  if (!initCode) throw new Error("Failed to build initCode")
  console.log("InitCode length:", initCode.length)
  console.log("Price passed to constructor (E6):", priceForConstructor.toString(), `(${fmt6(priceForConstructor)})`)
  console.log()

  // 5) StaticCall simulate
  console.log("Static call simulation...")
  try {
    await userCardFactory.createCardCollectionWithInitCode.staticCall(
      TARGET_EOA,
      USER_CARD_CURRENCY,
      priceForConstructor,
      initCode
    )
    console.log("✅ Simulation OK")
  } catch (err: any) {
    console.log("❌ Simulation failed:", err?.message || err)
    if (err?.data) {
      console.log("error.data:", err.data)
      try {
        const parsed = userCardFactory.interface.parseError(err.data)
        console.log("Parsed error:", parsed)
      } catch {
        console.log("Could not parse error data")
      }
    }
    throw err
  }

  // 6) Send tx
  console.log("=".repeat(70))
  console.log("Create BeamioUserCard on-chain")
  console.log("=".repeat(70))

  const tx = await userCardFactory.createCardCollectionWithInitCode(
    TARGET_EOA,
    USER_CARD_CURRENCY,
    priceForConstructor,
    initCode
  )
  console.log("Tx:", tx.hash)

  const receipt = await tx.wait()
  console.log("✅ Created. block:", receipt?.blockNumber, "hash:", receipt?.hash)

  // 7) Get new card address
  let userCardAddress = ""

  const ev = findCardDeployedLog(ethers, userCardFactory.interface, receipt?.logs || [])
  if (ev) {
    // common pattern: args.card
    userCardAddress = ev.args?.card || ev.args?.userCard || ""
  }

  if (!userCardAddress) {
    const newCards: string[] = await userCardFactory.cardsOfOwner(TARGET_EOA)
    if (newCards.length <= oldCards.length) throw new Error("Cannot locate new card address")
    userCardAddress = newCards[newCards.length - 1]
  }

  userCardAddress = mustAddress(ethers, userCardAddress, "New UserCard")
  console.log("New UserCard:", userCardAddress)

  // 8) Post-create checks (关键设定检查)
  console.log("\n" + "=".repeat(70))
  console.log("Post-create checks (key settings)")
  console.log("=".repeat(70))

  const isRegistered = await userCardFactory.isBeamioUserCard(userCardAddress)
  console.log("Factory registered:", isRegistered)

  // read from UserCard
  const userCard = await ethers.getContractAt("BeamioUserCard", userCardAddress)

  const [
    ucVersion,
    ucGateway,
    ucOwner,
    ucCurrency,
    ucPriceE6,
    ucExpirySeconds,
    ucThreshold,
    ucDeployer,
    wlEnabled
  ] = await Promise.all([
    userCard.version?.().catch(() => null),
    userCard.factoryGateway?.().catch(() => userCard.gateway?.().catch(() => null)),
    userCard.owner(),
    userCard.currency?.(),
    userCard.pointsUnitPriceInCurrencyE6?.(),
    userCard.expirySeconds?.().catch(() => null),
    userCard.threshold?.().catch(() => null),
    userCard.deployer?.().catch(() => null),
    userCard.transferWhitelistEnabled?.().catch(() => null)
  ])

  console.log("UserCard.version:", ucVersion?.toString?.() ?? "(n/a)")
  console.log("UserCard.gateway:", ucGateway ?? "(n/a)")
  console.log("UserCard.owner  :", ucOwner)
  console.log("UserCard.currency(enum):", ucCurrency?.toString?.() ?? "(n/a)")
  console.log("UserCard.priceE6:", ucPriceE6?.toString?.() ?? "(n/a)", ucPriceE6 != null ? `(${fmt6(BigInt(ucPriceE6.toString()))})` : "")
  console.log("UserCard.expirySeconds:", ucExpirySeconds?.toString?.() ?? "(n/a)")
  console.log("UserCard.threshold:", ucThreshold?.toString?.() ?? "(n/a)")
  console.log("UserCard.deployer:", ucDeployer ?? "(n/a)")
  console.log("UserCard.transferWhitelistEnabled:", wlEnabled?.toString?.() ?? "(n/a)")

  // quick balance check: points balance of account owner is AA-account, so use getOwnershipByEOA if exists
  if (typeof userCard.getOwnershipByEOA === "function") {
    try {
      const [pt] = await userCard.getOwnershipByEOA(TARGET_EOA)
      console.log("Ownership(points6) for EOA:", pt.toString(), `(${fmt6(BigInt(pt.toString()))} pts)`)
    } catch {
      // ignore
    }
  }

  // 9) Optional: verify on explorer
  const explorerBase =
    networkInfo.chainId === 8453n
      ? "https://basescan.org"
      : networkInfo.chainId === 84532n
      ? "https://sepolia.basescan.org"
      : ""

  if (explorerBase) {
    console.log("\n" + "=".repeat(70))
    console.log("Verify on explorer")
    console.log("=".repeat(70))

    // wait a bit (optional)
    await new Promise((r) => setTimeout(r, 30_000))

    try {
      await verifyContract(
        userCardAddress,
        [
          USER_CARD_URI,
          USER_CARD_CURRENCY,
          priceForConstructor.toString(),
          TARGET_EOA,
          USER_CARD_FACTORY_ADDRESS
        ],
        "BeamioUserCard"
      )
      console.log("✅ Verified")
      console.log("View:", `${explorerBase}/address/${userCardAddress}#code`)
    } catch (e: any) {
      console.log("⚠️ Verify failed:", e?.message || e)
      console.log("Manual verify:")
      console.log(
        `npx hardhat verify --network ${networkInfo.name} ${userCardAddress} "${USER_CARD_URI}" ${USER_CARD_CURRENCY} ${priceForConstructor.toString()} ${TARGET_EOA} ${USER_CARD_FACTORY_ADDRESS}`
      )
    }
  }

  // 10) Save deployment info
  const deploymentInfo = {
    network: networkInfo.name,
    chainId: networkInfo.chainId.toString(),
    eoa: TARGET_EOA,
    userCard: userCardAddress,
    factory: USER_CARD_FACTORY_ADDRESS,
    uri: USER_CARD_URI,
    currency: USER_CARD_CURRENCY,
    price6: USER_CARD_PRICE_6.toString(),
    timestamp: new Date().toISOString(),
    transactionHash: receipt?.hash
  }

  const deploymentFile = path.join(
    __dirname,
    "..",
    "deployments",
    `${networkInfo.name}-UserCard-${TARGET_EOA.slice(0, 10)}.json`
  )

  fs.mkdirSync(path.dirname(deploymentFile), { recursive: true })
  fs.writeFileSync(deploymentFile, JSON.stringify(deploymentInfo, null, 2))

  console.log("\n" + "=".repeat(70))
  console.log("Done")
  console.log("=".repeat(70))
  console.log("Saved:", deploymentFile)
  if (explorerBase) {
    console.log("Explorer:", `${explorerBase}/address/${userCardAddress}`)
    console.log("Tx:", `${explorerBase}/tx/${receipt.hash}`)
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err)
    process.exit(1)
  })
