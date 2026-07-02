// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IssuedNftModule.sol";
import "./IssuedNftStorage.sol";
import "./Errors.sol";
import "./UserCumulativeStatLib.sol";
import "./RewardPoolStorage.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "../contracts/utils/cryptography/MessageHashUtils.sol";

interface IBeamioUserCardFactoryEip712 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/**
 * @title BeamioUserCardIssuedNftModuleV2
 * @notice Kind 2 extension: user cumulative stats (L0/L1/L2) without new module kind.
 */
contract BeamioUserCardIssuedNftModuleV2 is BeamioUserCardIssuedNftModuleV1 {
    bytes32 public constant RECORD_USER_LIKE_TYPEHASH = keccak256(
        "RecordUserLike(address cardAddress,address userEOA,uint8 targetKind,uint256 issuedParentId,bool liked,uint256 deadline,bytes32 nonce)"
    );

    event CardUserCumulativeStatTokensInitialized();
    event UserLikeAppliedWithSignature(
        address indexed userEOA,
        uint8 indexed targetKind,
        uint256 indexed issuedParentId,
        bool liked,
        bytes32 nonce
    );
    event UserCumulativeStatRecorded(
        address indexed wallet,
        uint8 indexed metricKind,
        uint8 indexed targetKind,
        uint256 issuedParentId,
        uint256 globalStatTokenId,
        uint256 scopedStatTokenId,
        uint256 delta
    );
    event UserCumulativeStatRevoked(
        address indexed wallet,
        uint8 indexed metricKind,
        uint8 indexed targetKind,
        uint256 issuedParentId,
        uint256 globalStatTokenId,
        uint256 scopedStatTokenId,
        uint256 delta
    );

    function initializeCardUserCumulativeStatTokens() external onlyOwnerAdminOrGateway {
        RewardPoolStorage.Layout storage rp = RewardPoolStorage.layout();
        if (rp.cardUserStatTokensInitialized) return;
        IssuedNftStorage.Layout storage l = IssuedNftStorage.layout();
        uint256[] memory ids = UserCumulativeStatLib.cardLevelStatTokenIds();
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            if (id == UserCumulativeStatLib.REWARD_VOUCHER_TOKEN_ID) continue;
            if (l.issuedNftMaxSupply[id] != 0) continue;
            l.issuedNftMaxSupply[id] = type(uint256).max;
            l.issuedNftIsStatToken[id] = true;
            l.issuedNftStatParentTokenId[id] = 0;
            l.issuedNftStatKind[id] = 0;
            emit IssuedNftStatTokenInitialized(id, 0, 0);
        }
        rp.cardUserStatTokensInitialized = true;
        emit CardUserCumulativeStatTokensInitialized();
    }

    function cardUserCumulativeStatTokensInitialized() external view returns (bool) {
        return RewardPoolStorage.layout().cardUserStatTokensInitialized;
    }

    /// @notice Plan A: user EIP-712 like / unlike without Factory `gatewayInvokeCard`.
    /// @dev Domain verifyingContract = card `factoryGateway()` (CoNET Factory DOMAIN_SEPARATOR).
    function applyUserLikeWithSignature(
        address userEOA,
        uint8 targetKind,
        uint256 issuedParentId,
        bool liked,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata userSignature
    ) external returns (uint256 globalStatTokenId, uint256 scopedStatTokenId) {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (block.timestamp > deadline) revert UC_InvalidTimeWindow(block.timestamp, 0, deadline);
        if (!RewardPoolStorage.layout().cardUserStatTokensInitialized) revert UC_UserStatNotInitialized();
        if (targetKind != UserCumulativeStatLib.TARGET_MERCHANT_CARD_COUPON
            && targetKind != UserCumulativeStatLib.TARGET_ISSUED_COUPON) {
            revert UC_InvalidCumulativeTarget(targetKind, issuedParentId);
        }

        address gw = IUserCardCtx(address(this)).factoryGateway();
        if (gw == address(0)) revert BM_ZeroAddress();

        RewardPoolStorage.Layout storage rp = RewardPoolStorage.layout();
        bytes32 nonceKey = keccak256(abi.encode(userEOA, nonce));
        if (rp.usedRecordUserLikeNonces[nonceKey]) revert UC_NonceUsed();
        rp.usedRecordUserLikeNonces[nonceKey] = true;

        bytes32 structHash = keccak256(
            abi.encode(
                RECORD_USER_LIKE_TYPEHASH,
                address(this),
                userEOA,
                targetKind,
                issuedParentId,
                liked,
                deadline,
                nonce
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            IBeamioUserCardFactoryEip712(gw).DOMAIN_SEPARATOR(),
            structHash
        );
        address signer = ECDSA.recover(digest, userSignature);
        if (signer != userEOA) revert UC_InvalidSignature(signer, userEOA);

        uint8 metricKind = UserCumulativeStatLib.METRIC_USER_LIKE;
        uint256 delta = 1;
        if (liked) {
            (globalStatTokenId, scopedStatTokenId) = _recordUserLikeStat(userEOA, metricKind, targetKind, issuedParentId, delta);
        } else {
            (globalStatTokenId, scopedStatTokenId) = _burnUserLikeStat(userEOA, metricKind, targetKind, issuedParentId, delta);
        }
        emit UserLikeAppliedWithSignature(userEOA, targetKind, issuedParentId, liked, nonce);
    }

    /// @notice Record user cumulative stats. Topup/charge use targetKind=TARGET_GLOBAL_ONLY.
    ///         Merchant-card page uses TARGET_MERCHANT_CARD_COUPON (L0+L1).
    ///         Issued coupon uses TARGET_ISSUED_COUPON (L0+L2).
    function recordUserCumulativeStat(
        address wallet,
        uint8 metricKind,
        uint8 targetKind,
        uint256 issuedParentId,
        uint256 delta
    ) external onlyOwnerAdminOrGateway returns (uint256 globalStatTokenId, uint256 scopedStatTokenId) {
        return _recordUserLikeStat(wallet, metricKind, targetKind, issuedParentId, delta);
    }

    function _recordUserLikeStat(
        address wallet,
        uint8 metricKind,
        uint8 targetKind,
        uint256 issuedParentId,
        uint256 delta
    ) internal returns (uint256 globalStatTokenId, uint256 scopedStatTokenId) {
        if (wallet == address(0)) revert BM_ZeroAddress();
        if (delta == 0) revert UC_AmountZero();
        if (!RewardPoolStorage.layout().cardUserStatTokensInitialized) revert UC_UserStatNotInitialized();

        if (metricKind == UserCumulativeStatLib.METRIC_TOPUP || metricKind == UserCumulativeStatLib.METRIC_CHARGE) {
            if (targetKind != UserCumulativeStatLib.TARGET_GLOBAL_ONLY) {
                revert UC_InvalidCumulativeTarget(targetKind, issuedParentId);
            }
            globalStatTokenId = UserCumulativeStatLib.globalStatTokenId(metricKind);
            _mint(wallet, globalStatTokenId, delta, "");
            scopedStatTokenId = 0;
            emit UserCumulativeStatRecorded(wallet, metricKind, targetKind, 0, globalStatTokenId, 0, delta);
            return (globalStatTokenId, 0);
        }

        globalStatTokenId = UserCumulativeStatLib.globalStatTokenId(metricKind);
        _mint(wallet, globalStatTokenId, delta, "");

        if (targetKind == UserCumulativeStatLib.TARGET_MERCHANT_CARD_COUPON) {
            scopedStatTokenId = UserCumulativeStatLib.merchantCardStatTokenId(metricKind);
            _mint(wallet, scopedStatTokenId, delta, "");
        } else if (targetKind == UserCumulativeStatLib.TARGET_ISSUED_COUPON) {
            _requireRealIssuedNft(issuedParentId);
            scopedStatTokenId = UserCumulativeStatLib.issuedCouponStatTokenId(issuedParentId, metricKind);
            _requireStatToken(scopedStatTokenId);
            _mint(wallet, scopedStatTokenId, delta, "");
        } else {
            revert UC_InvalidCumulativeTarget(targetKind, issuedParentId);
        }

        emit UserCumulativeStatRecorded(
            wallet, metricKind, targetKind, issuedParentId, globalStatTokenId, scopedStatTokenId, delta
        );
    }

    /// @notice Revoke (burn) user cumulative stat balances; gateway-only mirror of `recordUserCumulativeStat`.
    function burnUserCumulativeStatByGateway(
        address wallet,
        uint8 metricKind,
        uint8 targetKind,
        uint256 issuedParentId,
        uint256 delta
    ) external onlyOwnerAdminOrGateway returns (uint256 globalStatTokenId, uint256 scopedStatTokenId) {
        return _burnUserLikeStat(wallet, metricKind, targetKind, issuedParentId, delta);
    }

    function _burnUserLikeStat(
        address wallet,
        uint8 metricKind,
        uint8 targetKind,
        uint256 issuedParentId,
        uint256 delta
    ) internal returns (uint256 globalStatTokenId, uint256 scopedStatTokenId) {
        if (wallet == address(0)) revert BM_ZeroAddress();
        if (delta == 0) revert UC_AmountZero();
        if (!RewardPoolStorage.layout().cardUserStatTokensInitialized) revert UC_UserStatNotInitialized();

        if (metricKind == UserCumulativeStatLib.METRIC_TOPUP || metricKind == UserCumulativeStatLib.METRIC_CHARGE) {
            if (targetKind != UserCumulativeStatLib.TARGET_GLOBAL_ONLY) {
                revert UC_InvalidCumulativeTarget(targetKind, issuedParentId);
            }
            globalStatTokenId = UserCumulativeStatLib.globalStatTokenId(metricKind);
            uint256 bal = balanceOf(wallet, globalStatTokenId);
            if (delta > bal) revert UC_InsufficientBalance(wallet, globalStatTokenId, bal, delta);
            _burn(wallet, globalStatTokenId, delta);
            scopedStatTokenId = 0;
            emit UserCumulativeStatRevoked(wallet, metricKind, targetKind, 0, globalStatTokenId, 0, delta);
            return (globalStatTokenId, 0);
        }

        globalStatTokenId = UserCumulativeStatLib.globalStatTokenId(metricKind);
        {
            uint256 balG = balanceOf(wallet, globalStatTokenId);
            if (delta > balG) revert UC_InsufficientBalance(wallet, globalStatTokenId, balG, delta);
            _burn(wallet, globalStatTokenId, delta);
        }

        if (targetKind == UserCumulativeStatLib.TARGET_MERCHANT_CARD_COUPON) {
            scopedStatTokenId = UserCumulativeStatLib.merchantCardStatTokenId(metricKind);
            uint256 balS = balanceOf(wallet, scopedStatTokenId);
            if (delta > balS) revert UC_InsufficientBalance(wallet, scopedStatTokenId, balS, delta);
            _burn(wallet, scopedStatTokenId, delta);
        } else if (targetKind == UserCumulativeStatLib.TARGET_ISSUED_COUPON) {
            _requireRealIssuedNft(issuedParentId);
            scopedStatTokenId = UserCumulativeStatLib.issuedCouponStatTokenId(issuedParentId, metricKind);
            _requireStatToken(scopedStatTokenId);
            uint256 balS = balanceOf(wallet, scopedStatTokenId);
            if (delta > balS) revert UC_InsufficientBalance(wallet, scopedStatTokenId, balS, delta);
            _burn(wallet, scopedStatTokenId, delta);
        } else {
            revert UC_InvalidCumulativeTarget(targetKind, issuedParentId);
        }

        emit UserCumulativeStatRevoked(
            wallet, metricKind, targetKind, issuedParentId, globalStatTokenId, scopedStatTokenId, delta
        );
    }

    function resolveUserCumulativeStatTokenId(uint8 metricKind, uint8 targetKind, uint256 issuedParentId)
        external
        pure
        returns (uint256 globalTokenId, uint256 scopedTokenId)
    {
        globalTokenId = UserCumulativeStatLib.globalStatTokenId(metricKind);
        if (targetKind == UserCumulativeStatLib.TARGET_MERCHANT_CARD_COUPON) {
            scopedTokenId = UserCumulativeStatLib.merchantCardStatTokenId(metricKind);
        } else if (targetKind == UserCumulativeStatLib.TARGET_ISSUED_COUPON) {
            scopedTokenId = UserCumulativeStatLib.issuedCouponStatTokenId(issuedParentId, metricKind);
        }
    }

    function _initializeIssuedNftStatTokens(IssuedNftStorage.Layout storage l, uint256 parentTokenId) internal override {
        super._initializeIssuedNftStatTokens(l, parentTokenId);
        _initializeIssuedNftStatToken(
            l, parentTokenId, parentTokenId + UserCumulativeStatLib.COUPON_USER_CLICK_OFFSET, STAT_KIND_REFERRAL_CLICK
        );
        _initializeIssuedNftStatToken(
            l, parentTokenId, parentTokenId + UserCumulativeStatLib.COUPON_USER_COMMENT_OFFSET, STAT_KIND_TRAFFIC
        );
        _initializeIssuedNftStatToken(
            l, parentTokenId, parentTokenId + UserCumulativeStatLib.COUPON_USER_LIKE_OFFSET, STAT_KIND_TRAFFIC
        );
        _initializeIssuedNftStatToken(
            l, parentTokenId, parentTokenId + UserCumulativeStatLib.COUPON_USER_PURCHASE_OFFSET, STAT_KIND_TRAFFIC
        );
        _initializeIssuedNftStatToken(
            l, parentTokenId, parentTokenId + UserCumulativeStatLib.COUPON_REF_LIKE_OFFSET, STAT_KIND_REFERRAL_CLICK
        );
        _initializeIssuedNftStatToken(
            l, parentTokenId, parentTokenId + UserCumulativeStatLib.COUPON_REF_COMMENT_OFFSET, STAT_KIND_REFERRAL_CLICK
        );
        _initializeIssuedNftStatToken(
            l, parentTokenId, parentTokenId + UserCumulativeStatLib.COUPON_REF_PURCHASE_OFFSET, STAT_KIND_REFERRAL_CLICK
        );
    }

    /// @dev Backfill V2 per-issued stat tokens for series created before V2 module bind.
    function bootstrapIssuedNftV2StatTokens(uint256 parentTokenId) external onlyOwnerAdminOrGateway {
        _requireRealIssuedNft(parentTokenId);
        _initializeIssuedNftStatTokens(IssuedNftStorage.layout(), parentTokenId);
    }
}
