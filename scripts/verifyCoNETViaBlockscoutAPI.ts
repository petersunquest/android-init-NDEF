/**
 * 通过 Blockscout API 验证 BeamioIndexerDiamond
 * 解决 mainnet.conet.network 验证失败问题：使用 Blockscout legacy API（module=contract&action=verify）
 *
 * 前置: npx hardhat flatten src/CoNETIndexTaskdiamond/BeamioIndexerDiamond.sol 2>/dev/null > scripts/BeamioIndexerDiamond_flat.sol
 * 运行: npx tsx scripts/verifyCoNETViaBlockscoutAPI.ts
 *
 * 若仍失败，可手动在 Blockscout UI 验证：
 *   https://mainnet.conet.network/contract-verification
 *   选择 "Via flattened source code"，粘贴 BeamioIndexerDiamond_flat.sol 内容
 */

import { ethers } from "ethers"
import * as fs from "fs"
import * as path from "path"
import { fileURLToPath } from "url"

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

const DIAMOND = "0x0DBDF27E71f9c89353bC5e4dC27c9C5dAe0cc612"
/** Blockscout legacy API - 避免 v2 的 413 限制 */
const BLOCKSCOUT_API = "https://mainnet.conet.network/api"
const INITIAL_OWNER = "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1"
const DIAMOND_CUT_FACET = "0xf079eA83B3dDBaB64473df13Fa49021BA85E80C4"

async function main() {
	const flatPath = path.join(__dirname, "BeamioIndexerDiamond_flat.sol")
	let sourceCode = fs.readFileSync(flatPath, "utf-8")
	// 移除 hardhat flatten 可能混入的 dotenv 等非源码行
	sourceCode = sourceCode.replace(/^\[dotenv[^\n]*\n/, "")
	if (!sourceCode.includes("contract BeamioIndexerDiamond")) {
		throw new Error("Flattened file invalid - run: npx hardhat flatten src/CoNETIndexTaskdiamond/BeamioIndexerDiamond.sol > scripts/BeamioIndexerDiamond_flat.sol")
	}

	const coder = ethers.AbiCoder.defaultAbiCoder()
	const encoded = coder.encode(["address", "address"], [INITIAL_OWNER, DIAMOND_CUT_FACET])
	const constructorArgsHex = encoded.startsWith("0x") ? encoded.slice(2) : encoded

	// 优先尝试 Blockscout legacy API (module=contract&action=verify)
	// 参考: https://docs.blockscout.com/devs/apis/rpc/contract
	const legacyBody: Record<string, unknown> = {
		addressHash: DIAMOND,
		name: "BeamioIndexerDiamond",
		compilerVersion: "v0.8.33+commit.64118f21",
		optimization: "1",
		contractSourceCode: sourceCode,
		constructorArguments: constructorArgsHex,
		optimizationRuns: "50",
		evmVersion: "osaka",
	}

	const legacyUrl = `${BLOCKSCOUT_API}?module=contract&action=verify`
	console.log("POST", legacyUrl, "(Blockscout legacy API)")
	const res = await fetch(legacyUrl, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify(legacyBody),
	})
	const data = (await res.json().catch(() => ({}))) as Record<string, unknown>

	if (res.ok && (data.status === "1" || data.result)) {
		const guid = (data as { result?: string }).result
		console.log("Verification submitted. GUID:", guid)
		console.log("\n✅ 验证已提交到 Blockscout！查看: https://mainnet.conet.network/address/" + DIAMOND)
		return
	}

	// 若 legacy API 失败，回退到 v2 flattened-code
	console.warn("Legacy API 未成功，尝试 v2 flattened-code API...")
	const v2Body = {
		compiler_version: "v0.8.33+commit.64118f21",
		license_type: "mit",
		source_code: sourceCode,
		is_optimization_enabled: true,
		optimization_runs: 50,
		contract_name: "BeamioIndexerDiamond",
		constructor_arguments: constructorArgsHex,
		autodetect_constructor_args: false,
		evm_version: "osaka",
	} as Record<string, unknown>
	if (process.env.VIA_IR !== "0") {
		v2Body.via_ir = true
	}
	const v2Res = await fetch(
		`https://mainnet.conet.network/api/v2/smart-contracts/${DIAMOND}/verification/via/flattened-code`,
		{ method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(v2Body) }
	)
	const v2Data = await v2Res.json().catch(() => ({}))
	if (!v2Res.ok) {
		console.error("Both APIs failed. Legacy:", data, "V2:", v2Data)
		throw new Error("验证失败。可手动在 https://mainnet.conet.network/contract-verification 粘贴 flattened 源码验证")
	}
	console.log("V2 result:", v2Data)
	console.log("\n✅ 验证已提交！查看: https://mainnet.conet.network/address/" + DIAMOND)
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
