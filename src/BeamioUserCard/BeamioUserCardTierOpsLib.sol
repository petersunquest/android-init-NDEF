// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BeamioUserCardTypes.sol";
import "./MembershipFeeOpsLib.sol";
import "./Errors.sol";

/// @dev Linked storage routines kept outside BeamioUserCard so the card remains
///      below EIP-170 while retaining one-transaction Beacon initialization.
library BeamioUserCardTierOpsLib {
    uint8 internal constant QUALIFICATION_TOPUP = 0;
    uint8 internal constant QUALIFICATION_DIRECT_PURCHASE = 1;
    uint8 internal constant QUALIFICATION_CHARGE = 2;

    event TierAppended(
        uint256 index,
        uint256 minUsdc6,
        uint256 attr,
        uint256 tierExpirySeconds,
        bool upgradeByBalance
    );

    function configureInitialTiers(
        UserCardTier[] storage destination,
        UserCardInitialTierConfig memory config
    ) external returns (uint8 upgradeType_) {
        uint8 mode = config.qualificationMode;
        if (mode > QUALIFICATION_CHARGE) revert UC_InvalidUpgradeType();

        if (mode == QUALIFICATION_DIRECT_PURCHASE) {
            uint256 feeTierCount = config.membershipFeeE6.length;
            if (
                feeTierCount == 0 ||
                config.tiers.length != feeTierCount ||
                config.membershipDurationKind.length != feeTierCount
            ) revert UC_MembershipFeeLenMismatch();
            for (uint256 i = 0; i < feeTierCount; i++) {
                UserCardTier memory tier = config.tiers[i];
                if (tier.minUsdc6 == 0) revert UC_TierMinZero();
                if (i > 0 && tier.minUsdc6 <= config.tiers[i - 1].minUsdc6) {
                    revert UC_TiersNotIncreasing();
                }
                // Direct-fee schedules are represented in `tiers` for a
                // canonical on-chain tier[0..n] list, but never qualify
                // membership through top-up/balance/charge points.
                destination.push(UserCardTier(tier.minUsdc6, tier.attr, tier.tierExpirySeconds, false));
            }
            MembershipFeeOpsLib.configureInitialMembershipFees(
                config.membershipFeeE6, config.membershipDurationKind
            );
            // Direct membership fees do not create top-up credit.
            return QUALIFICATION_TOPUP;
        }

        if (config.membershipFeeE6.length != 0 || config.membershipDurationKind.length != 0) {
            revert UC_MembershipFeeLenMismatch();
        }
        if (config.tiers.length == 0) revert UC_TierLenMismatch();

        for (uint256 i = 0; i < config.tiers.length; i++) {
            UserCardTier memory tier = config.tiers[i];
            if (tier.minUsdc6 == 0) revert UC_TierMinZero();
            if (i > 0 && tier.minUsdc6 <= config.tiers[i - 1].minUsdc6) {
                revert UC_TiersNotIncreasing();
            }
            destination.push(UserCardTier(tier.minUsdc6, tier.attr, tier.tierExpirySeconds, false));
        }
        return mode == QUALIFICATION_CHARGE ? QUALIFICATION_CHARGE : QUALIFICATION_TOPUP;
    }

    function replaceTiers(UserCardTier[] storage destination, UserCardTier[] calldata replacement) external {
        if (replacement.length == 0) revert UC_TierLenMismatch();
        while (destination.length != 0) destination.pop();
        for (uint256 i = 0; i < replacement.length; i++) {
            if (replacement[i].minUsdc6 == 0) revert UC_TierMinZero();
            if (i > 0 && replacement[i].minUsdc6 <= replacement[i - 1].minUsdc6) {
                revert UC_TiersNotIncreasing();
            }
            destination.push(replacement[i]);
        }
    }

    function appendTier(
        UserCardTier[] storage destination,
        uint256 minUsdc6,
        uint256 attr,
        uint256 tierExpirySeconds,
        bool upgradeByBalance
    ) external {
        if (minUsdc6 == 0) revert UC_TierMinZero();
        uint256 index = destination.length;
        if (index != 0 && minUsdc6 <= destination[index - 1].minUsdc6) {
            revert UC_TiersNotIncreasing();
        }
        destination.push(UserCardTier(minUsdc6, attr, tierExpirySeconds, upgradeByBalance));
        emit TierAppended(index, minUsdc6, attr, tierExpirySeconds, upgradeByBalance);
    }

}
