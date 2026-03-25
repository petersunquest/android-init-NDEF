// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BeamioContainerItemTypesV07.sol";
import "./BeamioContainerModuleErrorsV07.sol";

interface IBeamioQuoteHelperV07Like {
	function quoteCurrencyAmountInUSDC6(uint8 cur, uint256 amount6) external view returns (uint256);
	function quoteUnitPointInUSDC6(uint8 cardCurrency, uint256 unitPointPriceInCurrencyE6) external view returns (uint256);
}

interface IBeamioUserCardLike {
	function currency() external view returns (uint8);
	function pointsUnitPriceInCurrencyE6() external view returns (uint256);
}

/// @dev Linked library: open/hash/topup pure+view helpers to shrink BeamioContainerModuleV07 bytecode.
library BeamioContainerModuleExternalLibV07 {
	bytes32 private constant CONTAINER_TYPEHASH =
		keccak256("ContainerMain(address account,address to,bytes32 itemsHash,uint256 nonce,uint256 deadline)");
	bytes32 private constant OPEN_CONTAINER_TYPEHASH =
		keccak256("OpenContainerMain(address account,uint8 currencyType,uint256 maxAmount,uint256 nonce,uint256 deadline)");

	function _hashItemInner(ContainerItem calldata it) private pure returns (bytes32) {
		return
			keccak256(abi.encode(uint8(it.kind), it.asset, it.amount, it.tokenId, keccak256(it.data)));
	}

	function hashItem(ContainerItem calldata it) external pure returns (bytes32) {
		return _hashItemInner(it);
	}

	function hashItems(ContainerItem[] calldata items) external pure returns (bytes32 itemsHash) {
		uint256 n = items.length;
		bytes32[] memory hs = new bytes32[](n);
		for (uint256 i = 0; i < n; i++) {
			hs[i] = _hashItemInner(items[i]);
		}
		return keccak256(abi.encode(hs));
	}

	function hashContainerMessage(
		bytes32 domainSeparator_,
		address acct,
		address to,
		bytes32 itemsHash_,
		uint256 nonce_,
		uint256 deadline_
	) external pure returns (bytes32) {
		bytes32 structHash = keccak256(
			abi.encode(CONTAINER_TYPEHASH, acct, to, itemsHash_, nonce_, deadline_)
		);
		return keccak256(abi.encodePacked("\x19\x01", domainSeparator_, structHash));
	}

	function hashOpenContainerMessage(
		bytes32 domainSeparator_,
		address acct,
		uint8 currencyType,
		uint256 maxAmount,
		uint256 nonce_,
		uint256 deadline_
	) external pure returns (bytes32) {
		bytes32 structHash = keccak256(
			abi.encode(OPEN_CONTAINER_TYPEHASH, acct, currencyType, maxAmount, nonce_, deadline_)
		);
		return keccak256(abi.encodePacked("\x19\x01", domainSeparator_, structHash));
	}

	function scanOpenItemsForRelay(
		ContainerItem[] calldata items,
		bool strict,
		address usdc,
		address userCard
	) external pure returns (uint256 totalUsdc6, uint256 cardPoints6) {
		uint256 n = items.length;
		for (uint256 i = 0; i < n; i++) {
			ContainerItem calldata it = items[i];
			if (it.asset == address(0)) revert CM_ItemAssetZero(i);

			if (it.kind == AssetKind.ERC20) {
				if (it.tokenId != 0 || it.data.length != 0) revert CM_ERC20HasTokenIdOrData(i);
				if (strict) {
					if (it.asset != usdc) revert CM_TokenNotUSDC(it.asset, usdc);
					totalUsdc6 += it.amount;
				}
				continue;
			}
			if (it.kind == AssetKind.ERC1155) {
				if (strict) {
					if (it.asset != userCard) revert CM_ERC1155NotUserCard(i, it.asset, userCard);
					if (it.tokenId != 0) revert CM_ERC1155TokenIdNotZero(i, it.tokenId);
					cardPoints6 += it.amount;
				}
				continue;
			}
			revert CM_UnsupportedKind(i);
		}
	}

	function parseAndValidateOpenTopupItems(
		ContainerItem[] calldata items,
		address usdc,
		address userCard
	) external pure returns (
		ContainerItem[] memory usdcItems,
		uint256 totalUsdc6,
		uint256 basePoints6,
		bytes memory data1155
	) {
		uint256 n = items.length;
		uint256 n20;
		uint256 n1155;
		for (uint256 i = 0; i < n; i++) {
			ContainerItem calldata it = items[i];
			if (it.kind == AssetKind.ERC20) n20++;
			else if (it.kind == AssetKind.ERC1155) n1155++;
			else revert CM_OpenTopupNotMixed();
		}
		if (n20 == 0 || n1155 == 0) revert CM_OpenTopupNotMixed();

		usdcItems = new ContainerItem[](n20);
		uint256 p;
		totalUsdc6 = 0;
		basePoints6 = 0;
		data1155 = "";
		bool dataSet;

		for (uint256 i = 0; i < n; i++) {
			ContainerItem calldata it = items[i];
			if (it.kind == AssetKind.ERC20) {
				if (it.asset == address(0)) revert CM_ItemAssetZero(i);
				if (it.asset != usdc) revert CM_TokenNotUSDC(it.asset, usdc);
				if (it.tokenId != 0 || it.data.length != 0) revert CM_ERC20HasTokenIdOrData(i);
				usdcItems[p++] = ContainerItem(AssetKind.ERC20, it.asset, it.amount, 0, bytes(""));
				totalUsdc6 += it.amount;
			} else {
				if (it.asset == address(0)) revert CM_ItemAssetZero(i);
				if (it.asset != userCard) revert CM_ERC1155NotUserCard(i, it.asset, userCard);
				if (it.tokenId != 0) revert CM_ERC1155TokenIdNotZero(i, it.tokenId);
				basePoints6 += it.amount;
				if (!dataSet) {
					data1155 = it.data;
					dataSet = true;
				}
			}
		}
	}

	function _unitPointUsdc6Inner(address userCard_, address helperAddr) private view returns (uint256 unitPointUsdc6) {
		uint8 cardCur = IBeamioUserCardLike(userCard_).currency();
		uint256 unitPriceE6 = IBeamioUserCardLike(userCard_).pointsUnitPriceInCurrencyE6();
		if (unitPriceE6 == 0) revert CM_UnitPriceZero();
		unitPointUsdc6 = IBeamioQuoteHelperV07Like(helperAddr).quoteUnitPointInUSDC6(cardCur, unitPriceE6);
		if (unitPointUsdc6 == 0) revert CM_UnitPriceZero();
	}

	function usdc6ToTopupPoints6(uint256 usdc6, address userCard_, address helperAddr) external view returns (uint256) {
		if (usdc6 == 0) return 0;
		return (usdc6 * 1e6) / _unitPointUsdc6Inner(userCard_, helperAddr);
	}

	function enforceOpenMaxBudget(
		uint256 maxAmount,
		address helperAddr,
		address userCard_,
		uint8 currencyType,
		uint256 totalUsdc6,
		uint256 cardPoints6
	) external view {
		if (maxAmount == 0) return;
		IBeamioQuoteHelperV07Like qh = IBeamioQuoteHelperV07Like(helperAddr);
		uint256 maxUsdc6 = qh.quoteCurrencyAmountInUSDC6(currencyType, maxAmount);
		uint256 cardValueUsdc6 = 0;
		if (cardPoints6 > 0) {
			uint256 unitPointUsdc6 = _unitPointUsdc6Inner(userCard_, helperAddr);
			cardValueUsdc6 = (cardPoints6 * unitPointUsdc6) / 1e6;
		}
		if (totalUsdc6 + cardValueUsdc6 > maxUsdc6) {
			revert CM_ExceedsMaxDetailed(totalUsdc6, cardValueUsdc6, maxUsdc6);
		}
	}

	function simTryUnitPointUsdc6(address userCard_, address helperAddr)
		external
		view
		returns (bool ok, uint256 unitPointUsdc6)
	{
		uint8 cardCur = IBeamioUserCardLike(userCard_).currency();
		uint256 unitPriceE6 = IBeamioUserCardLike(userCard_).pointsUnitPriceInCurrencyE6();
		if (unitPriceE6 == 0) return (false, 0);
		unitPointUsdc6 = IBeamioQuoteHelperV07Like(helperAddr).quoteUnitPointInUSDC6(cardCur, unitPriceE6);
		if (unitPointUsdc6 == 0) return (false, 0);
		return (true, unitPointUsdc6);
	}
}
