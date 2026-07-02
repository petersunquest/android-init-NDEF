// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library RewardPoolStorage {
    bytes32 internal constant SLOT = keccak256("beamio.usercard.rewardpool.storage.v1");

    uint8 internal constant ASSET_POINTS0 = 1;
    uint8 internal constant ASSET_CHARGE_REWARD2 = 2;
    uint8 internal constant ASSET_VOUCHER13 = 3;
    uint8 internal constant ASSET_CONET_USDC = 4;
    uint8 internal constant ASSET_GB = 5;
    uint8 internal constant ASSET_BUNIT = 6;

    struct EventRewardRule {
        bool active;
        uint8 eventKind;
        uint8 targetKind;
        uint256 issuedParentId;
        uint256 actorMint13;
        uint256 refMint13;
    }

    struct Layout {
        bool cardUserStatTokensInitialized;
        uint256 rewardMintBudget13;
        uint256 escrowUsdc6;
        uint256 escrowPoints6;
        uint256 escrowGb18;
        uint256 escrowBunit6;
        uint256 nextRuleId;
        mapping(uint256 => EventRewardRule) rules;
        /// @dev Plan A user-like EIP-712 nonces (key = keccak256(userEOA, nonce)).
        mapping(bytes32 => bool) usedRecordUserLikeNonces;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
