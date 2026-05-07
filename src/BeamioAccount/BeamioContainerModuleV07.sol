// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// BeamioContainerModuleV07.sol — container relay / open / redeem / reserve / pool; events + CM_/RD_/FP_/RS_ errors.
// Open relay: digest binds (account,currencyType,maxAmount,nonce,deadline) only. maxAmount>0 ⇒ valuatable USDC + factory card #0.
// Open USDC topup path: mixed USDC + card #0 items; USDC→card owner, mint via executor, then transfer basePoints+mint to pointsTo.

import "./BeamioTypesV07.sol";
import "./BeamioContainerStorageV07.sol";
import "./BeamioContainerItemTypesV07.sol";
import "./BeamioContainerModuleErrorsV07.sol";
import { BeamioContainerModuleExternalLibV07 as CExtLib } from "./BeamioContainerModuleExternalLibV07.sol";
import { BeamioContainerModuleExternalLib2V07 as CExtLib2 } from "./BeamioContainerModuleExternalLib2V07.sol";
import "../contracts/utils/cryptography/ECDSA.sol";
import "../contracts/utils/cryptography/MessageHashUtils.sol";

interface IBeamioAccountFactoryConfigV2 {
	function quoteHelper() external view returns (address);
	function beamioUserCard() external view returns (address);
	function USDC() external view returns (address);
	function openContainerMintExecutor() external view returns (address);
	function isBeamioAccount(address account) external view returns (bool);
}

interface IOwnableMinimal {
	function owner() external view returns (address);
}

interface IBeamioOpenContainerMintExecutorLike {
	function mintPointsForOpen(address userCard, uint256 points6, address operator) external;
}

interface IBeamioQuoteHelperV07Like {
	function quoteCurrencyAmountInUSDC6(uint8 cur, uint256 amount6) external view returns (uint256);
}

