// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

interface IBUnitAirdropReferralClaim {
    function payoutClaimable(address recipient, uint256 amount) external;
}

/**
 * @dev Extracted from ReferralRegistryVaultV1 to stay under the 24KB limit.
 * MemberView must match ReferralRegistryVaultV1.Member storage layout.
 */
library ReferralRegistryClaimLib {
    using ECDSA for bytes32;

    uint8 internal constant ROLE_L0 = 1;
    uint8 internal constant ROLE_L1 = 2;

    error SignatureExpired();
    error NonceUsed();
    error InvalidAmount();
    error ClaimPaused();
    error InvalidSignature();

    struct MemberView {
        uint8 role;
        address parentAdmin;
        address parentL0;
        uint256 rebateBps;
        uint256 ratioBps;
        bool active;
    }

    function claimConetUsdc(
        mapping(address => MemberView) storage members,
        mapping(address => uint256) storage claimableConetUsdc,
        mapping(address => uint256) storage claimedConetUsdc,
        mapping(address => uint256) storage claimNonces,
        mapping(address => bool) storage l0ClaimPaused,
        mapping(address => mapping(address => bool)) storage l1ClaimPaused,
        address bunitAirdrop,
        address account,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (claimNonces[account] != nonce) revert NonceUsed();
        if (amount == 0 || amount > claimableConetUsdc[account]) revert InvalidAmount();
        MemberView memory m = members[account];
        if (m.role == ROLE_L0 && l0ClaimPaused[account]) revert ClaimPaused();
        if (m.role == ROLE_L1 && l1ClaimPaused[m.parentL0][account]) revert ClaimPaused();
        bytes32 digest = keccak256(
            abi.encode(
                keccak256("ClaimConetUsdc(address account,uint256 amount,uint256 nonce,uint256 deadline)"),
                account,
                amount,
                nonce,
                deadline
            )
        );
        bytes32 ethDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        if (ethDigest.recover(signature) != account) revert InvalidSignature();
        claimNonces[account] = nonce + 1;
        claimableConetUsdc[account] -= amount;
        claimedConetUsdc[account] += amount;
        IBUnitAirdropReferralClaim(bunitAirdrop).payoutClaimable(account, amount);
    }
}
