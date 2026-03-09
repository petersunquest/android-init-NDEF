/**
 * 脚本：将 Settle_ContractPool 的钱包添加到两个 Factory 作为 paymaster
 * 
 * 用法:
 *   npx hardhat run scripts/addSettleWalletsToFactories.ts --network base
 *   或
 *   npx tsx scripts/addSettleWalletsToFactories.ts
 * 
 * 配置来源:
 *   - 从 ~/.master.json 读取 masterSetup（包含 settle_contractAdmin 和 base_endpoint）
 */
import { ethers } from 'ethers'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { readFileSync } from 'node:fs'
import Colors from 'colors/safe'
import BeamioFactoryPaymasterABI from './API server/ABI/BeamioUserCardFactoryPaymaster.json'
import BeamioAAAccountFactoryPaymasterABI from './API server/ABI/BeamioAAAccountFactoryPaymaster.json'

// 从 ~/.master.json 读取配置
const setupFile = join(homedir(), '.master.json')
let masterSetup: { settle_contractAdmin: string[]; base_endpoint: string }

try {
	masterSetup = JSON.parse(readFileSync(setupFile, 'utf-8'))
} catch (e) {
	console.error(Colors.red(`❌ 无法读取配置文件: ${setupFile}`))
	console.error(Colors.red(`错误: ${e instanceof Error ? e.message : String(e)}`))
	console.log()
	console.log('请确保 ~/.master.json 文件存在且格式正确:')
	console.log('  {')
	console.log('    "settle_contractAdmin": ["pk1", "pk2", "pk3"],')
	console.log('    "base_endpoint": "https://base-rpc.conet.network"')
	console.log('  }')
	process.exit(1)
}

// Base Mainnet：与 config/base-addresses.ts 一致
import { BASE_MAINNET_FACTORIES } from '../config/base-addresses'
const BeamioUserCardFactoryPaymasterV2 = BASE_MAINNET_FACTORIES.CARD_FACTORY
const BeamioAAAccountFactoryPaymaster = BASE_MAINNET_FACTORIES.AA_FACTORY

