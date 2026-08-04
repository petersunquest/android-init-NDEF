// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BeamioERC1155Logic.sol";

/// @dev Shared user cumulative stat token ids, kinds, and resolution (kind 2 + kind 5).
library UserCumulativeStatLib {
    uint256 internal constant ISSUED_NFT_START_ID = BeamioERC1155Logic.ISSUED_NFT_START_ID;
    uint256 internal constant NFT_START_ID = BeamioERC1155Logic.NFT_START_ID;

    // L0 global cumulative (target aggregate = entire merchant program card)
    uint256 internal constant USER_CUMUL_TOPUP_TOKEN_ID = 3;
    uint256 internal constant USER_CUMUL_CHARGE_TOKEN_ID = 4;
    uint256 internal constant USER_CUMUL_CLICK_TOKEN_ID = 5;
    uint256 internal constant USER_CUMUL_COMMENT_TOKEN_ID = 6;
    uint256 internal constant USER_CUMUL_SHARE_TOKEN_ID = 7;
    uint256 internal constant USER_CUMUL_LIKE_TOKEN_ID = 8;
    uint256 internal constant USER_CUMUL_PURCHASE_TOKEN_ID = 9;
    uint256 internal constant CARD_REFERRAL_CLICK_TOKEN_ID = 10;
    uint256 internal constant CARD_REFERRAL_CLAIM_TOKEN_ID = 11;
    uint256 internal constant CARD_REFERRAL_BURN_TOKEN_ID = 12;
    uint256 internal constant REWARD_VOUCHER_TOKEN_ID = 13;
    uint256 internal constant CARD_REFERRAL_LIKE_TOKEN_ID = 14;
    uint256 internal constant CARD_REFERRAL_COMMENT_TOKEN_ID = 15;
    uint256 internal constant CARD_REFERRAL_PURCHASE_TOKEN_ID = 16;

    // L1 merchant-card-as-special-coupon (#17-#24, strictly below membership NFT_START_ID=100)
    uint256 internal constant MERCHANT_CARD_CLICK_TOKEN_ID = 17;
    uint256 internal constant MERCHANT_CARD_COMMENT_TOKEN_ID = 18;
    uint256 internal constant MERCHANT_CARD_LIKE_TOKEN_ID = 19;
    uint256 internal constant MERCHANT_CARD_PURCHASE_TOKEN_ID = 20;
    uint256 internal constant MERCHANT_CARD_REF_CLICK_TOKEN_ID = 21;
    uint256 internal constant MERCHANT_CARD_REF_CLAIM_TOKEN_ID = 22;
    uint256 internal constant MERCHANT_CARD_REF_BURN_TOKEN_ID = 23;
    uint256 internal constant MERCHANT_CARD_REF_LIKE_TOKEN_ID = 24;
    uint256 internal constant MERCHANT_CARD_REF_COMMENT_TOKEN_ID = 25;
    uint256 internal constant MERCHANT_CARD_REF_PURCHASE_TOKEN_ID = 26;
    uint256 internal constant USER_CUMUL_INSTALL_TOKEN_ID = 27;
    uint256 internal constant CARD_REFERRAL_INSTALL_TOKEN_ID = 28;
    uint256 internal constant MERCHANT_CARD_INSTALL_TOKEN_ID = 29;
    uint256 internal constant MERCHANT_CARD_REF_INSTALL_TOKEN_ID = 30;

    // L2 issued-coupon offsets (parent = issued token id >= 1e11)
    uint256 internal constant COUPON_REFERRAL_CLICK_OFFSET = 200_000_000_000;
    uint256 internal constant COUPON_REFERRAL_CLAIM_OFFSET = 300_000_000_000;
    uint256 internal constant COUPON_REFERRAL_BURN_OFFSET = 400_000_000_000;
    uint256 internal constant COUPON_USER_CLICK_OFFSET = 600_000_000_000;
    uint256 internal constant COUPON_USER_COMMENT_OFFSET = 610_000_000_000;
    uint256 internal constant COUPON_USER_LIKE_OFFSET = 620_000_000_000;
    uint256 internal constant COUPON_USER_PURCHASE_OFFSET = 630_000_000_000;
    uint256 internal constant COUPON_REF_LIKE_OFFSET = 700_000_000_000;
    uint256 internal constant COUPON_REF_COMMENT_OFFSET = 710_000_000_000;
    uint256 internal constant COUPON_REF_PURCHASE_OFFSET = 720_000_000_000;

    uint8 internal constant TARGET_GLOBAL_ONLY = 0;
    uint8 internal constant TARGET_MERCHANT_CARD_COUPON = 1;
    uint8 internal constant TARGET_ISSUED_COUPON = 2;

    uint8 internal constant METRIC_TOPUP = 1;
    uint8 internal constant METRIC_CHARGE = 2;
    uint8 internal constant METRIC_USER_CLICK = 3;
    uint8 internal constant METRIC_USER_COMMENT = 4;
    uint8 internal constant METRIC_USER_LIKE = 5;
    uint8 internal constant METRIC_USER_PURCHASE = 6;
    uint8 internal constant METRIC_REF_CLICK = 7;
    uint8 internal constant METRIC_REF_CLAIM = 8;
    uint8 internal constant METRIC_REF_BURN = 9;
    uint8 internal constant METRIC_REF_LIKE = 10;
    uint8 internal constant METRIC_REF_COMMENT = 11;
    uint8 internal constant METRIC_REF_PURCHASE = 12;
    uint8 internal constant METRIC_INSTALL = 13;
    uint8 internal constant METRIC_REF_INSTALL = 14;

    function globalStatTokenId(uint8 metricKind) internal pure returns (uint256 tokenId) {
        if (metricKind == METRIC_TOPUP) return USER_CUMUL_TOPUP_TOKEN_ID;
        if (metricKind == METRIC_CHARGE) return USER_CUMUL_CHARGE_TOKEN_ID;
        if (metricKind == METRIC_USER_CLICK) return USER_CUMUL_CLICK_TOKEN_ID;
        if (metricKind == METRIC_USER_COMMENT) return USER_CUMUL_COMMENT_TOKEN_ID;
        if (metricKind == METRIC_USER_LIKE) return USER_CUMUL_LIKE_TOKEN_ID;
        if (metricKind == METRIC_USER_PURCHASE) return USER_CUMUL_PURCHASE_TOKEN_ID;
        if (metricKind == METRIC_REF_CLICK) return CARD_REFERRAL_CLICK_TOKEN_ID;
        if (metricKind == METRIC_REF_CLAIM) return CARD_REFERRAL_CLAIM_TOKEN_ID;
        if (metricKind == METRIC_REF_BURN) return CARD_REFERRAL_BURN_TOKEN_ID;
        if (metricKind == METRIC_REF_LIKE) return CARD_REFERRAL_LIKE_TOKEN_ID;
        if (metricKind == METRIC_REF_COMMENT) return CARD_REFERRAL_COMMENT_TOKEN_ID;
        if (metricKind == METRIC_REF_PURCHASE) return CARD_REFERRAL_PURCHASE_TOKEN_ID;
        if (metricKind == METRIC_INSTALL) return USER_CUMUL_INSTALL_TOKEN_ID;
        if (metricKind == METRIC_REF_INSTALL) return CARD_REFERRAL_INSTALL_TOKEN_ID;
        revert("UC_STAT_METRIC");
    }

    function merchantCardStatTokenId(uint8 metricKind) internal pure returns (uint256 tokenId) {
        if (metricKind == METRIC_USER_CLICK) return MERCHANT_CARD_CLICK_TOKEN_ID;
        if (metricKind == METRIC_USER_COMMENT) return MERCHANT_CARD_COMMENT_TOKEN_ID;
        if (metricKind == METRIC_USER_LIKE) return MERCHANT_CARD_LIKE_TOKEN_ID;
        if (metricKind == METRIC_USER_PURCHASE) return MERCHANT_CARD_PURCHASE_TOKEN_ID;
        if (metricKind == METRIC_REF_CLICK) return MERCHANT_CARD_REF_CLICK_TOKEN_ID;
        if (metricKind == METRIC_REF_CLAIM) return MERCHANT_CARD_REF_CLAIM_TOKEN_ID;
        if (metricKind == METRIC_REF_BURN) return MERCHANT_CARD_REF_BURN_TOKEN_ID;
        if (metricKind == METRIC_REF_LIKE) return MERCHANT_CARD_REF_LIKE_TOKEN_ID;
        if (metricKind == METRIC_REF_COMMENT) return MERCHANT_CARD_REF_COMMENT_TOKEN_ID;
        if (metricKind == METRIC_REF_PURCHASE) return MERCHANT_CARD_REF_PURCHASE_TOKEN_ID;
        if (metricKind == METRIC_INSTALL) return MERCHANT_CARD_INSTALL_TOKEN_ID;
        if (metricKind == METRIC_REF_INSTALL) return MERCHANT_CARD_REF_INSTALL_TOKEN_ID;
        revert("UC_STAT_METRIC");
    }

    function issuedCouponStatTokenId(uint256 issuedParentId, uint8 metricKind) internal pure returns (uint256 tokenId) {
        if (metricKind == METRIC_USER_CLICK) return issuedParentId + COUPON_USER_CLICK_OFFSET;
        if (metricKind == METRIC_USER_COMMENT) return issuedParentId + COUPON_USER_COMMENT_OFFSET;
        if (metricKind == METRIC_USER_LIKE) return issuedParentId + COUPON_USER_LIKE_OFFSET;
        if (metricKind == METRIC_USER_PURCHASE) return issuedParentId + COUPON_USER_PURCHASE_OFFSET;
        if (metricKind == METRIC_REF_CLICK) return issuedParentId + COUPON_REFERRAL_CLICK_OFFSET;
        if (metricKind == METRIC_REF_CLAIM) return issuedParentId + COUPON_REFERRAL_CLAIM_OFFSET;
        if (metricKind == METRIC_REF_BURN) return issuedParentId + COUPON_REFERRAL_BURN_OFFSET;
        if (metricKind == METRIC_REF_LIKE) return issuedParentId + COUPON_REF_LIKE_OFFSET;
        if (metricKind == METRIC_REF_COMMENT) return issuedParentId + COUPON_REF_COMMENT_OFFSET;
        if (metricKind == METRIC_REF_PURCHASE) return issuedParentId + COUPON_REF_PURCHASE_OFFSET;
        revert("UC_STAT_METRIC");
    }

    function cardLevelStatTokenIds() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](28);
        ids[0] = USER_CUMUL_TOPUP_TOKEN_ID;
        ids[1] = USER_CUMUL_CHARGE_TOKEN_ID;
        ids[2] = USER_CUMUL_CLICK_TOKEN_ID;
        ids[3] = USER_CUMUL_COMMENT_TOKEN_ID;
        ids[4] = USER_CUMUL_SHARE_TOKEN_ID;
        ids[5] = USER_CUMUL_LIKE_TOKEN_ID;
        ids[6] = USER_CUMUL_PURCHASE_TOKEN_ID;
        ids[7] = CARD_REFERRAL_CLICK_TOKEN_ID;
        ids[8] = CARD_REFERRAL_CLAIM_TOKEN_ID;
        ids[9] = CARD_REFERRAL_BURN_TOKEN_ID;
        ids[10] = REWARD_VOUCHER_TOKEN_ID;
        ids[11] = CARD_REFERRAL_LIKE_TOKEN_ID;
        ids[12] = CARD_REFERRAL_COMMENT_TOKEN_ID;
        ids[13] = CARD_REFERRAL_PURCHASE_TOKEN_ID;
        ids[14] = MERCHANT_CARD_CLICK_TOKEN_ID;
        ids[15] = MERCHANT_CARD_COMMENT_TOKEN_ID;
        ids[16] = MERCHANT_CARD_LIKE_TOKEN_ID;
        ids[17] = MERCHANT_CARD_PURCHASE_TOKEN_ID;
        ids[18] = MERCHANT_CARD_REF_CLICK_TOKEN_ID;
        ids[19] = MERCHANT_CARD_REF_CLAIM_TOKEN_ID;
        ids[20] = MERCHANT_CARD_REF_BURN_TOKEN_ID;
        ids[21] = MERCHANT_CARD_REF_LIKE_TOKEN_ID;
        ids[22] = MERCHANT_CARD_REF_COMMENT_TOKEN_ID;
        ids[23] = MERCHANT_CARD_REF_PURCHASE_TOKEN_ID;
        ids[24] = USER_CUMUL_INSTALL_TOKEN_ID;
        ids[25] = CARD_REFERRAL_INSTALL_TOKEN_ID;
        ids[26] = MERCHANT_CARD_INSTALL_TOKEN_ID;
        ids[27] = MERCHANT_CARD_REF_INSTALL_TOKEN_ID;
    }

    function isLowIdStatToken(uint256 tokenId) internal pure returns (bool) {
        if (tokenId < USER_CUMUL_TOPUP_TOKEN_ID) return false;
        if (tokenId >= NFT_START_ID && tokenId < ISSUED_NFT_START_ID) return false;
        if (tokenId > MERCHANT_CARD_REF_INSTALL_TOKEN_ID && tokenId < NFT_START_ID) return false;
        return tokenId <= MERCHANT_CARD_REF_INSTALL_TOKEN_ID || tokenId == REWARD_VOUCHER_TOKEN_ID;
    }
}
