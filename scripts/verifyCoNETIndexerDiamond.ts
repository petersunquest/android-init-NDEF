/**
 * 在 CoNET Mainnet Explorer 上验证 BeamioIndexerDiamond
 * https://mainnet.conet.network/
 *
 * 前置：
 *   1. npm install（含 @nomicfoundation/hardhat-verify）
 *   2. hardhat compile
 *
 * 运行: npm run verify:indexer-diamond:conet
 *   或: npx hardhat run scripts/verifyCoNETIndexerDiamond.ts --network conet
 *
 * 若程序验证失败，可手动走 Sourcify：
 *   1. 打开 https://mainnet.conet.network/ → Other → Verify contract
 *   2. 输入当前 deployments/conet-IndexerDiamond.json 中的 Diamond 地址
 *   3. 选择 Verification method: Sourcify
 *   4. 上传 artifacts + 源码，或粘贴 Standard JSON Input
 */

import { run } from "hardhat"
import * as path from "path"
import * as fs from "fs"
import { fileURLToPath } from "url"

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

const DEPLOYMENT = path.join(__dirname, "../deployments/conet-IndexerDiamond.json")

async function main() {
	const deployJson = JSON.parse(fs.readFileSync(DEPLOYMENT, "utf-8"))
	const diamondAddr = deployJson.diamond
	const cutFacetAddr = deployJson.facets?.DiamondCutFacet
	const initialOwner = deployJson.deployer

	if (!diamondAddr || !cutFacetAddr || !initialOwner) {
		throw new Error("部署文件缺少 diamond / DiamondCutFacet / deployer")
	}

	console.log("=".repeat(60))
	console.log("验证 BeamioIndexerDiamond 到 CoNET Explorer")
	console.log("=".repeat(60))
	console.log("Diamond 地址:", diamondAddr)
	console.log("constructor args: initialOwner=", initialOwner, "diamondCutFacet=", cutFacetAddr)

	// 合约全限定名（须与 artifacts 中 sourceName 一致）
	const contractFqn = "src/CoNETIndexTaskdiamond/BeamioIndexerDiamond.sol:BeamioIndexerDiamond"

	await run("verify:verify", {
		address: diamondAddr,
		contract: contractFqn,
		constructorArguments: [initialOwner, cutFacetAddr],
	})

	console.log("\n✅ BeamioIndexerDiamond 验证成功！")
	console.log("查看: https://mainnet.conet.network/address/" + diamondAddr)
}

main()
	.then(() => process.exit(0))
	.catch((err) => {
		console.error(err)
		process.exit(1)
	})
