// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev MUST match BeamioAccount / clients ABI layout (ERC20=0, ERC1155=1).
enum AssetKind {
	ERC20,
	ERC1155
}

struct ContainerItem {
	AssetKind kind;
	address asset;
	uint256 amount;
	uint256 tokenId;
	bytes data;
}
