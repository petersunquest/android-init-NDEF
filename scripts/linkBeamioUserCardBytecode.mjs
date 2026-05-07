/**
 * 将 Hardhat 产物中 BeamioUserCard 的未链接 bytecode 按 linkReferences 填入库地址（与 solc linker 规则一致）。
 * 供 x402sdk / 无 Hardhat 环境生成 initCode 使用。
 */
import { getAddress, keccak256, toUtf8Bytes } from "ethers"

/**
 * @param {string} bytecode - 0x 前缀的 creation bytecode
 * @param {Record<string, Record<string, unknown[]>>} linkReferences - artifact.linkReferences
 * @param {Record<string, string>} libraryAddressesByName - 如 { BeamioUserCardFormattingLib: '0x...', BeamioUserCardTransferLib: '0x...' }
 * @returns {string}
 */
export function linkBeamioUserCardBytecode(bytecode, linkReferences, libraryAddressesByName) {
  let b = bytecode.startsWith("0x") ? bytecode.slice(2) : bytecode
  for (const [sourcePath, libs] of Object.entries(linkReferences || {})) {
    for (const libName of Object.keys(libs)) {
      const addr = libraryAddressesByName[libName]
      if (!addr) {
        throw new Error(`linkBeamioUserCardBytecode: missing library address for ${libName}`)
      }
      const fqn = `${sourcePath}:${libName}`
      const hash = keccak256(toUtf8Bytes(fqn))
      const placeholder = ("__$" + hash.slice(2, 36) + "$__").toLowerCase()
      const clean = getAddress(addr).slice(2).toLowerCase()
      if (clean.length !== 40) {
        throw new Error(`linkBeamioUserCardBytecode: invalid address for ${libName}`)
      }
      const parts = b.toLowerCase().split(placeholder)
      if (parts.length < 2) {
        throw new Error(`linkBeamioUserCardBytecode: placeholder not found for ${libName} (${fqn})`)
      }
      b = parts.join(clean)
    }
  }
  return "0x" + b
}
