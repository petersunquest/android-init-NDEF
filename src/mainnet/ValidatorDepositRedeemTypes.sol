// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Complete on-chain node dataset for a beneficiary (shared by main contract + stats library).
struct NodeBundle {
    address beneficiary;
    uint256[] guardianNodeIds;
    string[] depinNodeIps;
    address[] nodeWallets;
    bytes[] validatorPubkeys;
    bool[] validatorActive;
    uint256 validatorNodeCount;
    uint256 gbMiningNodeCount;
    uint256 claimCount;
    uint256 nativeBalance;
    uint256 gbBalance;
    uint256 usdcBalance;
}
