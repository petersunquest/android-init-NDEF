// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ChargeRewardModule.sol";
import "./Errors.sol";
import "./RewardPoolStorage.sol";
import "./UserCumulativeStatLib.sol";
import "./BeamioUserCardTransferLib.sol";
import "./BeamioUserCardReferrerLib.sol";
import "./IBeamioUserCardSelfDelegate.sol";
import "./IssuedNftStorage.sol";
import "./BeamioUserCardModuleMintLib.sol";
import "./TopupMintAmountCodec.sol";
import "./ChargeRewardStorage.sol";

interface ICardPoints {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

interface ICardPointsUnitPrice {
    function pointsUnitPriceInCurrencyE6() external view returns (uint256);
}

interface IFactoryOracleQuote {
    function quoteCurrencyAmountInUSDC6(uint8 cur, uint256 amount6) external view returns (uint256);
}

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
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
    event ConvertReward13ToPointsRatioUpdated(uint256 oldRatioE6, uint256 newRatioE6);
    event ConvertReward13ToUsdcRatioUpdated(uint256 oldRatioE6, uint256 newRatioE6);
    event MerchantOracleSpreadUpdated(uint256 oldSpreadBps, uint256 newSpreadBps);
    event Reward13ConvertedToProgramPoints(
        address indexed userEOA, address indexed userAcct, uint256 burn13, uint256 minted0
    );
    event Reward13ConvertedToUsdcToAa(
        address indexed userEOA, address indexed userAcct, uint256 burn13, uint256 usdcOut6, uint256 escrowAfter
    );
    event PeerReward13RedeemedForContainerTopup(
        address indexed userEOA,
        address indexed userAcct,
        address indexed targetCard,
        uint256 burn13,
        uint256 usdcOut6,
        uint256 escrowAfter
    );
    event TopupWithReward13Container(
        address indexed userEOA,
        address indexed userAcct,
        uint256 sameStoreBurn13,
        uint256 sameStoreMinted0,
        uint256 peerUsdcCredited6,
        uint256 pointsFromPeerUsdc6,
        uint256 minted0Total,
        bytes32 nonce
    );

    /// @dev Canonical CoNET mainnet USDC (TreasuryBridgeV3, 6 decimals).
    ///      This must remain aligned with chainAddresses.CONET_USDC.
    address public constant CONET_USDC_TOKEN = 0x5209865D404aA5646eDe5B91CD4218909eA72eDA;
    /// @dev Max merchant-favorable oracle spread: 1000 bps = 10%.
    uint256 public constant MAX_MERCHANT_ORACLE_SPREAD_BPS = 1000;

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

    /// @notice Same-cycle with top-up #0 mint: METRIC_TOPUP cumulative + proportional #13.
    /// @dev Actor: `amountFiat6 × topupActorRewardRatioE6 / 1e6` (Programs → Reward PT).
    ///      Referrer: `amountFiat6 × referrerRewardFromTopupAmountRatioE6 / 1e6`.
    ///      Base = 实付 paidPoints6→fiat only（不含 Top-up Promotion bonus #0）.
    ///      `points6` may be TopupMintAmountCodec-packed (total|paid) or legacy total;
    ///      legacy + `topupPromotionBonusRatioE6` derives paid = total * 1e6 / (1e6 + bonus).
    ///      Soft-skip when ratio/amount 0. Does **not** read Social Promotion `getRewardRule(2)`.
    function recordTopupCumulativeStat(address userEOA, uint256 points6) external onlyGatewayOrFactoryPaymaster {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        (uint256 totalPoints6, uint256 paidPoints6) = TopupMintAmountCodec.resolve(
            points6, ChargeRewardStorage.layout().topupPromotionBonusRatioE6
        );
        if (totalPoints6 == 0) revert UC_AmountZero();
        address gw = IUserCardCtx(address(this)).factoryGateway();
        address acct = BeamioUserCardTransferLib.toAccount(gw, userEOA);
        // Cumulative tracks full #0 mint (principal + promotion bonus).
        _mintCumulativeStat(acct, UserCumulativeStatLib.METRIC_TOPUP, UserCumulativeStatLib.TARGET_GLOBAL_ONLY, 0, totalPoints6);
        uint256 price = ICardPointsUnitPrice(address(this)).pointsUnitPriceInCurrencyE6();
        // Top-up #13 base = 实付 paidPoints6→fiat only（不含 promotion bonus #0）.
        uint256 amountFiat6 = price == 0 ? 0 : (paidPoints6 * price) / 1_000_000;
        if (amountFiat6 > 0) {
            uint256 actorReward = _calcTopupActorRewardAmount(amountFiat6);
            if (actorReward > 0) {
                // CHARGE_REWARD_TOKEN_ID == 13 (unified Reward PT).
                BeamioUserCardModuleMintLib.cardMint(acct, CHARGE_REWARD_TOKEN_ID, actorReward);
                emit ChargeRewardAirdropped(
                    userEOA, acct, IUserCardCurrency(address(this)).currency(), amountFiat6, actorReward
                );
            }
            BeamioUserCardReferrerLib.mintReferrerRewardForTopupIfConfigured(
                IBeamioUserCardSelfDelegate(address(this)), acct, amountFiat6
            );
        }
    }

