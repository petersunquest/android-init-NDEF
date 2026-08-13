import { Contract, JsonRpcProvider, Wallet, isAddress } from 'ethers'
import { CONET_RPC } from '@/constants'
import { CONET_ADDRESS_PGP_MANAGER } from '@/conet/constants'
import { aesGcmDecrypt, fromBase64Utf8, normalizePrivateKeyHex } from '@/conet/crypto'

const ADDRESS_PGP_ABI = [
	'function searchKey(address account) view returns (string userPgpKeyID, string userPublicKeyArmored, string routePgpKeyID, string routePublicKeyArmored, bool routeOnline)',
	'function getEncryptedPrivateKey() view returns (string)',
] as const

export type AddressPgpKeyInfo = {
	privateArmored: string
	publicArmored: string
	routersArmoreds: string
	userPgpKeyID: string
	routePgpKeyID: string
}

/**
 * Read AddressPGP for wallet — mirrors bizSite `getKeysFromCoNETPGPSC`.
 * Decrypts encrypted private key with EOA private key (`0x…` password).
 */
export async function fetchAddressPgpKeys(
	walletPrivateKeyHex: string,
	lookupAddress?: string,
): Promise<AddressPgpKeyInfo | null> {
	const pk = normalizePrivateKeyHex(walletPrivateKeyHex)
	if (!pk) return null
	const provider = new JsonRpcProvider(CONET_RPC, 224422, { staticNetwork: true })
	let wallet: Wallet
	try {
		wallet = new Wallet(`0x${pk}`, provider)
	} catch {
		return null
	}
	const lookup =
		lookupAddress && isAddress(lookupAddress) ? lookupAddress : wallet.address
	const sc = new Contract(CONET_ADDRESS_PGP_MANAGER, ADDRESS_PGP_ABI, wallet)
	try {
		const [info, encPrivate] = await Promise.all([
			sc.searchKey(lookup) as Promise<{
				userPgpKeyID: string
				userPublicKeyArmored: string
				routePgpKeyID: string
				routePublicKeyArmored: string
				routeOnline: boolean
			}>,
			sc.getEncryptedPrivateKey() as Promise<string>,
		])
		let privateArmored = ''
		if (encPrivate) {
			try {
				privateArmored = await aesGcmDecrypt(encPrivate, wallet.privateKey)
			} catch {
				privateArmored = ''
			}
		}
		const publicArmored = info.userPublicKeyArmored
			? fromBase64Utf8(info.userPublicKeyArmored)
			: ''
		const routersArmoreds = info.routePublicKeyArmored
			? fromBase64Utf8(info.routePublicKeyArmored)
			: ''
		return {
			privateArmored,
			publicArmored,
			routersArmoreds,
			userPgpKeyID: String(info.userPgpKeyID ?? ''),
			routePgpKeyID: String(info.routePgpKeyID ?? ''),
		}
	} catch (ex) {
		console.warn('[fetchAddressPgpKeys]', ex instanceof Error ? ex.message : ex)
		return null
	}
}
