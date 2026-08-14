// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @notice Minimal Treasury V3 adapter surface consumed by AssetBurnMintGateway.
/// @dev Implementations must make operation ids globally single-use and reserve
/// replacement mint capacity atomically with each physical burn.
interface ITreasuryDleAuthorityV1 {
    function reserveAndBurn(
        bytes32 operationId,
        address asset,
        address from,
        uint256 amount,
        uint64 adapterEpoch
    ) external;

    function releaseReservedAndMint(
        bytes32 operationId,
        address asset,
        address to,
        uint256 amount,
        uint64 adapterEpoch
    ) external;

    function canonicalAsset(address asset) external view returns (bool);

    function availableReplacementCapacity(address asset) external view returns (uint256);

    function reservedReplacement(address asset) external view returns (uint256);

    function operationConsumed(bytes32 operationId) external view returns (bool);
}