contract BeamioContainerModuleV07 {
	using ECDSA for bytes32;
	using MessageHashUtils for bytes32;

	// ========= Events (ONLY here) =========
	event ContainerRelayed(address indexed to, bytes32 indexed itemsHash, uint256 nonce, uint256 deadline);

	event RedeemCreated(bytes32 indexed passwordHash, bytes32 indexed itemsHash, uint64 expiry, address presetTo);
	event RedeemCancelled(bytes32 indexed passwordHash);
	event Redeemed(bytes32 indexed passwordHash, address indexed to);

	event FaucetPoolCreated(bytes32 indexed passwordHash, bytes32 indexed itemsHash, uint32 totalCount, uint64 expiry);
	event FaucetPoolCancelled(bytes32 indexed passwordHash);
	event FaucetClaimed(bytes32 indexed passwordHash, address indexed claimer, address indexed to, uint32 remaining);

	event ReserveCreated(uint256 indexed reserveId, address indexed beneficiary, bytes32 itemsHash, uint64 cancelDeadline);
	event ReserveCancelled(uint256 indexed reserveId, address indexed beneficiary, uint256 index);
	event ReserveApprovedEvt(uint256 indexed reserveId, address indexed beneficiary, uint256 index);
	event ReserveTransferred(uint256 indexed reserveId, address indexed beneficiary, uint256 index);

	event ContainerOpenUsdcTopupThenPoints(
		address indexed pointsTo,
		address indexed userCard,
		uint256 usdc6,
		uint256 topupPoints6,
		uint256 basePoints6,
		uint256 nonce,
		uint256 deadline
	);

	// ========= onlyDelegatecall =========
	address private immutable SELF;

	constructor() {
		SELF = address(this);
	}

	modifier onlyDelegatecall() {
		if (address(this) == SELF) revert CM_OnlyDelegatecall();
		_;
	}

	// ========= EIP-712 =========
	bytes32 private constant DOMAIN_TYPEHASH =
		keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
	bytes32 private constant NAME_HASH = keccak256(bytes("BeamioAccount"));
	bytes32 private constant VERSION_HASH = keccak256(bytes("1"));

	// ========= Context helpers (delegatecall or staticcall facade) =========
	function _ctxAccount() internal view returns (address acct) {
		// staticcall facade path: Account.staticDelegate 调用时，calldata 末尾 20 字节为 account 地址
		if (
			msg.sig == this.simulateOpenContainer.selector ||
			msg.sig == this.simulateOpenContainerUsdcTopupThenPoints.selector ||
			msg.sig == this.relayedNonce.selector ||
			msg.sig == this.openRelayedNonce.selector
		) {
			if (msg.data.length >= 20) {
				address a;
				assembly {
					a := shr(96, calldataload(sub(calldatasize(), 20)))
				}
				return a;
			}
		}

		// delegatecall path: address(this) 即 account
		return address(this);
	}

	function _owner(address acct) internal view returns (address o) {
		(bool ok, bytes memory ret) = acct.staticcall(abi.encodeWithSignature("owner()"));
		if (!ok || ret.length != 32) revert NotAuthorized();
		return abi.decode(ret, (address));
	}

	/// @notice 用于 simulateOpenContainer，不 revert，失败时返回 (address(0), false)
	function _ownerSafe(address acct) internal view returns (address o, bool ok) {
		(bool success, bytes memory ret) = acct.staticcall(abi.encodeWithSignature("owner()"));
		if (!success || ret.length != 32) return (address(0), false);
		return (abi.decode(ret, (address)), true);
	}

	function _factory(address acct) internal view returns (address f) {
		(bool ok, bytes memory ret) = acct.staticcall(abi.encodeWithSignature("factory()"));
		if (!ok || ret.length != 32) revert CM_NoFactory();
		return abi.decode(ret, (address));
	}

	/// @notice 用于 simulateOpenContainer，不 revert，失败时返回 (address(0), false)
	function _factorySafe(address acct) internal view returns (address f, bool ok) {
		(bool success, bytes memory ret) = acct.staticcall(abi.encodeWithSignature("factory()"));
		if (!success || ret.length != 32) return (address(0), false);
		return (abi.decode(ret, (address)), true);
	}

	function _requireMsgSenderIsOwner(address acct) internal view {
		address o = _owner(acct);
		if (msg.sender != o) revert RS_NotOwner(msg.sender, o);
	}

	function _reserveStatusLabel(uint8 st) internal pure returns (string memory) {
		if (st == 0) return "Pending";
		if (st == 1) return "ReserveApproved";
		if (st == 2) return "Completed";
		if (st == 3) return "Cancelled";
		return "Unknown";
	}

	function domainSeparator(address acct) public view returns (bytes32) {
		return keccak256(
			abi.encode(
				DOMAIN_TYPEHASH,
				NAME_HASH,
				VERSION_HASH,
				block.chainid,
				acct
			)
		);
	}

	// ========= Hashing (delegate to linked library) =========
	function hashItem(ContainerItem calldata it) public pure returns (bytes32) {
		return CExtLib.hashItem(it);
	}

	function hashItems(ContainerItem[] calldata items) public pure returns (bytes32 itemsHash) {
		return CExtLib.hashItems(items);
	}

	function _hashContainerMessage(
		address acct,
		address to,
		bytes32 itemsHash_,
		uint256 nonce_,
		uint256 deadline_
	) internal view returns (bytes32) {
		return CExtLib.hashContainerMessage(domainSeparator(acct), acct, to, itemsHash_, nonce_, deadline_);
	}

	function _hashOpenContainerMessage(
		address acct,
		uint8 currencyType,
		uint256 maxAmount,
		uint256 nonce_,
		uint256 deadline_
	) internal view returns (bytes32) {
		return CExtLib.hashOpenContainerMessage(domainSeparator(acct), acct, currencyType, maxAmount, nonce_, deadline_);
	}

	function _factoryLoadValuatableTokens(address acct)
		internal
		view
		returns (address f, address helperAddr, address usdc, address userCard)
	{
		f = _factory(acct);
		helperAddr = IBeamioAccountFactoryConfigV2(f).quoteHelper();
		usdc = IBeamioAccountFactoryConfigV2(f).USDC();
		userCard = IBeamioAccountFactoryConfigV2(f).beamioUserCard();
		if (helperAddr == address(0) || helperAddr.code.length == 0) revert CM_NoQuoteHelper();
		if (usdc == address(0)) revert CM_NoUSDC();
		if (userCard == address(0) || userCard.code.length == 0) revert CM_NoUserCard();
	}

	function _openRelayPreamble(
		BeamioContainerStorageV07.Layout storage l,
		uint256 deadline_,
		uint256 nonce_,
		bytes calldata sig,
		ContainerItem[] calldata items
	) internal view {
		if (block.timestamp > deadline_) revert CM_Expired(block.timestamp, deadline_);
		if (nonce_ != l.openRelayedNonce) revert CM_BadNonce(nonce_, l.openRelayedNonce);
		if (sig.length != 65) revert CM_BadSigLen(sig.length);
		if (items.length == 0) revert CM_EmptyItems();
	}

	// ========= Views (nonce) =========
	function relayedNonce() external view returns (uint256) {
		address acct = _ctxAccount();
		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();
		acct;
		return l.relayedNonce;
	}

	function openRelayedNonce() external view returns (uint256) {
		address acct = _ctxAccount();
		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();
		acct;
		return l.openRelayedNonce;
	}

	// ========= Reserved accounting =========
	function _reserveAdd(ContainerItem[] memory items) internal {
		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();

		for (uint256 i = 0; i < items.length; i++) {
			ContainerItem memory it = items[i];
			if (it.amount == 0) continue;

			if (it.kind == AssetKind.ERC20) {
				l.reservedErc20[it.asset] += it.amount;
			} else if (it.kind == AssetKind.ERC1155) {
				l.reserved1155[it.asset][it.tokenId] += it.amount;
			} else {
				revert CM_UnsupportedKind(i);
			}
		}
	}

	function _reserveSub(ContainerItem[] memory items) internal {
		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();

		for (uint256 i = 0; i < items.length; i++) {
			ContainerItem memory it = items[i];
			if (it.amount == 0) continue;

			if (it.kind == AssetKind.ERC20) {
				l.reservedErc20[it.asset] -= it.amount;
			} else if (it.kind == AssetKind.ERC1155) {
				l.reserved1155[it.asset][it.tokenId] -= it.amount;
			} else {
				revert CM_UnsupportedKind(i);
			}
		}
	}

	function _requireSpendableOne(
		address acct,
		BeamioContainerStorageV07.Layout storage l,
		AssetKind kind,
		address asset,
		uint256 amount,
		uint256 tokenId,
		uint256 errIdx
	) internal view {
		if (amount == 0) return;
		if (kind == AssetKind.ERC20) {
			uint256 bal = IERC20Like(asset).balanceOf(acct);
			uint256 r = l.reservedErc20[asset];
			if (bal < r + amount) revert CM_ReservedERC20Violation(asset, amount, bal, r);
			return;
		}
		if (kind == AssetKind.ERC1155) {
			uint256 bal = IERC1155Like(asset).balanceOf(acct, tokenId);
			uint256 r2 = l.reserved1155[asset][tokenId];
			if (bal < r2 + amount) revert CM_Reserved1155Violation(asset, tokenId, amount, bal, r2);
			return;
		}
		revert CM_UnsupportedKind(errIdx);
	}

	function _checkSpendable(address acct, ContainerItem[] calldata items) internal view {
		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();
		for (uint256 i = 0; i < items.length; i++) {
			ContainerItem calldata it = items[i];
			_requireSpendableOne(acct, l, it.kind, it.asset, it.amount, it.tokenId, i);
		}
	}

	function _checkSpendableMem(address acct, ContainerItem[] memory items) internal view {
		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();
		for (uint256 i = 0; i < items.length; i++) {
			ContainerItem memory it = items[i];
			_requireSpendableOne(acct, l, it.kind, it.asset, it.amount, it.tokenId, i);
		}
	}

	/// @notice 用于 simulateOpenContainer，不 revert，失败时返回 (false, reason)
	function _checkSpendableSafe(address acct, ContainerItem[] calldata items) internal view returns (bool ok, string memory reason) {
		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();

		for (uint256 i = 0; i < items.length; i++) {
			ContainerItem calldata it = items[i];
			if (it.amount == 0) continue;

			if (it.kind == AssetKind.ERC20) {
				try IERC20Like(it.asset).balanceOf(acct) returns (uint256 bal) {
					uint256 r = l.reservedErc20[it.asset];
					if (bal < r + it.amount) return (false, "reserved erc20");
				} catch {
					return (false, "balanceOf failed");
				}
			} else if (it.kind == AssetKind.ERC1155) {
				try IERC1155Like(it.asset).balanceOf(acct, it.tokenId) returns (uint256 bal) {
					uint256 r2 = l.reserved1155[it.asset][it.tokenId];
					if (bal < r2 + it.amount) return (false, "reserved 1155");
				} catch {
					return (false, "balanceOf1155 failed");
				}
			} else {
				return (false, "unsupported kind");
			}
		}
		return (true, "");
	}

	/// @notice 在 Account.execute / executeBatch 前调用，校验即将执行的外部调用是否会转出被 reserve 锁定的资产。若会违反 reserve 则 revert。
	/// @dev 仅校验 ERC20 transfer、transferFrom(from==account)、ERC1155 safeTransferFrom/safeBatchTransferFrom(from==account)。其他调用放行。
	function preExecuteCheck(address dest, uint256 /* value */, bytes calldata func) external view {
		CExtLib2.preExecuteCheck(BeamioContainerStorageV07.layout(), address(this), dest, func);
	}

	function _containerMain(address to, ContainerItem[] calldata items) internal {
		ContainerItem[] memory m = new ContainerItem[](items.length);
		for (uint256 i = 0; i < items.length; i++) {
			m[i] = items[i];
		}
		CExtLib2.containerMainMem(to, m);
	}

	// =========================================================
	// (A) to-bound owner relayed container (nonce in module layout)
	// =========================================================
	function containerMainRelayed(
		address to,
		ContainerItem[] calldata items,
		uint256 nonce_,
		uint256 deadline_,
		bytes calldata sig
	) external onlyDelegatecall {
		address acct = address(this);
		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();

		if (block.timestamp > deadline_) revert CM_Expired(block.timestamp, deadline_);
		if (nonce_ != l.relayedNonce) revert CM_BadNonce(nonce_, l.relayedNonce);
		if (sig.length != 65) revert CM_BadSigLen(sig.length);

		bytes32 itemsHash_ = hashItems(items);
		bytes32 digest = _hashContainerMessage(acct, to, itemsHash_, nonce_, deadline_);
		address signer = ECDSA.recover(digest, sig);
		address o = _owner(acct);
		if (signer != o) revert CM_SignerNotOwner(signer, o);

		_checkSpendable(acct, items);

		l.relayedNonce = nonce_ + 1;

		_containerMain(to, items);

		emit ContainerRelayed(to, itemsHash_, nonce_, deadline_);
	}

	// =========================================================
	// (B) open relayed (signature does NOT bind to/items/token)
	// =========================================================
	function containerMainRelayedOpen(
		address to,
		ContainerItem[] calldata items,
		uint8 currencyType,
		uint256 maxAmount,   // 0 => unlimited; >0 时必须 E6 精度，如 10*1e6 表示 10 单位
		uint256 nonce_,
		uint256 deadline_,
		bytes calldata sig
	) external onlyDelegatecall {
		address acct = address(this);
		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();

		if (to == address(0)) revert CM_ToZero();
		_openRelayPreamble(l, deadline_, nonce_, sig, items);

		_checkSpendable(acct, items);

		address helperAddr;
		address usdc;
		address userCard;
		if (maxAmount > 0) {
			if (maxAmount < 1e4) revert CM_MaxAmountTooSmall(maxAmount);
			(, helperAddr, usdc, userCard) = _factoryLoadValuatableTokens(acct);
		}

		(uint256 totalUsdc6, uint256 cardPoints6) = CExtLib.scanOpenItemsForRelay(items, maxAmount > 0, usdc, userCard);
		CExtLib.enforceOpenMaxBudget(maxAmount, helperAddr, userCard, currencyType, totalUsdc6, cardPoints6);

		// signature binds only budget fields (NOT to/items/token)
		bytes32 digest = _hashOpenContainerMessage(acct, currencyType, maxAmount, nonce_, deadline_);
		address signer = ECDSA.recover(digest, sig);
		address o2 = _owner(acct);
		if (signer != o2) revert CM_SignerNotOwner(signer, o2);

		l.openRelayedNonce = nonce_ + 1;

		_containerMain(to, items);

		emit ContainerRelayed(to, bytes32(0), nonce_, deadline_);
	}

	// =========================================================
	// (C) open relayed: USDC → UserCard.owner（topup 收款），再经 executor mint points，最后转出 basePoints + mint 量
	// =========================================================
	function containerMainRelayedOpenUsdcTopupThenPoints(
		address pointsTo,
		ContainerItem[] calldata items,
		uint8 currencyType,
		uint256 maxAmount,
		uint256 nonce_,
		uint256 deadline_,
		bytes calldata sig
	) external onlyDelegatecall {
		address acct = address(this);
		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();

		if (pointsTo == address(0)) revert CM_ToZero();
		_openRelayPreamble(l, deadline_, nonce_, sig, items);

		(address f, address helperAddr, address usdc, address userCard) = _factoryLoadValuatableTokens(acct);

		if (maxAmount > 0) {
			if (maxAmount < 1e4) revert CM_MaxAmountTooSmall(maxAmount);
		}

		(ContainerItem[] memory usdcItems, uint256 totalUsdc6, uint256 basePoints6, bytes memory data1155) =
			CExtLib.parseAndValidateOpenTopupItems(items, usdc, userCard);

		_checkSpendable(acct, items);

		CExtLib.enforceOpenMaxBudget(maxAmount, helperAddr, userCard, currencyType, totalUsdc6, basePoints6);

		bytes32 digest = _hashOpenContainerMessage(acct, currencyType, maxAmount, nonce_, deadline_);
		address signer = ECDSA.recover(digest, sig);
		address o2 = _owner(acct);
		if (signer != o2) revert CM_SignerNotOwner(signer, o2);

		uint256 topupPoints6 = CExtLib.usdc6ToTopupPoints6(totalUsdc6, userCard, helperAddr);
		if (basePoints6 + topupPoints6 == 0) revert CM_OpenTopupZeroOut();

		l.openRelayedNonce = nonce_ + 1;

		address cardOwner = IOwnableMinimal(userCard).owner();
		if (totalUsdc6 > 0) {
			CExtLib2.containerERC20(cardOwner, usdcItems);
		}

		if (topupPoints6 > 0) {
			address exec = IBeamioAccountFactoryConfigV2(f).openContainerMintExecutor();
			if (exec == address(0)) revert CM_OpenTopupNoExecutor();
			IBeamioOpenContainerMintExecutorLike(exec).mintPointsForOpen(userCard, topupPoints6, cardOwner);
		}

		ContainerItem[] memory out1155 = new ContainerItem[](1);
		out1155[0] = ContainerItem({
			kind: AssetKind.ERC1155,
			asset: userCard,
			amount: basePoints6 + topupPoints6,
			tokenId: 0,
			data: data1155
		});

		_checkSpendableMem(acct, out1155);

		CExtLib2.containerMainMem(pointsTo, out1155);

		emit ContainerOpenUsdcTopupThenPoints(pointsTo, userCard, totalUsdc6, topupPoints6, basePoints6, nonce_, deadline_);
		emit ContainerRelayed(pointsTo, bytes32(0), nonce_, deadline_);
	}

	function simulateOpenContainerUsdcTopupThenPoints(
		address pointsTo,
		ContainerItem[] calldata items,
		uint8 currencyType,
		uint256 maxAmount,
		uint256 nonce_,
		uint256 deadline_,
		bytes calldata sig
	) external view returns (bool ok, string memory reason) {
		address acct = _ctxAccount();
		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();

		if (pointsTo == address(0)) return (false, "pointsTo=0");
		if (block.timestamp > deadline_) return (false, "expired");
		if (nonce_ != l.openRelayedNonce) return (false, "bad nonce");
		if (sig.length != 65) return (false, "bad sig len");
		if (items.length == 0) return (false, "empty items");

		(bool spendOk, string memory spendReason) = _checkSpendableSafe(acct, items);
		if (!spendOk) return (false, spendReason);

		(address f, bool factoryOk) = _factorySafe(acct);
		if (!factoryOk) return (false, "no factory");
		address helperAddr = IBeamioAccountFactoryConfigV2(f).quoteHelper();
		address usdc = IBeamioAccountFactoryConfigV2(f).USDC();
		address userCard = IBeamioAccountFactoryConfigV2(f).beamioUserCard();

		if (helperAddr == address(0) || helperAddr.code.length == 0) return (false, "no helper");
		if (usdc == address(0)) return (false, "no usdc");
		if (userCard == address(0) || userCard.code.length == 0) return (false, "no usercard");

		if (maxAmount > 0) {
			if (maxAmount < 1e4) return (false, "max amount too small");
		}

		uint256 n = items.length;
		uint256 n20;
		uint256 n1155;
		for (uint256 i = 0; i < n; i++) {
			ContainerItem calldata it = items[i];
			if (it.kind == AssetKind.ERC20) n20++;
			else if (it.kind == AssetKind.ERC1155) n1155++;
			else return (false, "open topup not mixed");
		}
		if (n20 == 0 || n1155 == 0) return (false, "open topup not mixed");

		uint256 totalUsdc6 = 0;
		uint256 basePoints6 = 0;
		for (uint256 i = 0; i < n; i++) {
			ContainerItem calldata it = items[i];
			if (it.kind == AssetKind.ERC20) {
				if (it.asset == address(0)) return (false, "item asset=0");
				if (it.asset != usdc) return (false, "erc20 not usdc");
				if (it.tokenId != 0 || it.data.length != 0) return (false, "erc20 has tokenId/data");
				totalUsdc6 += it.amount;
			} else {
				if (it.asset == address(0)) return (false, "item asset=0");
				if (it.asset != userCard) return (false, "1155 not usercard");
				if (it.tokenId != 0) return (false, "erc1155 tokenId!=0");
				basePoints6 += it.amount;
			}
		}

		bool needUnit = (maxAmount > 0 && basePoints6 > 0) || (totalUsdc6 > 0);
		uint256 unitPu;
		if (needUnit) {
			(bool upOk, uint256 u) = CExtLib.simTryUnitPointUsdc6(userCard, helperAddr);
			if (!upOk) return (false, "unit point");
			unitPu = u;
		}

		if (maxAmount > 0) {
			IBeamioQuoteHelperV07Like qh = IBeamioQuoteHelperV07Like(helperAddr);
			uint256 maxUsdc6 = qh.quoteCurrencyAmountInUSDC6(currencyType, maxAmount);
			uint256 cardValueUsdc6 = (basePoints6 > 0) ? (basePoints6 * unitPu) / 1e6 : 0;
			if (totalUsdc6 + cardValueUsdc6 > maxUsdc6) return (false, "exceeds max");
		}

		uint256 topupPoints6 = (totalUsdc6 > 0) ? ((totalUsdc6 * 1e6) / unitPu) : 0;

		if (basePoints6 + topupPoints6 == 0) return (false, "zero out");

		if (topupPoints6 > 0) {
			address exec = IBeamioAccountFactoryConfigV2(f).openContainerMintExecutor();
			if (exec == address(0)) return (false, "no open mint executor");
		}

		bytes32 digest = _hashOpenContainerMessage(acct, currencyType, maxAmount, nonce_, deadline_);
		address signer = ECDSA.recover(digest, sig);
		(address o2, bool ownerOk) = _ownerSafe(acct);
		if (!ownerOk) return (false, "owner call failed");
		if (signer != o2) return (false, "sig not owner");

		return (true, "ok");
	}

	// =========================================================
	// View-only simulation (staticcall facade)
	// =========================================================
	function simulateOpenContainer(
		address to,
		ContainerItem[] calldata items,
		uint8 currencyType,
		uint256 maxAmount,
		uint256 nonce_,
		uint256 deadline_,
		bytes calldata sig
	) external view returns (bool ok, string memory reason) {
		address acct = _ctxAccount();
		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();

		if (to == address(0)) return (false, "to=0");
		if (block.timestamp > deadline_) return (false, "expired");
		if (nonce_ != l.openRelayedNonce) return (false, "bad nonce");
		if (sig.length != 65) return (false, "bad sig len");
		if (items.length == 0) return (false, "empty items");

		(bool spendOk, string memory spendReason) = _checkSpendableSafe(acct, items);
		if (!spendOk) return (false, spendReason);
		address usdc = address(0);
		address userCard = address(0);
		address helperAddr = address(0);

		if (maxAmount > 0) {
			if (maxAmount < 1e4) return (false, "max amount too small");
			(address f, bool factoryOk) = _factorySafe(acct);
			if (!factoryOk) return (false, "no factory");
			helperAddr = IBeamioAccountFactoryConfigV2(f).quoteHelper();
			usdc = IBeamioAccountFactoryConfigV2(f).USDC();
			userCard = IBeamioAccountFactoryConfigV2(f).beamioUserCard();

			if (helperAddr == address(0) || helperAddr.code.length == 0) return (false, "no helper");
			if (usdc == address(0)) return (false, "no usdc");
			if (userCard == address(0) || userCard.code.length == 0) return (false, "no usercard");
		}

		uint256 totalUsdc6 = 0;
		uint256 cardPoints6 = 0;

		for (uint256 i = 0; i < items.length; i++) {
			ContainerItem calldata it = items[i];
			if (it.asset == address(0)) return (false, "item asset=0");

			if (it.kind == AssetKind.ERC20) {
				if (it.tokenId != 0 || it.data.length != 0) return (false, "erc20 has tokenId/data");

				if (maxAmount > 0) {
					if (it.asset != usdc) return (false, "erc20 not usdc");
					totalUsdc6 += it.amount;
				}
				continue;
			}

			if (it.kind == AssetKind.ERC1155) {
				if (maxAmount > 0) {
					if (it.asset != userCard) return (false, "1155 not usercard");
					if (it.tokenId != 0) return (false, "erc1155 tokenId!=0");
					cardPoints6 += it.amount;
				}
				continue;
			}

			return (false, "unsupported kind");
		}

		uint256 unitPu;
		if (maxAmount > 0 && cardPoints6 > 0) {
			(bool upOk, uint256 u) = CExtLib.simTryUnitPointUsdc6(userCard, helperAddr);
			if (!upOk) return (false, "unit point");
			unitPu = u;
		}

		if (maxAmount > 0) {
			IBeamioQuoteHelperV07Like qh = IBeamioQuoteHelperV07Like(helperAddr);
			uint256 maxUsdc6 = qh.quoteCurrencyAmountInUSDC6(currencyType, maxAmount);
			uint256 cardValueUsdc6 = (cardPoints6 > 0) ? (cardPoints6 * unitPu) / 1e6 : 0;
			if (totalUsdc6 + cardValueUsdc6 > maxUsdc6) return (false, "exceeds max");
		}

		bytes32 digest = _hashOpenContainerMessage(acct, currencyType, maxAmount, nonce_, deadline_);
		address signer = ECDSA.recover(digest, sig);
		(address o2, bool ownerOk) = _ownerSafe(acct);
		if (!ownerOk) return (false, "owner call failed");
		if (signer != o2) return (false, "sig not owner");

		return (true, "ok");
	}

	// =========================================================
	// Redeem (single-use password) with freeze / cancel
	// =========================================================
	function createRedeem(
		bytes32 passwordHash,
		address to,
		ContainerItem[] calldata items,
		uint64 expiry
	) external onlyDelegatecall {
		if (passwordHash == bytes32(0)) revert RD_ZeroPasswordHash();

		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();
		BeamioContainerStorageV07.Redeem storage r = l.redeems[passwordHash];
		if (r.active) revert RD_AlreadyExists(passwordHash);

		if (items.length == 0) revert CM_EmptyItems();

		bytes memory enc = abi.encode(items);
		bytes32 ih = hashItems(items);

		ContainerItem[] memory memItems = abi.decode(enc, (ContainerItem[]));
		_reserveAdd(memItems);

		r.active = true;
		r.used = false;
		r.expiry = expiry;
		r.presetTo = to;
		r.itemsHash = ih;
		r.itemsData = enc;

		emit RedeemCreated(passwordHash, ih, expiry, to);
	}

	function cancelRedeem(string calldata code) external onlyDelegatecall {
		bytes32 ph = keccak256(bytes(code));
		if (ph == bytes32(0)) revert RD_BadPassword();

		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();
		BeamioContainerStorageV07.Redeem storage r = l.redeems[ph];
		if (!r.active) revert RD_NotFound(ph);
		if (r.used) revert RD_AlreadyUsed(ph);

		ContainerItem[] memory items = abi.decode(r.itemsData, (ContainerItem[]));
		_reserveSub(items);

		delete l.redeems[ph];

		emit RedeemCancelled(ph);
	}

	function redeem(string calldata password, address to) external onlyDelegatecall {
		if (to == address(0)) revert CM_ToZero();
		bytes32 ph = keccak256(bytes(password));
		if (ph == bytes32(0)) revert RD_BadPassword();

		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();
		BeamioContainerStorageV07.Redeem storage r = l.redeems[ph];
		if (!r.active) revert RD_NotFound(ph);
		if (r.used) revert RD_AlreadyUsed(ph);

		if (r.presetTo != address(0) && to != r.presetTo) revert RD_PresetToMismatch(to, r.presetTo);

		if (r.expiry != 0 && block.timestamp > r.expiry) revert RD_Expired(ph);

		ContainerItem[] memory items = abi.decode(r.itemsData, (ContainerItem[]));
		_reserveSub(items);

		r.used = true;
		r.active = false;

		CExtLib2.containerMainMem(to, items);

		delete l.redeems[ph];

		emit Redeemed(ph, to);
	}

	// =========================================================
	// Faucet pool (password may leak; many uses; per-wallet once)
	// =========================================================
	function createFaucetPool(
		bytes32 passwordHash,
		uint32 totalCount,
		uint64 expiry,
		ContainerItem[] calldata items
	) external onlyDelegatecall {
		if (passwordHash == bytes32(0)) revert FP_ZeroPasswordHash();
		if (totalCount == 0) revert FP_InvalidTotalCount();
		if (items.length == 0) revert CM_EmptyItems();

		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();
		BeamioContainerStorageV07.Pool storage p = l.pools[passwordHash];
		if (p.active) revert FP_AlreadyExists(passwordHash);

		bytes memory enc = abi.encode(items);
		bytes32 ih = hashItems(items);

		ContainerItem[] memory memItems = abi.decode(enc, (ContainerItem[]));
		for (uint256 i = 0; i < memItems.length; i++) {
			if (memItems[i].amount == 0) continue;
			memItems[i].amount = memItems[i].amount * uint256(totalCount);
		}
		_reserveAdd(memItems);

		p.active = true;
		p.expiry = expiry;
		p.remaining = totalCount;
		p.itemsHash = ih;
		p.itemsData = enc;

		emit FaucetPoolCreated(passwordHash, ih, totalCount, expiry);
	}

	function cancelFaucetPool(string calldata code) external onlyDelegatecall {
		if (bytes(code).length == 0) revert FP_ZeroPasswordHash();
		bytes32 ph = keccak256(bytes(code));

		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();
		BeamioContainerStorageV07.Pool storage p = l.pools[ph];
		if (!p.active) revert FP_NotFound(ph);

		ContainerItem[] memory baseItems = abi.decode(p.itemsData, (ContainerItem[]));
		ContainerItem[] memory scaled = new ContainerItem[](baseItems.length);
		for (uint256 i = 0; i < baseItems.length; i++) {
			scaled[i] = baseItems[i];
			if (scaled[i].amount != 0) {
				scaled[i].amount = scaled[i].amount * uint256(p.remaining);
			}
		}
		_reserveSub(scaled);

		delete l.pools[ph];

		emit FaucetPoolCancelled(ph);
	}

	function faucetRedeemPool(
		string calldata password,
		address claimer,
		address to,
		ContainerItem[] calldata items
	) external onlyDelegatecall {
		if (claimer == address(0)) revert ZeroAddress();
		if (to == address(0)) revert CM_ToZero();
		if (to != claimer) revert FP_ToMustEqualClaimer(); // 禁止代领到第三方

		bytes32 ph = keccak256(bytes(password));
		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();
		BeamioContainerStorageV07.Pool storage p = l.pools[ph];

		if (!p.active) revert FP_NotFound(ph);
		if (p.expiry != 0 && block.timestamp > p.expiry) revert FP_Expired(ph);
		if (p.remaining == 0) revert FP_OutOfStock(ph);
		if (l.poolClaimed[ph][to]) revert FP_AlreadyClaimed(ph, to); // 记录 to，每个地址仅可领取一次

		bytes32 ih = hashItems(items);
		if (ih != p.itemsHash) revert FP_ItemsMismatch();

		ContainerItem[] memory baseItems = abi.decode(p.itemsData, (ContainerItem[]));
		_reserveSub(baseItems);

		l.poolClaimed[ph][to] = true;
		p.remaining -= 1;

		_containerMain(to, items);

		emit FaucetClaimed(ph, claimer, to, p.remaining);

		if (p.remaining == 0) {
			delete l.pools[ph];
		}
	}

	// =========================================================
	// Reserve: owner locks container for beneficiary; time-bounded cancel; beneficiary approves then public transfer
	// =========================================================
	function createReserve(
		ContainerItem[] calldata items,
		address beneficiary,
		uint32 cancelWindowSeconds
	) external onlyDelegatecall {
		address acct = address(this);
		if (beneficiary == address(0)) revert RS_BeneficiaryZero();
		if (cancelWindowSeconds == 0) revert RS_CancelWindowZero();
		if (items.length == 0) revert CM_EmptyItems();

		uint256 dl = uint256(block.timestamp) + uint256(cancelWindowSeconds);
		if (dl > type(uint64).max) revert RS_CancelWindowTooLong();

		_requireMsgSenderIsOwner(acct);
		_checkSpendable(acct, items);

		bytes memory enc = abi.encode(items);
		bytes32 ih = hashItems(items);

		ContainerItem[] memory memItems = abi.decode(enc, (ContainerItem[]));
		_reserveAdd(memItems);

		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();
		uint256 id = l.nextReserveId++;
		l.reserveIdsByBeneficiary[beneficiary].push(id);

		BeamioContainerStorageV07.ReserveEntry storage e = l.reserveById[id];
		e.status = 0;
		e.cancelDeadline = uint64(dl);
		e.beneficiary = beneficiary;
		e.itemsHash = ih;
		e.itemsData = enc;

		emit ReserveCreated(id, beneficiary, ih, uint64(dl));
	}

	function cancelReserve(address beneficiary, uint256 index) external onlyDelegatecall {
		address acct = address(this);
		if (beneficiary == address(0)) revert RS_BeneficiaryZero();
		_requireMsgSenderIsOwner(acct);

		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();
		uint256[] storage ids = l.reserveIdsByBeneficiary[beneficiary];
		if (index >= ids.length) revert RS_BadIndex(beneficiary, index, ids.length);
		uint256 id = ids[index];
		BeamioContainerStorageV07.ReserveEntry storage e = l.reserveById[id];
		if (e.itemsHash == bytes32(0)) revert RS_NotFound(id);
		if (e.status != 0) revert RS_BadStatus(id, e.status, 0);
		if (block.timestamp > e.cancelDeadline) revert RS_CancelDeadlinePassed(e.cancelDeadline, block.timestamp);

		ContainerItem[] memory items = abi.decode(e.itemsData, (ContainerItem[]));
		_reserveSub(items);
		e.status = 3;

		emit ReserveCancelled(id, beneficiary, index);
	}

	function execReserve(address beneficiary, uint256 index) external onlyDelegatecall {
		if (beneficiary == address(0)) revert RS_BeneficiaryZero();
		if (msg.sender != beneficiary) revert RS_NotBeneficiary(msg.sender, beneficiary);

		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();
		uint256[] storage ids = l.reserveIdsByBeneficiary[beneficiary];
		if (index >= ids.length) revert RS_BadIndex(beneficiary, index, ids.length);
		uint256 id = ids[index];
		BeamioContainerStorageV07.ReserveEntry storage e = l.reserveById[id];
		if (e.itemsHash == bytes32(0)) revert RS_NotFound(id);
		if (e.status != 0) revert RS_BadStatus(id, e.status, 0);
		if (block.timestamp <= e.cancelDeadline) revert RS_CancelNotYetExpired(e.cancelDeadline, block.timestamp);

		e.status = 1;

		emit ReserveApprovedEvt(id, beneficiary, index);
	}

	function transferReserve(address beneficiary, uint256 index) external onlyDelegatecall {
		if (beneficiary == address(0)) revert RS_BeneficiaryZero();

		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();
		uint256[] storage ids = l.reserveIdsByBeneficiary[beneficiary];
		if (index >= ids.length) revert RS_BadIndex(beneficiary, index, ids.length);
		uint256 id = ids[index];
		BeamioContainerStorageV07.ReserveEntry storage e = l.reserveById[id];
		if (e.itemsHash == bytes32(0)) revert RS_NotFound(id);
		if (e.status != 1) revert RS_BadStatus(id, e.status, 1);

		ContainerItem[] memory items = abi.decode(e.itemsData, (ContainerItem[]));
		_reserveSub(items);
		CExtLib2.containerMainMem(beneficiary, items);

		e.status = 2;

		emit ReserveTransferred(id, beneficiary, index);
	}

	/// @return index Slot position in beneficiary's reserve list (same as execReserve / transferReserve `index`).
	/// @return itemBundles Each element is `abi.encode(ContainerItem[])` for that reserve (empty if corrupt entry).
	/// @return execStatus Raw status: 0 Pending, 1 ReserveApproved, 2 Completed, 3 Cancelled.
	/// @return statusLabel English label for UI.
	function searchReserve(address beneficiary)
		external
		view
		onlyDelegatecall
		returns (
			uint256[] memory index,
			bytes[] memory itemBundles,
			uint8[] memory execStatus,
			string[] memory statusLabel
		)
	{
		if (beneficiary == address(0)) revert RS_BeneficiaryZero();
		BeamioContainerStorageV07.Layout storage l = BeamioContainerStorageV07.layout();
		uint256[] storage ids = l.reserveIdsByBeneficiary[beneficiary];
		uint256 n = ids.length;
		index = new uint256[](n);
		itemBundles = new bytes[](n);
		execStatus = new uint8[](n);
		statusLabel = new string[](n);
		for (uint256 i = 0; i < n; ) {
			BeamioContainerStorageV07.ReserveEntry storage e = l.reserveById[ids[i]];
			index[i] = i;
			itemBundles[i] = e.itemsData;
			execStatus[i] = e.status;
			statusLabel[i] = _reserveStatusLabel(e.status);
			unchecked {
				++i;
			}
		}
	}
}
