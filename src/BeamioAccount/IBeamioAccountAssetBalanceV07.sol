// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Unified ERC20 / ERC1155 balance view for BeamioAccount (Route A container layout).
/// @dev Enum values MUST match `IBeamioContainerModuleV07.AssetKind` (ERC20=0, ERC1155=1).
interface IBeamioAccountAssetBalanceV07 {
	enum AssetKind {
		ERC20,
		ERC1155
	}

	struct AssetBalanceView {
		uint256 total;
		uint256 reserved;
		uint256 spendable;
	}

	/// @param tokenId Used only when kind == ERC1155; ignored for ERC20.
	function getAssetBalanceView(AssetKind kind, address asset, uint256 tokenId)
		external
		view
		returns (AssetBalanceView memory);
}
