// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BeamioContainerStorageV07.sol";
import "./BeamioContainerItemTypesV07.sol";
import "./BeamioContainerModuleErrorsV07.sol";
import "./BeamioTypesV07.sol";

/// @dev Second linked library: preExecute reserve checks + ERC20/1155 transfer pipeline (shrinks module bytecode).
library BeamioContainerModuleExternalLib2V07 {
	function preExecuteCheck(
		BeamioContainerStorageV07.Layout storage l,
		address acct,
		address dest,
		bytes calldata func
	) external view {
		if (func.length < 4) return;

		bytes4 sel;
		assembly {
			sel := calldataload(func.offset)
		}

		if (sel == 0xa9059cbb) {
			if (func.length < 4 + 32 + 32) return;
			(, uint256 amount) = abi.decode(func[4:], (address, uint256));
			uint256 bal = IERC20Like(dest).balanceOf(acct);
			uint256 r = l.reservedErc20[dest];
			if (bal < r + amount) revert CM_ReservedERC20Violation(dest, amount, bal, r);
			return;
		}

		if (sel == 0x23b872dd) {
			if (func.length < 4 + 32 * 3) return;
			(address from,, uint256 amount) = abi.decode(func[4:], (address, address, uint256));
			if (from != acct) return;
			uint256 bal = IERC20Like(dest).balanceOf(acct);
			uint256 r = l.reservedErc20[dest];
			if (bal < r + amount) revert CM_ReservedERC20Violation(dest, amount, bal, r);
			return;
		}

		if (sel == 0xf242432a) {
			if (func.length < 4 + 32 * 4) return;
			(address from,, uint256 id, uint256 amount,) = abi.decode(func[4:], (address, address, uint256, uint256, bytes));
			if (from != acct) return;
			uint256 bal = IERC1155Like(dest).balanceOf(acct, id);
			uint256 r = l.reserved1155[dest][id];
			if (bal < r + amount) revert CM_Reserved1155Violation(dest, id, amount, bal, r);
			return;
		}

		if (sel == 0x2eb2c2d6) {
			if (func.length < 4 + 32 * 5) return;
			(address from,, uint256[] memory ids, uint256[] memory amounts,) = abi.decode(
				func[4:],
				(address, address, uint256[], uint256[], bytes)
			);
			if (from != acct) return;
			for (uint256 i = 0; i < ids.length; i++) {
				uint256 bal = IERC1155Like(dest).balanceOf(acct, ids[i]);
				uint256 r = l.reserved1155[dest][ids[i]];
				uint256 amt = i < amounts.length ? amounts[i] : 0;
				if (bal < r + amt) revert CM_Reserved1155Violation(dest, ids[i], amt, bal, r);
			}
			return;
		}
	}

	function _containerERC20(address to, ContainerItem[] memory items20) private {
		for (uint256 i = 0; i < items20.length; i++) {
			ContainerItem memory it = items20[i];
			if (it.amount == 0) continue;
			bool ok = IERC20Like(it.asset).transfer(to, it.amount);
			if (!ok) revert CM_ERC20TransferFailed(it.asset, to, it.amount);
		}
	}

	function containerERC20(address to, ContainerItem[] memory items20) external {
		_containerERC20(to, items20);
	}

	function _containerERC1155_token(
		address token,
		address to,
		uint256[] memory ids,
		uint256[] memory amounts,
		bytes[] memory datas
	) private {
		uint256 n = ids.length;
		if (n == 0) return;
		if (n != amounts.length || n != datas.length) revert LenMismatch();

		bool sameData = true;
		bytes32 d0 = keccak256(datas[0]);
		for (uint256 i = 1; i < n; i++) {
			if (keccak256(datas[i]) != d0) {
				sameData = false;
				break;
			}
		}

		if (sameData) {
			try IERC1155Like(token).safeBatchTransferFrom(address(this), to, ids, amounts, datas[0]) {
				return;
			} catch {}
		}

		for (uint256 i = 0; i < n; i++) {
			if (amounts[i] == 0) continue;
			try IERC1155Like(token).safeTransferFrom(address(this), to, ids[i], amounts[i], datas[i]) {
			} catch {
				revert CM_ERC1155TransferFailed(token, to);
			}
		}
	}

	function _containerERC1155(address to, ContainerItem[] memory items1155) private {
		uint256 n = items1155.length;
		if (n == 0) return;

		address[] memory tokens = new address[](n);
		uint256 tLen = 0;

		for (uint256 i = 0; i < n; i++) {
			address token = items1155[i].asset;
			bool seen = false;
			for (uint256 j = 0; j < tLen; j++) {
				if (tokens[j] == token) {
					seen = true;
					break;
				}
			}
			if (!seen) tokens[tLen++] = token;
		}

		for (uint256 ti = 0; ti < tLen; ti++) {
			address token = tokens[ti];
			uint256 m = 0;
			for (uint256 i = 0; i < n; i++) {
				if (items1155[i].asset == token) m++;
			}
			uint256[] memory ids = new uint256[](m);
			uint256[] memory amts = new uint256[](m);
			bytes[] memory datas = new bytes[](m);
			uint256 p = 0;
			for (uint256 i = 0; i < n; i++) {
				if (items1155[i].asset != token) continue;
				ids[p] = items1155[i].tokenId;
				amts[p] = items1155[i].amount;
				datas[p] = items1155[i].data;
				p++;
			}
			_containerERC1155_token(token, to, ids, amts, datas);
		}
	}

	function containerMainMem(address to, ContainerItem[] memory items) external {
		if (to == address(0)) revert CM_ToZero();
		uint256 n = items.length;
		if (n == 0) revert CM_EmptyItems();

		uint256 n20 = 0;
		uint256 n1155 = 0;
		for (uint256 i = 0; i < n; i++) {
			if (items[i].asset == address(0)) revert CM_ItemAssetZero(i);
			if (items[i].kind == AssetKind.ERC20) n20++;
			else if (items[i].kind == AssetKind.ERC1155) n1155++;
			else revert CM_UnsupportedKind(i);
		}

		if (n20 > 0) {
			ContainerItem[] memory a20 = new ContainerItem[](n20);
			uint256 p = 0;
			for (uint256 i = 0; i < n; i++) {
				if (items[i].kind == AssetKind.ERC20) a20[p++] = items[i];
			}
			_containerERC20(to, a20);
		}

		if (n1155 > 0) {
			ContainerItem[] memory a1155 = new ContainerItem[](n1155);
			uint256 p2 = 0;
			for (uint256 i = 0; i < n; i++) {
				if (items[i].kind == AssetKind.ERC1155) a1155[p2++] = items[i];
			}
			_containerERC1155(to, a1155);
		}
	}
}
