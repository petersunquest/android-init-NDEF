// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Phase 6 AAC registry.
/// @dev This deployment is permanently paused. It has no token balance,
///      no external call, and no function that can turn pause off.
contract AacRegistryPaused {
    bool public constant paused = true;

    error Paused();

    function note(bytes32) external pure {
        revert Paused();
    }

    function consume(bytes32) external pure {
        revert Paused();
    }
}
