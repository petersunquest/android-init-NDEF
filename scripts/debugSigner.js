/**
 * 从 executeForAdmin 交易 data 恢复 signer 地址（无需 RPC）
 * 用法: node scripts/debugSigner.js
 */
import { ethers } from 'ethers';

const data =
	'0xe83492d100000000000000000000000057052780925448ce1db7ac409ccccf13bcc4eb7100000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000699e1ec7a1f39f2dad9905bfb9d34840ea5c6795e07736f46fe6aae95880841035e44ccd00000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000000044564da7570000000000000000000000003fd6964e322ab2fe9cb4f5d0b9e5166eea9e4fe40000000000000000000000000000000000000000000000000000000000b71afa000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000041a0496595b273a4d62b7e0b310f61cb7b809680ae44ce3ed159f80f1480a2683a53b163c436458174db03083c26d42e5515758ad3858796ebeafc56029c4a1ff01c00000000000000000000000000000000000000000000000000000000000000';

const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
	['address', 'bytes', 'uint256', 'bytes32', 'bytes'],
	'0x' + data.slice(10)
);
const cardAddr = decoded[0];
const innerData = decoded[1];
const deadline = decoded[2];
const nonce = decoded[3];
const adminSig = decoded[4];

const dataHash = ethers.keccak256(innerData);
const domain = {
	name: 'BeamioUserCardFactory',
	version: '1',
	chainId: 8453,
	verifyingContract: '0xbDC8a165820bB8FA23f5d953632409F73E804eE5',
};
const types = {
	ExecuteForAdmin: [
		{ name: 'cardAddress', type: 'address' },
		{ name: 'dataHash', type: 'bytes32' },
		{ name: 'deadline', type: 'uint256' },
		{ name: 'nonce', type: 'bytes32' },
	],
};
const message = { cardAddress: cardAddr, dataHash, deadline, nonce };
const digest = ethers.TypedDataEncoder.hash(domain, types, message);
const signer = ethers.recoverAddress(digest, adminSig);

// 解析 innerData: mintPointsByAdmin(recipient, points6)
const mintIface = new ethers.Interface(['function mintPointsByAdmin(address user, uint256 points6)']);
const inner = mintIface.parseTransaction({ data: innerData });
const recipient = inner?.args[0];
const points6 = inner?.args[1];

console.log('=== Recovered from executeForAdmin data ===');
console.log('cardAddr:', cardAddr);
console.log('signer:', signer);
console.log('recipient:', recipient);
console.log('points6:', points6?.toString());
console.log('deadline:', deadline.toString(), '(block.timestamp 需 < deadline)');
console.log('nonce:', nonce);
console.log('\n链上检查命令:');
console.log('  cast call', cardAddr, '"isAdmin(address)(bool)"', signer, '--rpc-url https://base-rpc.conet.network');
