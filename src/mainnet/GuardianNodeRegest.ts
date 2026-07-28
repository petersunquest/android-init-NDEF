

import GuardianNodesInfoV6ABI from "./abi/GuardianNodesInfoV6.json";
import { ethers } from "ethers"
import { createRequire } from "node:module"
import { join } from "node:path"
import { homedir } from "node:os"

const require = createRequire(import.meta.url)
const masterSetup = require(join(homedir(), ".master.json"))

const v1Address = "0xdE51f1daaCa6eae9BDeEe33E324c3e6e96837e94"
const newNodeAddress = "0x6d7a526BFD03E90ea8D19eDB986577395a139872"

const newProvider = new ethers.JsonRpcProvider("https://rpc1.conet.network")
const v1Provider = new ethers.JsonRpcProvider("http://38.102.126.30:80")
const masterWallet = new ethers.Wallet(masterSetup.settle_contractAdmin[0], newProvider)

const oldNodeContract = new ethers.Contract(v1Address, GuardianNodesInfoV6ABI, v1Provider)
const newNodeContract = new ethers.Contract(newNodeAddress, GuardianNodesInfoV6ABI, masterWallet)

/** 旧合约 getAllNodes 返回的 nodeInfo：id, PGP(base64), PGPKey, ip_addr, regionName */
type NodeFromContract = [bigint, string, string, string, string] | {
	id: bigint
	PGP: string
	PGPKey: string
	ip_addr: string
	regionName: string
}

const resiestNode = async (node: NodeFromContract) => {
	const id = Array.isArray(node) ? node[0] : node.id
	const pgpBase64 = Array.isArray(node) ? node[1] : node.PGP
	const pgpKey = Array.isArray(node) ? node[2] : node.PGPKey
	const ipaddress = Array.isArray(node) ? node[3] : node.ip_addr
	const regionName = Array.isArray(node) ? node[4] : node.regionName

	const owner = await oldNodeContract.idOwner(id)
	const tx = await newNodeContract.addNode(
		id,
		ipaddress,
		regionName,
		pgpBase64,
		pgpKey,
		owner
	)
	await tx.wait()
	return tx
}

/** 从旧合约拉取所有节点并迁移到新合约 */
const migrateAllNodes = async () => {
	const nodes = await oldNodeContract.getAllNodes(0, 1000)
	console.log(`从旧合约获取到 ${nodes.length} 个节点，开始迁移...`)
	for (let i = 0; i < nodes.length; i++) {
		const node = nodes[i]
		const id = Array.isArray(node) ? node[0] : node.id
		console.log(`[${i + 1}/${nodes.length}] 迁移节点 id=${id}...`)
		await resiestNode(node)
		console.log(`[${i + 1}/${nodes.length}] 完成`)
	}
	console.log(`迁移完成，共 ${nodes.length} 个节点`)
}

migrateAllNodes().catch(console.error)