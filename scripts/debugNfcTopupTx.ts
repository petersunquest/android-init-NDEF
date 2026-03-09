/**
 * 调试 NFC Topup 失败交易：解析 data、恢复 signer、检查 admin/nonce/recipient/aaFactory
 * 用法：TX=0x0997f50a... npx tsx scripts/debugNfcTopupTx.ts
 */
import { ethers } from 'ethers'

const BASE_CARD_FACTORY = '0xDdD5c17E549a4e66ca636a3c528ae8FAebb8692b'
const BASE_AA_FACTORY = '0xD86403DD1755F7add19540489Ea10cdE876Cc1CE'
/** 与 UI baseRpc 一致：优先 Beamio Base RPC；部分 call 可能返回 missing revert data，可设 BASE_RPC_FALLBACK 备用 */
const RPC = process.env.BASE_RPC || 'https://base-rpc.conet.network'
const RPC_FALLBACK = process.env.BASE_RPC_FALLBACK || 'https://base-rpc.conet.network'

const DEFAULT_DATA =
	'0xe83492d100000000000000000000000057052780925448ce1db7ac409ccccf13bcc4eb7100000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000699e1ec7a1f39f2dad9905bfb9d34840ea5c6795e07736f46fe6aae95880841035e44ccd00000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000000044564da7570000000000000000000000003fd6964e322ab2fe9cb4f5d0b9e5166eea9e4fe40000000000000000000000000000000000000000000000000000000000b71afa000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000041a0496595b273a4d62b7e0b310f61cb7b809680ae44ce3ed159f80f1480a2683a53b163c436458174db03083c26d42e5515758ad3858796ebeafc56029c4a1ff01c00000000000000000000000000000000000000000000000000000000000000'

/** 带 fallback 的 provider.call：1rpc 部分 call 可能返回 missing revert data，自动切 fallback */
async function providerCallWithFallback(
	provider: ethers.JsonRpcProvider,
	fallback: ethers.JsonRpcProvider,
	params: { to: `0x${string}`; data: `0x${string}` }
): Promise<string> {
	try {
		return (await provider.call(params)) as string
	} catch (e: unknown) {
		if (/missing revert data|CALL_EXCEPTION/i.test(String((e as Error)?.message ?? e))) {
			console.log('  (1rpc 返回 missing revert data，改用 fallback RPC)')
			return fallback.call(params) as Promise<string>
		}
		throw e
	}
}

