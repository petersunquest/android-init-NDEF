/**
 * 简化版 NFC Topup 调试（纯 JS，无需 tsx）
 * 用法：TX=0x0997f50a... node scripts/debugNfcTopupTxSimple.js
 */
import { ethers } from 'ethers'

const BASE_CARD_FACTORY = '0xbDC8a165820bB8FA23f5d953632409F73E804eE5'
const BASE_AA_FACTORY = '0xD86403DD1755F7add19540489Ea10cdE876Cc1CE'
const RPC = process.env.BASE_RPC || 'https://1rpc.io/base'
const RPC_FALLBACK = process.env.BASE_RPC_FALLBACK || 'https://1rpc.io/base'

async function providerCallWithFallback(provider, fallback, params) {
	try {
		return await provider.call(params)
	} catch (e) {
		if (/missing revert data|CALL_EXCEPTION/i.test(String(e?.message ?? e))) {
			console.log('  (1rpc 返回 missing revert data，改用 fallback RPC)')
			return fallback.call(params)
		}
		throw e
	}
}

async function main() {
	console.log('RPC:', RPC, '(与 UI baseRpc 一致)')
	console.log('Fallback:', RPC_FALLBACK, '\n')

	const provider = new ethers.JsonRpcProvider(RPC)
	const providerFallback = new ethers.JsonRpcProvider(RPC_FALLBACK)

	let data
	const txHash = process.env.TX
	if (txHash) {
		const tx = await provider.getTransaction(txHash)
		if (!tx?.data) throw new Error(`Tx ${txHash} not found or no data`)
		data = tx.data
		console.log('Fetched data from tx:', txHash, '\n')
	} else {
		throw new Error('请设置 TX=0x... 环境变量')
	}

	const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
		['address', 'bytes', 'uint256', 'bytes32', 'bytes'],
		'0x' + data.slice(10)
	)
	const cardAddr = decoded[0]
	const innerData = decoded[1]
	const deadline = decoded[2]
	const nonce = decoded[3]
	const adminSig = decoded[4]

	const domain = { name: 'BeamioUserCardFactory', version: '1', chainId: 8453, verifyingContract: BASE_CARD_FACTORY }
	const types = { ExecuteForAdmin: [
		{ name: 'cardAddress', type: 'address' },
		{ name: 'dataHash', type: 'bytes32' },
		{ name: 'deadline', type: 'uint256' },
		{ name: 'nonce', type: 'bytes32' },
	]}
	const dataHash = ethers.keccak256(innerData)
	const message = { cardAddress: cardAddr, dataHash, deadline, nonce }
	const digest = ethers.TypedDataEncoder.hash(domain, types, message)
	const signer = ethers.recoverAddress(digest, adminSig)

	const mintIface = new ethers.Interface(['function mintPointsByAdmin(address user, uint256 points6)'])
	const inner = mintIface.parseTransaction({ data: innerData })
	const recipient = inner.args[0]
	const points6 = inner.args[1]

	console.log('=== Parsed ===')
	console.log('cardAddr:', cardAddr)
	console.log('signer:', signer)
	console.log('recipient:', recipient)
	console.log('points6:', points6.toString())
	console.log('deadline:', deadline.toString())

	const block = await provider.getBlock('latest')
	console.log('\ncurrent block.timestamp:', block?.timestamp)

	// 1. Card Factory _aaFactory
	const iface = new ethers.Interface(['function _aaFactory() view returns (address)'])
	const factoryAa = await providerCallWithFallback(provider, providerFallback, {
		to: BASE_CARD_FACTORY,
		data: iface.encodeFunctionData('_aaFactory'),
	})
	const cardFactoryAaFactory = iface.decodeFunctionResult('_aaFactory', factoryAa)[0]
	console.log('\n=== Card Factory _aaFactory ===')
	console.log('Card Factory _aaFactory():', cardFactoryAaFactory)
	console.log('Expected BASE_AA_FACTORY:', BASE_AA_FACTORY)
	console.log('Match:', cardFactoryAaFactory.toLowerCase() === BASE_AA_FACTORY.toLowerCase())

	// 2. Recipient AA
	const aaIface = new ethers.Interface(['function beamioAccountOf(address) view returns (address)'])
	const recipientAA = await providerCallWithFallback(provider, providerFallback, {
		to: cardFactoryAaFactory,
		data: aaIface.encodeFunctionData('beamioAccountOf', [recipient]),
	})
	const recipientAAAddr = aaIface.decodeFunctionResult('beamioAccountOf', recipientAA)[0]
	const recipientAACode = await provider.getCode(recipientAAAddr)
	console.log('\n=== Recipient AA ===')
	console.log('recipientAA:', recipientAAAddr)
	console.log('recipientAA has code:', recipientAACode !== '0x' && recipientAACode.length > 2)

	// 3. Signer isAdmin
	const cardAbi = new ethers.Interface(['function isAdmin(address) view returns (bool)'])
	const isAdminRes = await providerCallWithFallback(provider, providerFallback, {
		to: cardAddr,
		data: cardAbi.encodeFunctionData('isAdmin', [signer]),
	})
	const isAdmin = cardAbi.decodeFunctionResult('isAdmin', isAdminRes)[0]
	console.log('\n=== Signer admin ===')
	console.log('signer isAdmin:', isAdmin)

	// 4. Nonce used（部分 RPC/合约可能 revert，跳过不影响其他检查）
	let nonceUsed = null
	try {
		const nonceKey = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(['address', 'address', 'bytes32'], [cardAddr, signer, nonce]))
		const factoryAbi = new ethers.Interface(['function usedAdminExecuteNonces(bytes32) view returns (bool)'])
		const nonceUsedRes = await providerCallWithFallback(provider, providerFallback, {
			to: BASE_CARD_FACTORY,
			data: factoryAbi.encodeFunctionData('usedAdminExecuteNonces', [nonceKey]),
		})
		nonceUsed = factoryAbi.decodeFunctionResult('usedAdminExecuteNonces', nonceUsedRes)[0]
		console.log('\n=== Nonce ===')
		console.log('nonce already used:', nonceUsed)
	} catch (e) {
		console.log('\n=== Nonce ===')
		console.log('(usedAdminExecuteNonces 调用失败，跳过):', e?.shortMessage ?? e?.message)
	}

	// 5. Card gateway
	let cardGateway = null
	try {
		const gatewayIface = new ethers.Interface(['function factoryGateway() view returns (address)'])
		const gatewayRes = await providerCallWithFallback(provider, providerFallback, {
			to: cardAddr,
			data: gatewayIface.encodeFunctionData('factoryGateway'),
		})
		cardGateway = gatewayIface.decodeFunctionResult('factoryGateway', gatewayRes)[0]
		console.log('\n=== Card gateway ===')
		console.log('card.factoryGateway():', cardGateway)
		console.log('Match:', cardGateway?.toLowerCase() === BASE_CARD_FACTORY.toLowerCase())
	} catch (e) {
		console.log('\n=== Card gateway ===')
		console.log('(factoryGateway 调用失败):', e?.shortMessage ?? e?.message)
	}

	console.log('\n=== Summary ===')
	if (cardFactoryAaFactory.toLowerCase() !== BASE_AA_FACTORY.toLowerCase()) {
		console.log('❌ Card Factory _aaFactory 与 BASE_AA_FACTORY 不一致')
	}
	if (!(recipientAACode !== '0x' && recipientAACode.length > 2)) {
		console.log('❌ Recipient 无有效 AA -> UC_ResolveAccountFailed')
	}
	if (!isAdmin) console.log('❌ Signer 不是 admin')
	if (nonceUsed === true) console.log('❌ Nonce 已使用')
	if (cardGateway && cardGateway.toLowerCase() !== BASE_CARD_FACTORY.toLowerCase()) {
		console.log('❌ Card gateway 不一致')
	}
	// 关键发现：deadline 已过期！
	if (Number(block?.timestamp ?? 0) > Number(deadline)) {
		console.log('❌ deadline 已过期！block.timestamp > deadline -> UC_InvalidTimeWindow')
		console.log('   block.timestamp:', block?.timestamp, 'deadline:', deadline.toString())
	}
	if (cardFactoryAaFactory.toLowerCase() === BASE_AA_FACTORY.toLowerCase() &&
		recipientAACode !== '0x' && recipientAACode.length > 2 && isAdmin &&
		(nonceUsed !== true) &&
		(!cardGateway || cardGateway.toLowerCase() === BASE_CARD_FACTORY.toLowerCase()) &&
		Number(block?.timestamp ?? 0) <= Number(deadline)) {
		console.log('✅ 链上检查均通过')
	}
}

main().catch((e) => { console.error(e); process.exit(1) })