async function main() {
	console.log(Colors.cyan('='.repeat(70)))
	console.log(Colors.cyan('添加 Settle Wallets 到 Factory Paymasters'))
	console.log(Colors.cyan('='.repeat(70)))
	console.log()

	const adminPks = masterSetup?.settle_contractAdmin || []
	if (!adminPks || adminPks.length === 0) {
		console.error(Colors.red('❌ 错误: ~/.master.json 中 settle_contractAdmin 为空或未设置'))
		console.log()
		console.log('请检查 ~/.master.json 文件，确保包含:')
		console.log('  {')
		console.log('    "settle_contractAdmin": ["pk1", "pk2", "pk3"],')
		console.log('    "base_endpoint": "https://base-rpc.conet.network"')
		console.log('  }')
		process.exit(1)
	}

	const baseEndpoint = masterSetup?.base_endpoint || 'https://base-rpc.conet.network'
	const provider = new ethers.JsonRpcProvider(baseEndpoint)
	
	// 确保私钥格式正确（可能需要添加 0x 前缀）
	const normalizedPks = adminPks.map((pk: string) => {
		const trimmed = pk.trim()
		return trimmed.startsWith('0x') ? trimmed : `0x${trimmed}`
	})
	
	const wallet = new ethers.Wallet(normalizedPks[0], provider)
	const addresses = normalizedPks.map((pk: string) => new ethers.Wallet(pk, provider).address)

	console.log('配置:')
	console.log(`  配置文件: ~/.master.json`)
	console.log(`  网络 RPC: ${baseEndpoint}`)
	console.log(`  钱包数量: ${adminPks.length}`)
	console.log('  钱包地址:')
	addresses.forEach((addr, i) => {
		console.log(`    ${i + 1}. ${addr}`)
	})
	console.log()

	// 验证第一个钱包是否有权限（检查余额）
	const balance = await provider.getBalance(wallet.address)
	console.log(`第一个钱包 (将作为 signer):`)
	console.log(`  地址: ${wallet.address}`)
	console.log(`  余额: ${ethers.formatEther(balance)} ETH`)
	if (balance === 0n) {
		console.log(Colors.yellow('⚠️  警告: 第一个钱包余额为 0，可能无法发送交易'))
	}
	console.log()

	console.log(Colors.yellow('⚠️  确认: 第一个钱包必须是:'))
	console.log(Colors.yellow('  - Card Factory (BeamioUserCardFactoryPaymasterV07) 的 owner'))
	console.log(Colors.yellow('  - AA Factory (BeamioFactoryPaymasterV07) 的 admin'))
	console.log()

	// 执行添加
	try {
		console.log(Colors.cyan('开始执行...'))
		console.log()

		// 手动构建 ABI Interface（因为 ABI 文件是占位符）
		const cardFactoryInterface = new ethers.Interface([
			'function owner() view returns (address)',
			'function isPaymaster(address) view returns (bool)',
			'function changePaymasterStatus(address, bool)'
		])
		const aaFactoryInterface = new ethers.Interface([
			'function admin() view returns (address)',
			'function isPayMaster(address) view returns (bool)',
			'function addPayMaster(address)'
		])

		const cardFactory = new ethers.Contract(BeamioUserCardFactoryPaymasterV2, cardFactoryInterface, wallet)
		const aaFactory = new ethers.Contract(BeamioAAAccountFactoryPaymaster, aaFactoryInterface, wallet)

		// 验证权限（可选，用于提前发现错误）
		try {
			const cardOwner = await cardFactory.owner()
			const aaAdmin = await aaFactory.admin()
			console.log(`Card Factory Owner: ${cardOwner}`)
			console.log(`AA Factory Admin: ${aaAdmin}`)
			console.log(`Signer Address: ${wallet.address}`)
			if (cardOwner.toLowerCase() !== wallet.address.toLowerCase()) {
				console.log(Colors.yellow(`⚠️  警告: Signer 不是 Card Factory 的 owner`))
			}
			if (aaAdmin.toLowerCase() !== wallet.address.toLowerCase()) {
				console.log(Colors.yellow(`⚠️  警告: Signer 不是 AA Factory 的 admin`))
			}
			console.log()
		} catch (e) {
			console.log(Colors.yellow('⚠️  无法验证权限，继续执行...'))
			console.log()
		}

		const addedCard: string[] = []
		const addedAA: string[] = []

		for (let i = 0; i < addresses.length; i++) {
			const addr = addresses[i]
			if (!ethers.isAddress(addr)) {
				console.log(Colors.yellow(`跳过无效地址: ${addr}`))
				continue
			}
			
			console.log(Colors.cyan(`\n处理钱包 ${i + 1}/${addresses.length}: ${addr}`))
			
			// Card Factory
			try {
				const isPaymaster = await cardFactory.isPaymaster(addr)
				if (!isPaymaster) {
					console.log(Colors.yellow(`  添加到 Card Factory...`))
					const tx = await cardFactory.changePaymasterStatus(addr, true)
					console.log(`  交易哈希: ${tx.hash}`)
					const receipt = await tx.wait()
					console.log(`  确认区块: ${receipt?.blockNumber}`)
					addedCard.push(addr)
					console.log(Colors.green(`  ✅ Card Factory: 已添加 paymaster`))
				} else {
					console.log(`  ℹ️  Card Factory: 已是 paymaster`)
				}
			} catch (e: unknown) {
				const msg = e instanceof Error ? e.message : String(e)
				console.error(Colors.red(`  ❌ Card Factory 添加失败: ${msg}`))
			}
			
			// AA Factory
			try {
				const isPM = await aaFactory.isPayMaster(addr)
				if (!isPM) {
					console.log(Colors.yellow(`  添加到 AA Factory...`))
					const tx = await aaFactory.addPayMaster(addr)
					console.log(`  交易哈希: ${tx.hash}`)
					const receipt = await tx.wait()
					console.log(`  确认区块: ${receipt?.blockNumber}`)
					addedAA.push(addr)
					console.log(Colors.green(`  ✅ AA Factory: 已添加 paymaster`))
				} else {
					console.log(`  ℹ️  AA Factory: 已是 paymaster`)
				}
			} catch (e: unknown) {
				const msg = e instanceof Error ? e.message : String(e)
				console.error(Colors.red(`  ❌ AA Factory 添加失败: ${msg}`))
			}
		}

		console.log()
		console.log(Colors.cyan('='.repeat(70)))
		console.log(Colors.green('✅ 执行完成!'))
		console.log(Colors.cyan('='.repeat(70)))
		console.log()

		if (addedCard.length > 0) {
			console.log(Colors.green(`Card Factory 新增 ${addedCard.length} 个 paymaster:`))
			addedCard.forEach((addr, i) => {
				console.log(`  ${i + 1}. ${addr}`)
			})
		} else {
			console.log(Colors.yellow('Card Factory: 无新增（所有地址已是 paymaster）'))
		}
		console.log()

		if (addedAA.length > 0) {
			console.log(Colors.green(`AA Factory 新增 ${addedAA.length} 个 paymaster:`))
			addedAA.forEach((addr, i) => {
				console.log(`  ${i + 1}. ${addr}`)
			})
		} else {
			console.log(Colors.yellow('AA Factory: 无新增（所有地址已是 paymaster）'))
		}
		console.log()

	} catch (error: unknown) {
		const msg = error instanceof Error ? error.message : String(error)
		console.error(Colors.red('❌ 执行失败:'), msg)
		if (error instanceof Error && error.stack) {
			console.error(Colors.red('堆栈:'), error.stack)
		}
		process.exit(1)
	}
}

main()
	.then(() => {
		console.log()
		console.log(Colors.cyan('脚本执行完成'))
		process.exit(0)
	})
	.catch((error) => {
		console.error(Colors.red('未捕获的错误:'), error)
		process.exit(1)
	})