async function main() {
	console.log('RPC:', RPC, '(与 UI baseRpc 一致)')
	console.log('Fallback:', RPC_FALLBACK, '\n')
	const provider = new ethers.JsonRpcProvider(RPC)
	const providerFallback = new ethers.JsonRpcProvider(RPC_FALLBACK)
	let data = DEFAULT_DATA
	const txHash = process.env.TX
	if (txHash) {
		const tx = await provider.getTransaction(txHash)
		if (!tx?.data) throw new Error(`Tx ${txHash} not found or no data`)
		data = tx.data
		console.log('Fetched data from tx:', txHash, '\n')
	}

	const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
		['address', 'bytes', 'uint256', 'bytes32', 'bytes'],
		'0x' + data.slice(10)
	) as [string, string, bigint, string, string]
	const cardAddr = decoded[0] as string
	const innerData = decoded[1] as string
	const deadline = decoded[2] as bigint
	const nonce = decoded[3] as string
	const adminSig = decoded[4] as string

	const dataHash = ethers.keccak256(innerData)
	const domain = {
		name: 'BeamioUserCardFactory',
		version: '1',
		chainId: 8453,
		verifyingContract: BASE_CARD_FACTORY,
	}
	const types = {
		ExecuteForAdmin: [
			{ name: 'cardAddress', type: 'address' },
			{ name: 'dataHash', type: 'bytes32' },
			{ name: 'deadline', type: 'uint256' },
			{ name: 'nonce', type: 'bytes32' },
		],
	}
	const message = { cardAddress: cardAddr, dataHash, deadline, nonce }
	const digest = ethers.TypedDataEncoder.hash(domain, types, message)
	const signer = ethers.recoverAddress(digest, adminSig)

	const mintIface = new ethers.Interface(['function mintPointsByAdmin(address user, uint256 points6)'])
	const inner = mintIface.parseTransaction({ data: innerData })
	const recipient = inner!.args[0] as string
	const points6 = inner!.args[1] as bigint

	console.log('=== Parsed ===')
	console.log('cardAddr:', cardAddr)
	console.log('deadline:', deadline.toString())
	console.log('signer:', signer)
	console.log('recipient:', recipient)
	console.log('points6:', points6.toString())

	const block = await provider.getBlock('latest')
	console.log('\ncurrent block.timestamp:', block?.timestamp)

	// 1. Card Factory _aaFactory
	const iface = new ethers.Interface(['function _aaFactory() view returns (address)'])
	const factoryAa = await providerCallWithFallback(provider, providerFallback, {
		to: BASE_CARD_FACTORY as `0x${string}`,
		data: iface.encodeFunctionData('_aaFactory') as `0x${string}`,
	})
	const cardFactoryAaFactory = iface.decodeFunctionResult('_aaFactory', factoryAa)[0] as string
	console.log('\n=== Card Factory _aaFactory ===')
	console.log('Card Factory _aaFactory():', cardFactoryAaFactory)
	console.log('Expected BASE_AA_FACTORY:', BASE_AA_FACTORY)
	console.log('Match:', cardFactoryAaFactory.toLowerCase() === BASE_AA_FACTORY.toLowerCase())

	// 2. Recipient AA from Card's expected AA Factory
	const aaIface = new ethers.Interface(['function beamioAccountOf(address) view returns (address)'])
	const recipientAA = await providerCallWithFallback(provider, providerFallback, {
		to: cardFactoryAaFactory as `0x${string}`,
		data: aaIface.encodeFunctionData('beamioAccountOf', [recipient]) as `0x${string}`,
	})
	const recipientAAAddr = aaIface.decodeFunctionResult('beamioAccountOf', recipientAA)[0] as string
	const recipientAACode = await provider.getCode(recipientAAAddr)
	console.log('\n=== Recipient AA (from card\'s aaFactory) ===')
	console.log('recipientAA:', recipientAAAddr)
	console.log('recipientAA has code:', recipientAACode !== '0x' && recipientAACode.length > 2)

	// 3. Signer isAdmin
	const cardAbi = new ethers.Interface(['function isAdmin(address) view returns (bool)'])
	const isAdminRes = await providerCallWithFallback(provider, providerFallback, {
		to: cardAddr as `0x${string}`,
		data: cardAbi.encodeFunctionData('isAdmin', [signer]) as `0x${string}`,
	})
	const isAdmin = cardAbi.decodeFunctionResult('isAdmin', isAdminRes)[0] as boolean
	console.log('\n=== Signer admin ===')
	console.log('signer isAdmin:', isAdmin)

	// 4. Nonce used
	const nonceKey = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(['address', 'address', 'bytes32'], [cardAddr, signer, nonce]))
	const factoryAbi = new ethers.Interface(['function usedAdminExecuteNonces(bytes32) view returns (bool)'])
	const nonceUsedRes = await providerCallWithFallback(provider, providerFallback, {
		to: BASE_CARD_FACTORY as `0x${string}`,
		data: factoryAbi.encodeFunctionData('usedAdminExecuteNonces', [nonceKey]) as `0x${string}`,
	})
	const nonceUsed = factoryAbi.decodeFunctionResult('usedAdminExecuteNonces', nonceUsedRes)[0] as boolean
	console.log('\n=== Nonce ===')
	console.log('nonceKey:', nonceKey)
	console.log('nonce already used:', nonceUsed)

	// 5. Card gateway
	const gatewayIface = new ethers.Interface(['function factoryGateway() view returns (address)'])
	const gatewayRes = await providerCallWithFallback(provider, providerFallback, {
		to: cardAddr as `0x${string}`,
		data: gatewayIface.encodeFunctionData('factoryGateway') as `0x${string}`,
	})
	const cardGateway = gatewayIface.decodeFunctionResult('factoryGateway', gatewayRes)[0] as string
	console.log('\n=== Card gateway ===')
	console.log('card.factoryGateway():', cardGateway)
	console.log('Expected (Card Factory):', BASE_CARD_FACTORY)
	console.log('Match:', cardGateway.toLowerCase() === BASE_CARD_FACTORY.toLowerCase())

	console.log('\n=== Summary ===')
	if (cardFactoryAaFactory.toLowerCase() !== BASE_AA_FACTORY.toLowerCase()) {
		console.log('❌ Card Factory _aaFactory 与 BASE_AA_FACTORY 不一致，需调用 setAAFactory 修正')
	}
	if (!(recipientAACode !== '0x' && recipientAACode.length > 2)) {
		console.log('❌ Recipient 在 card 的 aaFactory 下无有效 AA 账户 -> UC_ResolveAccountFailed')
	}
	if (!isAdmin) {
		console.log('❌ Signer 不是 card admin -> UC_NotAdmin')
	}
	if (nonceUsed) {
		console.log('❌ Nonce 已使用 -> UC_NonceUsed')
	}
	if (cardGateway.toLowerCase() !== BASE_CARD_FACTORY.toLowerCase()) {
		console.log('❌ Card gateway 与 Factory 不一致 -> BM_NotAuthorized')
	}
	if (
		cardFactoryAaFactory.toLowerCase() === BASE_AA_FACTORY.toLowerCase() &&
		recipientAACode !== '0x' &&
		recipientAACode.length > 2 &&
		isAdmin &&
		!nonceUsed &&
		cardGateway.toLowerCase() === BASE_CARD_FACTORY.toLowerCase()
	) {
		console.log('✅ 链上检查均通过，若仍失败请检查 deadline 或 RPC 状态')
	}
}

main().catch(console.error)
