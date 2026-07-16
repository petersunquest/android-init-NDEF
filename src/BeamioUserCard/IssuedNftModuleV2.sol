// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IssuedNftModule.sol";
import "./IssuedNftStorage.sol";
import "./Errors.sol";
import "./UserCumulativeStatLib.sol";
import "./RewardPoolStorage.sol";
import "./BeamioUserCardModuleMintLib.sol";
import "./IBeamioUserCardSelfDelegate.sol";
import "./BeamioUserCardInterfaces.sol";
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
    uint8 private constant MODULE_ISSUED_NFT = 2;
    uint8 private constant MODULE_CHARGE_REWARD = 5;

    bytes32 public constant RECORD_USER_LIKE_TYPEHASH = keccak256(
        "RecordUserLike(address cardAddress,address userEOA,uint8 targetKind,uint256 issuedParentId,bool liked,uint256 deadline,bytes32 nonce)"
    );
    bytes32 public constant RECORD_DISCOVER_SHARE_CLICK_TYPEHASH = keccak256(
        "RecordDiscoverShareClick(address cardAddress,address actorEOA,address refWallet,uint8 targetKind,uint256 issuedParentId,uint256 deadline,bytes32 nonce)"
    );
    bytes32 public constant CLAIM_SOCIAL_EXCHANGE_TYPEHASH = keccak256(
        "ClaimSocialExchange(address cardAddress,uint256 tokenId,uint256 pointsCost,uint256 usdcReward6,uint256 deadline,bytes32 nonce)"
    );

    event CardUserCumulativeStatTokensInitialized();
    event UserLikeAppliedWithSignature(
        address indexed userEOA,
        uint8 indexed targetKind,
        uint256 indexed issuedParentId,
        bool liked,
        bytes32 nonce
    );
    event DiscoverShareClickAppliedWithSignature(
        address indexed actorEOA,
        address indexed refWallet,
        uint8 indexed targetKind,
        uint256 issuedParentId,
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
    event SocialExchangeClaimedWithSignature(
        address indexed userEOA,
        uint256 indexed tokenId,
        uint256 pointsCost,
        uint256 usdcReward6,
        bytes32 nonce
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

    /// @notice Plan A: Discover share-link click (USER_CLICK + REF_CLICK) without Factory `gatewayInvokeCard`.
    /// @dev Domain verifyingContract = card `factoryGateway()` (CoNET Factory DOMAIN_SEPARATOR).
    ///      `refWallet` may be zero; REF_CLICK credits referrer when non-zero and distinct from actor.
    function applyDiscoverShareClickWithSignature(
        address actorEOA,
        address refWallet,
        uint8 targetKind,
        uint256 issuedParentId,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata userSignature
    ) external returns (uint256 userClickScopedTokenId, uint256 refClickScopedTokenId) {
        if (actorEOA == address(0)) revert BM_ZeroAddress();
        if (block.timestamp > deadline) revert UC_InvalidTimeWindow(block.timestamp, 0, deadline);
        if (!RewardPoolStorage.layout().cardUserStatTokensInitialized) revert UC_UserStatNotInitialized();
        if (targetKind != UserCumulativeStatLib.TARGET_MERCHANT_CARD_COUPON
            && targetKind != UserCumulativeStatLib.TARGET_ISSUED_COUPON) {
            revert UC_InvalidCumulativeTarget(targetKind, issuedParentId);
        }

        address gw = IUserCardCtx(address(this)).factoryGateway();
        if (gw == address(0)) revert BM_ZeroAddress();

        RewardPoolStorage.Layout storage rp = RewardPoolStorage.layout();
        bytes32 nonceKey = keccak256(abi.encode(actorEOA, nonce));
        if (rp.usedDiscoverShareClickNonces[nonceKey]) revert UC_NonceUsed();
        rp.usedDiscoverShareClickNonces[nonceKey] = true;

        bytes32 structHash = keccak256(
            abi.encode(
                RECORD_DISCOVER_SHARE_CLICK_TYPEHASH,
                address(this),
                actorEOA,
                refWallet,
                targetKind,
                issuedParentId,
                deadline,
                nonce
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            IBeamioUserCardFactoryEip712(gw).DOMAIN_SEPARATOR(),
            structHash
        );
        address signer = ECDSA.recover(digest, userSignature);
        if (signer != actorEOA) revert UC_InvalidSignature(signer, actorEOA);

        (, userClickScopedTokenId) = _recordUserLikeStat(
            actorEOA,
            UserCumulativeStatLib.METRIC_USER_CLICK,
            targetKind,
            issuedParentId,
            1
        );
        address refRecipient = (refWallet != address(0) && refWallet != actorEOA) ? refWallet : actorEOA;
        (, refClickScopedTokenId) = _recordUserLikeStat(
            refRecipient,
            UserCumulativeStatLib.METRIC_REF_CLICK,
            targetKind,
            issuedParentId,
            1
        );
        emit DiscoverShareClickAppliedWithSignature(actorEOA, refWallet, targetKind, issuedParentId, nonce);
    }

    /// @notice Plan A (CoNET legacy cards): user EIP-712 social exchange via card fallback → this module.
    /// @dev Relayer AA calls merchant card; AdminStats routes selector here. Burn/payout delegatecall ChargeReward module.
    function claimSocialExchangeWithUserSignature(
        address userEOA,
        uint256 tokenId,
        uint256 pointsCost,
        uint256 usdcReward6,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata userSignature
    ) external {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (block.timestamp > deadline) revert UC_InvalidTimeWindow(block.timestamp, 0, deadline);
        if (pointsCost == 0) revert UC_AmountZero();

        address gw = IUserCardCtx(address(this)).factoryGateway();
        if (gw == address(0)) revert BM_ZeroAddress();

        bytes32 nonceKey = keccak256(abi.encode(userEOA, nonce));
        if (IssuedNftStorage.layout().usedSocialExchangeClaimSigNonces[nonceKey]) revert UC_NonceUsed();
        IssuedNftStorage.layout().usedSocialExchangeClaimSigNonces[nonceKey] = true;

        bytes32 structHash = keccak256(
            abi.encode(CLAIM_SOCIAL_EXCHANGE_TYPEHASH, address(this), tokenId, pointsCost, usdcReward6, deadline, nonce)
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            IBeamioUserCardFactoryEip712(gw).DOMAIN_SEPARATOR(),
            structHash
        );
        address signer = ECDSA.recover(digest, userSignature);
        if (signer != userEOA) revert UC_InvalidSignature(signer, userEOA);

        _requireIssuedNftActive(tokenId);

        _delegateChargeModule(
            abi.encodeWithSelector(
                IBeamioChargeRewardModuleV2SocialExchange.burnSocialPointsFromUserForExchange.selector,
                userEOA,
                pointsCost
            )
        );

        if (usdcReward6 > 0) {
            _delegateChargeModule(
                abi.encodeWithSelector(
                    IBeamioChargeRewardModuleV2SocialExchange.payoutSocialExchangeUsdcToUser.selector,
                    userEOA,
                    usdcReward6
                )
            );
            IBeamioUserCardSelfDelegate(address(this)).cardSelfCallModule(
                MODULE_ISSUED_NFT,
                abi.encodeWithSelector(
                    IBeamioIssuedNftModuleV1.validateAndRecordSocialExchangeUsdcClaim.selector, userEOA, tokenId
                )
            );
        } else {
            address acct = IBeamioUserCardSelfDelegate(address(this)).cardSelfToAccount(userEOA);
            IBeamioUserCardSelfDelegate(address(this)).cardSelfCallModule(
                MODULE_ISSUED_NFT,
                abi.encodeWithSelector(
                    IBeamioIssuedNftModuleV1.validateAndRecordMintIssuedNftUserSigClaim.selector,
                    userEOA,
                    acct,
                    tokenId
                )
            );
            IBeamioUserCardSelfDelegate(address(this)).cardSelfMint(acct, tokenId, 1);
            IBeamioUserCardSelfDelegate(address(this)).cardSelfEmitIssuedNftMinted(tokenId, acct, 1);
        }

        emit SocialExchangeClaimedWithSignature(userEOA, tokenId, pointsCost, usdcReward6, nonce);
    }

    function _delegateChargeModule(bytes memory data) internal {
        address gw = IUserCardCtx(address(this)).factoryGateway();
        address chargeModule = IBeamioUserCardFactoryPaymasterV07(gw).defaultModule(MODULE_CHARGE_REWARD);
        if (chargeModule == address(0)) revert UC_ModuleZero(MODULE_CHARGE_REWARD);
        (bool ok, bytes memory ret) = chargeModule.delegatecall(data);
        if (!ok) _revertDelegate(ret);
    }

    function _revertDelegate(bytes memory data) internal pure {
        if (data.length > 0) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
        revert UC_RedeemDelegateFailed(data);
    }

    function _requireIssuedNftActive(uint256 tokenId) internal view {
        (bool ok, bytes memory ret) = address(this).staticcall(
            abi.encodeWithSelector(IBeamioIssuedNftModuleV1.isIssuedNftValid.selector, tokenId)
        );
        if (!ok || ret.length < 32 || !abi.decode(ret, (bool))) revert UC_IssuedNftInactive(tokenId);
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
            BeamioUserCardModuleMintLib.cardMint(wallet, globalStatTokenId, delta);
            scopedStatTokenId = 0;
            emit UserCumulativeStatRecorded(wallet, metricKind, targetKind, 0, globalStatTokenId, 0, delta);
            return (globalStatTokenId, 0);
        }

        globalStatTokenId = UserCumulativeStatLib.globalStatTokenId(metricKind);
        BeamioUserCardModuleMintLib.cardMint(wallet, globalStatTokenId, delta);

        if (targetKind == UserCumulativeStatLib.TARGET_MERCHANT_CARD_COUPON) {
            scopedStatTokenId = UserCumulativeStatLib.merchantCardStatTokenId(metricKind);
            BeamioUserCardModuleMintLib.cardMint(wallet, scopedStatTokenId, delta);
        } else if (targetKind == UserCumulativeStatLib.TARGET_ISSUED_COUPON) {
            _requireRealIssuedNft(issuedParentId);
            scopedStatTokenId = UserCumulativeStatLib.issuedCouponStatTokenId(issuedParentId, metricKind);
            _requireStatToken(scopedStatTokenId);
            BeamioUserCardModuleMintLib.cardMint(wallet, scopedStatTokenId, delta);
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
            _cardBurnWithLegacyFallback(wallet, globalStatTokenId, delta);
            scopedStatTokenId = 0;
            emit UserCumulativeStatRevoked(wallet, metricKind, targetKind, 0, globalStatTokenId, 0, delta);
            return (globalStatTokenId, 0);
        }

        globalStatTokenId = UserCumulativeStatLib.globalStatTokenId(metricKind);
        {
            uint256 balG = balanceOf(wallet, globalStatTokenId);
            if (delta > balG) revert UC_InsufficientBalance(wallet, globalStatTokenId, balG, delta);
            _cardBurnWithLegacyFallback(wallet, globalStatTokenId, delta);
        }

        if (targetKind == UserCumulativeStatLib.TARGET_MERCHANT_CARD_COUPON) {
            scopedStatTokenId = UserCumulativeStatLib.merchantCardStatTokenId(metricKind);
            uint256 balS = balanceOf(wallet, scopedStatTokenId);
            if (delta > balS) revert UC_InsufficientBalance(wallet, scopedStatTokenId, balS, delta);
            _cardBurnWithLegacyFallback(wallet, scopedStatTokenId, delta);
        } else if (targetKind == UserCumulativeStatLib.TARGET_ISSUED_COUPON) {
            _requireRealIssuedNft(issuedParentId);
            scopedStatTokenId = UserCumulativeStatLib.issuedCouponStatTokenId(issuedParentId, metricKind);
            _requireStatToken(scopedStatTokenId);
            uint256 balS = balanceOf(wallet, scopedStatTokenId);
            if (delta > balS) revert UC_InsufficientBalance(wallet, scopedStatTokenId, balS, delta);
            _cardBurnWithLegacyFallback(wallet, scopedStatTokenId, delta);
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
