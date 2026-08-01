import { readBalanceFormatMoney } from '@/utils/readBalanceDisplay'
import { formatPosReceiptDate, shortTxHash, shortWalletAddr } from '@/utils/posReceiptUtils'

function formatMoneyLine(amount: string | number, currency: string): string {
	const num = typeof amount === 'number' ? amount : Number(amount)
	const parts = readBalanceFormatMoney(Number.isFinite(num) ? num : 0, currency)
	if (parts.prefix) return `${parts.prefix}${parts.mid}${parts.suffix}`
	return `${parts.mid}${parts.suffix}`
}

export function buildTopupReceiptPlainText(params: {
	amount: string
	postBalance: string
	cardCurrency: string
	dateStr?: string
	memberNo?: string
	address?: string
	txHash?: string
	settlementViaQr?: boolean
}): string {
	const currency = params.cardCurrency || 'CAD'
	const dateStr = params.dateStr ?? formatPosReceiptDate()
	const accountId =
		params.memberNo?.trim() ||
		shortWalletAddr(params.address) ||
		'—'
	const tx = params.txHash?.trim()
		? shortTxHash(params.txHash)
		: '—'
	const settlement = params.settlementViaQr ? 'App Validator' : 'NTAG 424 DNA'
	return [
		'TOP-UP COMPLETE',
		'',
		`Amount: ${formatMoneyLine(params.amount, currency)}`,
		`Card Balance: ${formatMoneyLine(params.postBalance, currency)}`,
		'',
		`Date: ${dateStr}`,
		`Account ID: ${accountId}`,
		`TX Hash: ${tx}`,
		'',
		`Settlement: ${settlement}`,
	].join('\n')
}

export function buildChargeReceiptPlainText(params: {
	amount: string
	postBalance: string
	cardCurrency: string
	subtotal?: string
	tip?: string
	dateStr?: string
	memberNo?: string
	payee?: string
	customerWalletAddress?: string
	txHash?: string
	settlementViaQr?: boolean
}): string {
	const currency = params.cardCurrency || 'CAD'
	const dateStr = params.dateStr ?? formatPosReceiptDate()
	const accountId =
		params.memberNo?.trim() ||
		shortWalletAddr(params.customerWalletAddress) ||
		shortWalletAddr(params.payee) ||
		'—'
	const tx = params.txHash?.trim()
		? shortTxHash(params.txHash)
		: '—'
	const settlement = params.settlementViaQr ? 'App Validator' : 'NTAG 424 DNA'
	const lines = [
		'PAYMENT APPROVED',
		'',
		`Amount: ${formatMoneyLine(params.amount, currency)}`,
		`Card Balance: ${formatMoneyLine(params.postBalance, currency)}`,
	]
	if (params.subtotal) {
		lines.push(`Subtotal: ${formatMoneyLine(params.subtotal, currency)}`)
	}
	if (params.tip && Number(params.tip) > 0) {
		lines.push(`Tip: ${formatMoneyLine(params.tip, currency)}`)
	}
	lines.push(
		'',
		`Date: ${dateStr}`,
		`Account ID: ${accountId}`,
		`TX Hash: ${tx}`,
		'',
		`Settlement: ${settlement}`,
	)
	return lines.join('\n')
}