    /// @notice Gateway: mint referrer #13 from charge amountFiat6 (upgradeable module path).
    /// @dev Mirrors top-up referrer mint. Actor consumption points (#13) stay on UpdateLib / mintChargeRewardByGateway.
    function recordChargeReferrerReward(address userEOA, uint256 amountFiat6)
        external
        onlyGatewayOrFactoryPaymaster
    {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (amountFiat6 == 0) revert UC_AmountZero();
        address gw = IUserCardCtx(address(this)).factoryGateway();
        address acct = BeamioUserCardTransferLib.toAccount(gw, userEOA);
        BeamioUserCardReferrerLib.mintReferrerRewardForChargeIfConfigured(
            IBeamioUserCardSelfDelegate(address(this)), acct, amountFiat6
        );
    }

    /// @notice referrer→referee ledger (topup/charge cumulative #13 + fiat). Routed via ChargeReward module.
    function getReferrerRefereeLedger(address referrer, address referee)
        external
        view
        returns (
            uint256 topupReward13E6,
            uint256 chargeReward13E6,
            uint256 topupAmountFiat6,
            uint256 chargeAmountFiat6
        )
    {
        return BeamioUserCardReferrerLib.getReferrerRefereeLedger(referrer, referee);
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

    // ─── Charge path: atomic #13 → #0 / #13 → Conet-USDC (to AA) + oracle spread ─

    function convertReward13ToPointsRatioE6() external view returns (uint256) {
        return ChargeRewardStorage.layout().convertReward13ToPointsRatioE6;
    }

    function convertReward13ToUsdcRatioE6() external view returns (uint256) {
        return ChargeRewardStorage.layout().convertReward13ToUsdcRatioE6;
    }

    function merchantOracleSpreadBps() external view returns (uint256) {
        return ChargeRewardStorage.layout().merchantOracleSpreadBps;
    }

    /// @notice USDC the user must pay for `fiatAmount6` of card currency (deposit / buy path).
    /// @dev fair = factory.quoteCurrencyAmountInUSDC6(currency, fiatAmount6);
    ///      with spread s: usdcNeeded = fair * 10000 / (10000 - s)  (ceil via +denom-1).
    function quoteUsdcDepositForFiat6(uint256 fiatAmount6) external view returns (uint256 usdcNeeded6) {
        return _quoteUsdcDepositForFiat6(fiatAmount6);
    }

    /// @notice USDC the user receives for `fiatAmount6` of card currency (withdraw / #13→USDC).
    /// @dev fair = factory quote; usdcOut = fair * (10000 - s) / 10000.
    function quoteUsdcWithdrawForFiat6(uint256 fiatAmount6) external view returns (uint256 usdcOut6) {
        return _quoteUsdcWithdrawForFiat6(fiatAmount6);
    }

    /// @notice Apply deposit spread to a fair USDC quote (merchant-favorable: user pays more).
    function applyDepositSpreadUsdc6(uint256 fairUsdc6) external view returns (uint256) {
        return _applyDepositSpreadUsdc6(fairUsdc6);
    }

    /// @notice Apply withdraw spread to a fair USDC quote (merchant-favorable: user receives less).
    function applyWithdrawSpreadUsdc6(uint256 fairUsdc6) external view returns (uint256) {
        return _applyWithdrawSpreadUsdc6(fairUsdc6);
    }

    function setConvertReward13ToPointsRatio(uint256 ratioE6) external onlyOwnerOrGateway {
        _setConvertReward13ToPointsRatio(ratioE6);
    }

    function setConvertReward13ToPointsRatioByAdmin(uint256 ratioE6) external onlyAdmin {
        _setConvertReward13ToPointsRatio(ratioE6);
    }

    function setConvertReward13ToUsdcRatio(uint256 ratioE6) external onlyOwnerOrGateway {
        _setConvertReward13ToUsdcRatio(ratioE6);
    }

    function setConvertReward13ToUsdcRatioByAdmin(uint256 ratioE6) external onlyAdmin {
        _setConvertReward13ToUsdcRatio(ratioE6);
    }

    function setMerchantOracleSpreadBps(uint256 spreadBps) external onlyOwnerOrGateway {
        _setMerchantOracleSpreadBps(spreadBps);
    }

    function setMerchantOracleSpreadBpsByAdmin(uint256 spreadBps) external onlyAdmin {
        _setMerchantOracleSpreadBps(spreadBps);
    }

    /// @notice Same-store: burn #13 from user AA and mint this card's #0 credit (card-currency 1:1).
    /// @dev Always allowed when price > 0. minted0 = burn13 * 1e6 / pointsUnitPriceInCurrencyE6.
    ///      Does not require convertReward13ToPointsRatioE6 or USDC escrow. Distinct from convertReward13ToUsdcToAa.
    function convertReward13ToProgramPoints(address userEOA, uint256 burn13)
        external
        onlyGatewayOrFactoryPaymaster
        returns (uint256 minted0)
    {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (burn13 == 0) revert UC_AmountZero();

        uint256 price = ICardPointsUnitPrice(address(this)).pointsUnitPriceInCurrencyE6();
        if (price == 0) revert UC_AmountZero();
        minted0 = (burn13 * 1_000_000) / price;
        if (minted0 == 0) revert UC_AmountZero();

        address gw = IUserCardCtx(address(this)).factoryGateway();
        address acct = BeamioUserCardTransferLib.toAccount(gw, userEOA);
        uint256 bal = balanceOf(acct, REWARD_VOUCHER_TOKEN_ID);
        if (burn13 > bal) revert UC_InsufficientBalance(acct, REWARD_VOUCHER_TOKEN_ID, bal, burn13);

        BeamioUserCardModuleMintLib.cardBurn(acct, REWARD_VOUCHER_TOKEN_ID, burn13);
        BeamioUserCardModuleMintLib.cardMint(acct, POINTS_ID, minted0);
        emit Reward13ConvertedToProgramPoints(userEOA, acct, burn13, minted0);
    }

    /// @notice Atomically burn #13 from user AA and pay Conet-USDC from escrow to the same AA.
    /// @dev Enable: convertReward13ToUsdcRatioE6 > 0. #13 is 1:1 with card currency fiat6;
    ///      usdcOut = withdraw-spread(oracle quote of burn13). Distinct from social exchange (pays EOA).
    ///      Fail-closed: escrow AND IERC20.balanceOf must cover usdcOut BEFORE any burn.
    function convertReward13ToUsdcToAa(address userEOA, uint256 burn13)
        external
        onlyGatewayOrFactoryPaymaster
        returns (uint256 usdcOut6)
    {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (burn13 == 0) revert UC_AmountZero();
        if (ChargeRewardStorage.layout().convertReward13ToUsdcRatioE6 == 0) revert UC_ChargeRewardDisabled();

        usdcOut6 = _quoteUsdcWithdrawForFiat6(burn13);
        if (usdcOut6 == 0) revert UC_OracleQuoteZero();

        address gw = IUserCardCtx(address(this)).factoryGateway();
        address acct = BeamioUserCardTransferLib.toAccount(gw, userEOA);
        uint256 bal = balanceOf(acct, REWARD_VOUCHER_TOKEN_ID);
        if (burn13 > bal) revert UC_InsufficientBalance(acct, REWARD_VOUCHER_TOKEN_ID, bal, burn13);

        _requireUsdcLiquidity(usdcOut6);

        RewardPoolStorage.Layout storage l = RewardPoolStorage.layout();
        BeamioUserCardModuleMintLib.cardBurn(acct, REWARD_VOUCHER_TOKEN_ID, burn13);
        l.escrowUsdc6 -= usdcOut6;
        bool ok = IERC20Minimal(CONET_USDC_TOKEN).transfer(acct, usdcOut6);
        if (!ok) revert UC_AmountZero();
        emit Reward13ConvertedToUsdcToAa(userEOA, acct, burn13, usdcOut6, l.escrowUsdc6);
    }

    /// @notice Third-party card leg of atomic multi-source top-up: burn #13 and pay quoted USDC to target card.
    /// @dev Fail-closed: escrow AND IERC20.balanceOf must cover usdcOut6 BEFORE burn.
    ///      usdcOut6 must equal withdraw-oracle quote of burn13 (no silent underpay).
    ///      USDC goes to targetCard (merchant program card), not user AA/EOA.
    function peerRedeem13ForContainerTopup(
        address userEOA,
        uint256 burn13,
        uint256 usdcOut6,
        address targetCard
    ) external onlyGatewayOrFactoryPaymaster returns (uint256 paidUsdc6) {
        if (userEOA == address(0) || targetCard == address(0)) revert BM_ZeroAddress();
        if (targetCard == address(this)) revert UC_AmountZero();
        if (burn13 == 0 || usdcOut6 == 0) revert UC_AmountZero();
        if (ChargeRewardStorage.layout().convertReward13ToUsdcRatioE6 == 0) revert UC_ChargeRewardDisabled();

        uint256 quoted = _quoteUsdcWithdrawForFiat6(burn13);
        if (quoted == 0) revert UC_OracleQuoteZero();
        if (usdcOut6 != quoted) revert UC_Slippage();

        address gw = IUserCardCtx(address(this)).factoryGateway();
        address acct = BeamioUserCardTransferLib.toAccount(gw, userEOA);
        uint256 bal = balanceOf(acct, REWARD_VOUCHER_TOKEN_ID);
        if (burn13 > bal) revert UC_InsufficientBalance(acct, REWARD_VOUCHER_TOKEN_ID, bal, burn13);

        _requireUsdcLiquidity(usdcOut6);

        RewardPoolStorage.Layout storage l = RewardPoolStorage.layout();
        BeamioUserCardModuleMintLib.cardBurn(acct, REWARD_VOUCHER_TOKEN_ID, burn13);
        l.escrowUsdc6 -= usdcOut6;
        bool ok = IERC20Minimal(CONET_USDC_TOKEN).transfer(targetCard, usdcOut6);
        if (!ok) revert UC_AmountZero();
        paidUsdc6 = usdcOut6;
        emit PeerReward13RedeemedForContainerTopup(userEOA, acct, targetCard, burn13, usdcOut6, l.escrowUsdc6);
    }

    /// @notice Target-card coordinator for atomic multi-source top-up (same Relayer AA executeBatch as peers).
    /// @dev Binds container nonce; same-store #13→#0; credits peer USDC into escrow and mints #0 for peer USDC.
    ///      Peer USDC must already have been transferred to this card in earlier batch legs.
    function topupWithReward13Container(
        address userEOA,
        uint256 sameStoreBurn13,
        uint256 peerUsdcCredited6,
        uint256 pointsFromPeerUsdc6,
        uint256 minTotalPointsOut0,
        uint256 deadline,
        bytes32 nonce
    ) external onlyGatewayOrFactoryPaymaster returns (uint256 minted0Total) {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (block.timestamp > deadline) revert UC_InvalidTimeWindow(block.timestamp, 0, deadline);
        if (sameStoreBurn13 == 0 && peerUsdcCredited6 == 0) revert UC_AmountZero();
        if (peerUsdcCredited6 > 0 && pointsFromPeerUsdc6 == 0) revert UC_AmountZero();

        bytes32 nonceKey = keccak256(abi.encode(userEOA, nonce));
        RewardPoolStorage.Layout storage l = RewardPoolStorage.layout();
        if (l.usedContainerTopupNonces[nonceKey]) revert UC_NonceUsed();
        l.usedContainerTopupNonces[nonceKey] = true;

        address gw = IUserCardCtx(address(this)).factoryGateway();
        address acct = BeamioUserCardTransferLib.toAccount(gw, userEOA);

        uint256 sameStoreMinted0;
        if (sameStoreBurn13 > 0) {
            uint256 price = ICardPointsUnitPrice(address(this)).pointsUnitPriceInCurrencyE6();
            if (price == 0) revert UC_AmountZero();
            sameStoreMinted0 = (sameStoreBurn13 * 1_000_000) / price;
            if (sameStoreMinted0 == 0) revert UC_AmountZero();
            uint256 bal = balanceOf(acct, REWARD_VOUCHER_TOKEN_ID);
            if (sameStoreBurn13 > bal) {
                revert UC_InsufficientBalance(acct, REWARD_VOUCHER_TOKEN_ID, bal, sameStoreBurn13);
            }
            BeamioUserCardModuleMintLib.cardBurn(acct, REWARD_VOUCHER_TOKEN_ID, sameStoreBurn13);
            BeamioUserCardModuleMintLib.cardMint(acct, POINTS_ID, sameStoreMinted0);
            emit Reward13ConvertedToProgramPoints(userEOA, acct, sameStoreBurn13, sameStoreMinted0);
        }

        if (peerUsdcCredited6 > 0) {
            uint256 tokenBal = IERC20Minimal(CONET_USDC_TOKEN).balanceOf(address(this));
            // Peer legs transfer USDC into this card first; require liquidity covers credited amount.
            if (tokenBal < peerUsdcCredited6) {
                revert UC_RewardBudgetInsufficient(peerUsdcCredited6, tokenBal);
            }
            l.escrowUsdc6 += peerUsdcCredited6;
            BeamioUserCardModuleMintLib.cardMint(acct, POINTS_ID, pointsFromPeerUsdc6);
        }

        minted0Total = sameStoreMinted0 + pointsFromPeerUsdc6;
        if (minted0Total < minTotalPointsOut0) revert UC_Slippage();

        // Same-cycle cumulative + proportional #13 (Programs Reward PT / Referrer), like recordTopupCumulativeStat.
        // Container path has no promotion bonus pack — paid == total.
        if (minted0Total > 0) {
            _mintCumulativeStat(
                acct, UserCumulativeStatLib.METRIC_TOPUP, UserCumulativeStatLib.TARGET_GLOBAL_ONLY, 0, minted0Total
            );
            uint256 price = ICardPointsUnitPrice(address(this)).pointsUnitPriceInCurrencyE6();
            uint256 amountFiat6 = price == 0 ? 0 : (minted0Total * price) / 1_000_000;
            if (amountFiat6 > 0) {
                uint256 actorReward = _calcTopupActorRewardAmount(amountFiat6);
                if (actorReward > 0) {
                    BeamioUserCardModuleMintLib.cardMint(acct, CHARGE_REWARD_TOKEN_ID, actorReward);
                    emit ChargeRewardAirdropped(
                        userEOA, acct, IUserCardCurrency(address(this)).currency(), amountFiat6, actorReward
                    );
                }
                BeamioUserCardReferrerLib.mintReferrerRewardForTopupIfConfigured(
                    IBeamioUserCardSelfDelegate(address(this)), acct, amountFiat6
                );
            }
        }

        emit TopupWithReward13Container(
            userEOA,
            acct,
            sameStoreBurn13,
            sameStoreMinted0,
            peerUsdcCredited6,
            pointsFromPeerUsdc6,
            minted0Total,
            nonce
        );
    }

    /// @dev Fail-closed USDC liquidity: both escrow accounting and ERC20 balance must cover `need`.
    function _requireUsdcLiquidity(uint256 need) internal view {
        RewardPoolStorage.Layout storage l = RewardPoolStorage.layout();
        if (l.escrowUsdc6 < need) revert UC_RewardBudgetInsufficient(need, l.escrowUsdc6);
        uint256 tokenBal = IERC20Minimal(CONET_USDC_TOKEN).balanceOf(address(this));
        if (tokenBal < need) revert UC_RewardBudgetInsufficient(need, tokenBal);
    }

    function _setConvertReward13ToPointsRatio(uint256 ratioE6) internal {
        ChargeRewardStorage.Layout storage l = ChargeRewardStorage.layout();
        uint256 old = l.convertReward13ToPointsRatioE6;
        l.convertReward13ToPointsRatioE6 = ratioE6;
        emit ConvertReward13ToPointsRatioUpdated(old, ratioE6);
    }

    function _setConvertReward13ToUsdcRatio(uint256 ratioE6) internal {
        ChargeRewardStorage.Layout storage l = ChargeRewardStorage.layout();
        uint256 old = l.convertReward13ToUsdcRatioE6;
        l.convertReward13ToUsdcRatioE6 = ratioE6;
        emit ConvertReward13ToUsdcRatioUpdated(old, ratioE6);
    }

    function _setMerchantOracleSpreadBps(uint256 spreadBps) internal {
        if (spreadBps > MAX_MERCHANT_ORACLE_SPREAD_BPS) {
            revert UC_OracleSpreadTooHigh(spreadBps, MAX_MERCHANT_ORACLE_SPREAD_BPS);
        }
        ChargeRewardStorage.Layout storage l = ChargeRewardStorage.layout();
        uint256 old = l.merchantOracleSpreadBps;
        l.merchantOracleSpreadBps = spreadBps;
        emit MerchantOracleSpreadUpdated(old, spreadBps);
    }

    function _fairUsdcForFiat6(uint256 fiatAmount6) internal view returns (uint256) {
        if (fiatAmount6 == 0) return 0;
        address gw = IUserCardCtx(address(this)).factoryGateway();
        uint8 cur = IUserCardCurrency(address(this)).currency();
        uint256 fair = IFactoryOracleQuote(gw).quoteCurrencyAmountInUSDC6(cur, fiatAmount6);
        if (fair == 0) revert UC_OracleQuoteZero();
        return fair;
    }

    function _applyDepositSpreadUsdc6(uint256 fairUsdc6) internal view returns (uint256) {
        if (fairUsdc6 == 0) return 0;
        uint256 s = ChargeRewardStorage.layout().merchantOracleSpreadBps;
        if (s == 0) return fairUsdc6;
        // Cap enforced on set (≤1000); guard against corrupt storage.
        if (s >= 10_000) revert UC_OracleSpreadTooHigh(s, MAX_MERCHANT_ORACLE_SPREAD_BPS);
        uint256 denom = 10_000 - s;
        // ceil: (fair * 10000 + denom - 1) / denom
        return (fairUsdc6 * 10_000 + denom - 1) / denom;
    }

    function _applyWithdrawSpreadUsdc6(uint256 fairUsdc6) internal view returns (uint256) {
        if (fairUsdc6 == 0) return 0;
        uint256 s = ChargeRewardStorage.layout().merchantOracleSpreadBps;
        if (s == 0) return fairUsdc6;
        return (fairUsdc6 * (10_000 - s)) / 10_000;
    }

    function _quoteUsdcDepositForFiat6(uint256 fiatAmount6) internal view returns (uint256) {
        return _applyDepositSpreadUsdc6(_fairUsdcForFiat6(fiatAmount6));
    }

    function _quoteUsdcWithdrawForFiat6(uint256 fiatAmount6) internal view returns (uint256) {
        return _applyWithdrawSpreadUsdc6(_fairUsdcForFiat6(fiatAmount6));
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
