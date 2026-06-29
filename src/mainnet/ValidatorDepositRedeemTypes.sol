// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice CNET airdrop ledger (accrued on airdrop-flagged redeem claims, paid from the redeem contract balance).
/// @dev    Held as a single storage struct in {ValidatorDepositRedeem} so the claim/settle logic can be offloaded
///         to {ValidatorDepositRedeemStatsLib} by passing one storage pointer (keeps the main contract under EIP-170).
struct AirdropState {
    /// @dev beneficiary => cumulative CNET airdrop entitlement accrued.
    mapping(address => uint256) accrued;
    /// @dev beneficiary => CNET airdrop already claimed (claimable = accrued - claimed).
    mapping(address => uint256) claimed;
    /// @dev Unix time from which airdrops may be claimed; 0 = closed.
    uint64 claimableAt;
}

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

/// @notice Per-Guardian-id validator binding (shared by main contract + transfer library).
struct ValidatorBinding {
    bytes pubkey;
    address withdrawalBeneficiary;
    uint64 registeredAt;
    uint64 exitedAt;
    bool active;
}
