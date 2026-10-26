// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title IUnitStateVerifier
/// @notice Verifies CoNET-finalised proofs about one deposit unit on the external chain: its restriction state and balance
///         at one finalised block, and a loss determination for part of its principal. The proof system behind this
///         interface (state-root and storage proofs bound to finality) is a separate work item.
interface IUnitStateVerifier {
    /// @notice Restriction state and balance of one unit at one finalised external-chain block.
    struct UnitState {
        uint256 chainId;
        address treasury;
        address unit;
        address token;
        bool restricted;
        uint256 balance;
        uint256 blockNumber;
    }

    /// @notice A loss determination for part of one unit's registered principal.
    struct UnitLoss {
        uint256 chainId;
        address treasury;
        address unit;
        address token;
        uint256 amount;
        uint256 blockNumber;
    }

    function verifyUnitState(bytes calldata proof) external view returns (UnitState memory);

    function verifyUnitLoss(bytes calldata proof) external view returns (UnitLoss memory);
}
