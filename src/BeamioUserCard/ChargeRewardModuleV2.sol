// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ChargeRewardModule.sol";
import "./Errors.sol";
import "./RewardPoolStorage.sol";
import "./UserCumulativeStatLib.sol";
import "./BeamioUserCardTransferLib.sol";
import "./IssuedNftStorage.sol";
import "./BeamioUserCardModuleMintLib.sol";

interface ICardPoints {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/**
 * @title BeamioUserCardChargeRewardModuleV2
 * @notice Kind 5 extension: #13 reward pool, event dispatch, burn-funded programs, charge/topup cumulative.
 */
contract BeamioUserCardChargeRewardModuleV2 is BeamioUserCardChargeRewardModuleV1 {
    uint256 public constant REWARD_VOUCHER_TOKEN_ID = UserCumulativeStatLib.REWARD_VOUCHER_TOKEN_ID;
    uint256 private constant POINTS_ID = 0;

    event RewardRuleConfigured(uint256 indexed ruleId, uint8 eventKind, uint8 targetKind, uint256 issuedParentId);
    event RewardProgramFunded(
        address indexed payerEOA,
        address indexed payerAcct,
        uint8 assetKind,
        uint256 amount,
        uint256 faceValue6,
        uint256 budget13Added
    );
    event RewardVoucher13Minted(address indexed wallet, uint256 amount, uint256 ruleId);
    event BunitInstallAttributionRecorded(
        address indexed claimant,
        address indexed referrer,
        uint8 targetKind,
        uint256 issuedParentId
    );
    event SocialExchangeUsdcEscrowFunded(address indexed payerEOA, uint256 amount6, uint256 escrowAfter);
    event SocialPointsBurnedForExchange(address indexed userEOA, address indexed userAcct, uint256 pointsCost);
    event SocialExchangeUsdcPaid(address indexed userEOA, uint256 usdcReward6, uint256 escrowAfter);

    /// @dev CoNET mainnet CONET-USDC (6 decimals); merchant program cards are CoNET-only.
    address public constant CONET_USDC_TOKEN = 0xF9240fd613C00d5C479f1E9f1690130c5Fdc8BC3;

    address public bunitAirdropCaller;

    function setBunitAirdropCaller(address caller) external onlyOwnerOrGateway {
        bunitAirdropCaller = caller;
    }

    /// @notice BUnitAirdrop 首次 claim 成功后回调：记「安装」累计统计（#3/#4 KPI）。
    ///         须在卡上 `initializeCardUserCumulativeStatTokens()` 且 `setBunitAirdropCaller(BUnitAirdrop)`。
    function recordBUnitInstallAttribution(
        address claimant,
        address referrer,
        uint8 targetKind,
        uint256 issuedParentId
    ) external {
        if (msg.sender != bunitAirdropCaller) revert UC_BunitAirdropCallerOnly();
        if (claimant == address(0)) revert BM_ZeroAddress();
        address gw = IUserCardCtx(address(this)).factoryGateway();
        address acct = BeamioUserCardTransferLib.toAccount(gw, claimant);
        _mintCumulativeStat(acct, UserCumulativeStatLib.METRIC_INSTALL, targetKind, issuedParentId, 1);
        if (referrer != address(0) && referrer != claimant) {
            address refAcct = BeamioUserCardTransferLib.toAccount(gw, referrer);
            _mintCumulativeStat(
                refAcct, UserCumulativeStatLib.METRIC_REF_INSTALL, targetKind, issuedParentId, 1
            );
        }
        emit BunitInstallAttributionRecorded(claimant, referrer, targetKind, issuedParentId);
    }

    function rewardMintBudget13() external view returns (uint256) {
        return RewardPoolStorage.layout().rewardMintBudget13;
    }

    function rewardEscrowUsdc6() external view returns (uint256) {
        return RewardPoolStorage.layout().escrowUsdc6;
    }

    function rewardEscrowPoints6() external view returns (uint256) {
        return RewardPoolStorage.layout().escrowPoints6;
    }

    function getRewardRule(uint256 ruleId)
        external
        view
        returns (
            bool active,
            uint8 eventKind,
            uint8 targetKind,
            uint256 issuedParentId,
            uint256 actorMint13,
            uint256 refMint13
        )
    {
        RewardPoolStorage.EventRewardRule storage r = RewardPoolStorage.layout().rules[ruleId];
        return (r.active, r.eventKind, r.targetKind, r.issuedParentId, r.actorMint13, r.refMint13);
    }

    struct EventRewardRuleConfig {
        uint256 ruleId;
        bool active;
        uint8 eventKind;
        uint8 targetKind;
        uint256 issuedParentId;
        uint256 actorMint13;
        uint256 refMint13;
    }

    function _writeEventRewardRule(
        RewardPoolStorage.Layout storage l,
        uint256 ruleId,
        bool active,
        uint8 eventKind,
        uint8 targetKind,
        uint256 issuedParentId,
        uint256 actorMint13,
        uint256 refMint13
    ) private returns (uint256 id) {
        id = ruleId;
        if (id == 0) {
            id = ++l.nextRuleId;
        }
        l.rules[id] = RewardPoolStorage.EventRewardRule({
            active: active,
            eventKind: eventKind,
            targetKind: targetKind,
            issuedParentId: issuedParentId,
            actorMint13: actorMint13,
            refMint13: refMint13
        });
        emit RewardRuleConfigured(id, eventKind, targetKind, issuedParentId);
    }

    function configureEventRewardRule(
        uint256 ruleId,
        bool active,
        uint8 eventKind,
        uint8 targetKind,
        uint256 issuedParentId,
        uint256 actorMint13,
        uint256 refMint13
    ) external onlyOwnerOrGateway {
        _writeEventRewardRule(
            RewardPoolStorage.layout(),
            ruleId,
            active,
            eventKind,
            targetKind,
            issuedParentId,
            actorMint13,
            refMint13
        );
    }

    /// @notice Batch configure event reward rules in one card call (one executeForOwner / gateway relay).
    function configureEventRewardRulesBatch(EventRewardRuleConfig[] calldata configs)
        external
        onlyOwnerOrGateway
    {
        RewardPoolStorage.Layout storage l = RewardPoolStorage.layout();
        uint256 len = configs.length;
        for (uint256 i = 0; i < len; ) {
            EventRewardRuleConfig calldata c = configs[i];
            _writeEventRewardRule(
                l,
                c.ruleId,
                c.active,
                c.eventKind,
                c.targetKind,
                c.issuedParentId,
                c.active ? c.actorMint13 : 0,
                c.active ? c.refMint13 : 0
            );
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Fund #13 mint budget. #2/#13 burn immediately (not recycled). #0 credits escrow + budget.
    function purchaseRewardProgram(
        address payerEOA,
        uint8 assetKind,
        uint256 amount,
        uint256 budget13PerUnit,
        uint8 cumulativeTargetKind,
        uint256 cumulativeIssuedParentId
    ) external onlyGatewayOrFactoryPaymaster returns (uint256 budget13Added) {
        if (payerEOA == address(0)) revert BM_ZeroAddress();
        if (amount == 0) revert UC_AmountZero();
        if (budget13PerUnit == 0) revert UC_AmountZero();

        address gw = IUserCardCtx(address(this)).factoryGateway();
        address payerAcct = BeamioUserCardTransferLib.toAccount(gw, payerEOA);
        uint256 faceValue6 = amount;

        if (assetKind == RewardPoolStorage.ASSET_CHARGE_REWARD2) {
            uint256 bal = balanceOf(payerAcct, CHARGE_REWARD_TOKEN_ID);
            if (amount > bal) revert UC_InsufficientBalance(payerAcct, CHARGE_REWARD_TOKEN_ID, bal, amount);
            BeamioUserCardModuleMintLib.cardBurn(payerAcct, CHARGE_REWARD_TOKEN_ID, amount);
        } else if (assetKind == RewardPoolStorage.ASSET_VOUCHER13) {
            uint256 bal = balanceOf(payerAcct, REWARD_VOUCHER_TOKEN_ID);
            if (amount > bal) revert UC_InsufficientBalance(payerAcct, REWARD_VOUCHER_TOKEN_ID, bal, amount);
            BeamioUserCardModuleMintLib.cardBurn(payerAcct, REWARD_VOUCHER_TOKEN_ID, amount);
        } else if (assetKind == RewardPoolStorage.ASSET_POINTS0) {
            uint256 bal = ICardPoints(address(this)).balanceOf(payerAcct, POINTS_ID);
            if (amount > bal) revert UC_InsufficientBalance(payerAcct, POINTS_ID, bal, amount);
            BeamioUserCardModuleMintLib.cardBurn(payerAcct, POINTS_ID, amount);
            RewardPoolStorage.layout().escrowPoints6 += amount;
        } else {
            revert UC_AmountZero();
        }

        budget13Added = amount * budget13PerUnit;
        RewardPoolStorage.layout().rewardMintBudget13 += budget13Added;

        _recordPurchaseCumulative(payerAcct, cumulativeTargetKind, cumulativeIssuedParentId, faceValue6);

        emit RewardProgramFunded(payerEOA, payerAcct, assetKind, amount, faceValue6, budget13Added);
    }

    /// @notice Mint #13 to actor/ref when a configured event fires. Gateway only.
    function dispatchEventReward13(
        uint256 ruleId,
        address actorWallet,
        address refWallet,
        uint8 cumulativeTargetKind,
        uint256 cumulativeIssuedParentId,
        uint256 cumulativeDelta
    ) external onlyGatewayOrFactoryPaymaster returns (uint256 actorMinted, uint256 refMinted) {
        RewardPoolStorage.Layout storage l = RewardPoolStorage.layout();
        RewardPoolStorage.EventRewardRule storage rule = l.rules[ruleId];
        if (!rule.active) revert UC_RewardRuleInactive(ruleId);

        uint256 need = 0;
        if (actorWallet != address(0) && rule.actorMint13 > 0) need += rule.actorMint13;
        if (refWallet != address(0) && rule.refMint13 > 0) need += rule.refMint13;
        if (need == 0) return (0, 0);
        // Social promotion #13 rewards are minted on event (no pre-funded rewardMintBudget13 required).

        if (actorWallet != address(0) && rule.actorMint13 > 0) {
            BeamioUserCardModuleMintLib.cardMint(actorWallet, REWARD_VOUCHER_TOKEN_ID, rule.actorMint13);
            actorMinted = rule.actorMint13;
            emit RewardVoucher13Minted(actorWallet, actorMinted, ruleId);
        }
        if (refWallet != address(0) && rule.refMint13 > 0) {
            BeamioUserCardModuleMintLib.cardMint(refWallet, REWARD_VOUCHER_TOKEN_ID, rule.refMint13);
            refMinted = rule.refMint13;
            emit RewardVoucher13Minted(refWallet, refMinted, ruleId);
        }

        if (cumulativeDelta > 0 && actorWallet != address(0)) {
            _recordEventCumulative(
                actorWallet, rule.eventKind, cumulativeTargetKind, cumulativeIssuedParentId, cumulativeDelta
            );
        }
        if (cumulativeDelta > 0 && refWallet != address(0)) {
            _recordEventCumulative(
                refWallet, _refMetricForEvent(rule.eventKind), cumulativeTargetKind, cumulativeIssuedParentId, cumulativeDelta
            );
        }
    }

    function mintChargeRewardByGateway(address userEOA, uint256 amountFiat6, uint8 chargeCurrency)
        external
        override
        onlyGateway
    {
        super._mintChargeRewardByGateway(userEOA, amountFiat6, chargeCurrency);
        address gw = IUserCardCtx(address(this)).factoryGateway();
        address acct = BeamioUserCardTransferLib.toAccount(gw, userEOA);
        _mintCumulativeStat(acct, UserCumulativeStatLib.METRIC_CHARGE, UserCumulativeStatLib.TARGET_GLOBAL_ONLY, 0, amountFiat6);
    }

    function recordTopupCumulativeStat(address userEOA, uint256 points6) external onlyGatewayOrFactoryPaymaster {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (points6 == 0) revert UC_AmountZero();
        address gw = IUserCardCtx(address(this)).factoryGateway();
        address acct = BeamioUserCardTransferLib.toAccount(gw, userEOA);
        _mintCumulativeStat(acct, UserCumulativeStatLib.METRIC_TOPUP, UserCumulativeStatLib.TARGET_GLOBAL_ONLY, 0, points6);
    }

    /// @notice Merchant owner funds CONET-USDC escrow for social-points → USDC exchange activities.
    function fundSocialExchangeUsdcEscrow(address payerEOA, uint256 amount6) external onlyGatewayOrFactoryPaymaster {
        if (payerEOA == address(0)) revert BM_ZeroAddress();
        if (amount6 == 0) revert UC_AmountZero();
        bool ok = IERC20Minimal(CONET_USDC_TOKEN).transferFrom(payerEOA, address(this), amount6);
        if (!ok) revert UC_AmountZero();
        RewardPoolStorage.Layout storage l = RewardPoolStorage.layout();
        l.escrowUsdc6 += amount6;
        emit SocialExchangeUsdcEscrowFunded(payerEOA, amount6, l.escrowUsdc6);
    }

    /// @notice Burn #13 social points from user AA account before social exchange claim completes.
    function burnSocialPointsFromUserForExchange(address userEOA, uint256 pointsCost) external onlyGatewayOrFactoryPaymaster {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (pointsCost == 0) revert UC_AmountZero();
        address gw = IUserCardCtx(address(this)).factoryGateway();
        address acct = BeamioUserCardTransferLib.toAccount(gw, userEOA);
        uint256 bal = balanceOf(acct, REWARD_VOUCHER_TOKEN_ID);
        if (pointsCost > bal) revert UC_InsufficientBalance(acct, REWARD_VOUCHER_TOKEN_ID, bal, pointsCost);
        BeamioUserCardModuleMintLib.cardBurn(acct, REWARD_VOUCHER_TOKEN_ID, pointsCost);
        emit SocialPointsBurnedForExchange(userEOA, acct, pointsCost);
    }

    /// @notice Pay CONET-USDC from card escrow to user EOA after social points burn (USDC exchange activity).
    function payoutSocialExchangeUsdcToUser(address userEOA, uint256 usdcReward6) external onlyGatewayOrFactoryPaymaster {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (usdcReward6 == 0) revert UC_AmountZero();
        RewardPoolStorage.Layout storage l = RewardPoolStorage.layout();
        if (l.escrowUsdc6 < usdcReward6) revert UC_RewardBudgetInsufficient(usdcReward6, l.escrowUsdc6);
        l.escrowUsdc6 -= usdcReward6;
        bool ok = IERC20Minimal(CONET_USDC_TOKEN).transfer(userEOA, usdcReward6);
        if (!ok) revert UC_AmountZero();
        emit SocialExchangeUsdcPaid(userEOA, usdcReward6, l.escrowUsdc6);
    }

    function _recordPurchaseCumulative(
        address wallet,
        uint8 targetKind,
        uint256 issuedParentId,
        uint256 faceValue6
    ) private {
        _mintCumulativeStat(wallet, UserCumulativeStatLib.METRIC_USER_PURCHASE, targetKind, issuedParentId, faceValue6);
    }

    function _recordEventCumulative(
        address wallet,
        uint8 metricKind,
        uint8 targetKind,
        uint256 issuedParentId,
        uint256 delta
    ) private {
        if (metricKind == 0) return;
        _mintCumulativeStat(wallet, metricKind, targetKind, issuedParentId, delta);
    }

    function _refMetricForEvent(uint8 eventKind) private pure returns (uint8) {
        if (eventKind == UserCumulativeStatLib.METRIC_USER_CLICK) return UserCumulativeStatLib.METRIC_REF_CLICK;
        if (eventKind == UserCumulativeStatLib.METRIC_USER_COMMENT) return UserCumulativeStatLib.METRIC_REF_COMMENT;
        if (eventKind == UserCumulativeStatLib.METRIC_USER_LIKE) return UserCumulativeStatLib.METRIC_REF_LIKE;
        if (eventKind == UserCumulativeStatLib.METRIC_USER_PURCHASE) return UserCumulativeStatLib.METRIC_REF_PURCHASE;
        if (eventKind == UserCumulativeStatLib.METRIC_REF_CLAIM) return UserCumulativeStatLib.METRIC_REF_CLAIM;
        if (eventKind == UserCumulativeStatLib.METRIC_REF_BURN) return UserCumulativeStatLib.METRIC_REF_BURN;
        if (eventKind == UserCumulativeStatLib.METRIC_INSTALL) return UserCumulativeStatLib.METRIC_REF_INSTALL;
        return 0;
    }

    function _mintCumulativeStat(
        address wallet,
        uint8 metricKind,
        uint8 targetKind,
        uint256 issuedParentId,
        uint256 delta
    ) private {
        if (!RewardPoolStorage.layout().cardUserStatTokensInitialized) return;
        uint256 globalId = UserCumulativeStatLib.globalStatTokenId(metricKind);
        BeamioUserCardModuleMintLib.cardMint(wallet, globalId, delta);
        if (targetKind == UserCumulativeStatLib.TARGET_MERCHANT_CARD_COUPON) {
            BeamioUserCardModuleMintLib.cardMint(wallet, UserCumulativeStatLib.merchantCardStatTokenId(metricKind), delta);
        } else if (targetKind == UserCumulativeStatLib.TARGET_ISSUED_COUPON && issuedParentId != 0) {
            uint256 scoped = UserCumulativeStatLib.issuedCouponStatTokenId(issuedParentId, metricKind);
            if (IssuedNftStorage.layout().issuedNftIsStatToken[scoped]) {
                BeamioUserCardModuleMintLib.cardMint(wallet, scoped, delta);
            }
        }
    }
}
