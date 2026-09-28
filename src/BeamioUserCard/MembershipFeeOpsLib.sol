// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MembershipFeeStorage.sol";
import "./Errors.sol";

interface IUserCardMembershipFeeCtxLib {
    function owner() external view returns (address);
    function factoryGateway() external view returns (address);
    function tiers(uint256 index) external view returns (uint256 minUsdc6, uint256 attr, uint256 tierExpirySeconds, bool upgradeByBalance);
}

interface IUserCardFactoryPaymasterStatusLib {
    function isPaymaster(address account) external view returns (bool);
}

interface IBeamioAccountFactoryResolveLib {
    function isBeamioAccount(address account) external view returns (bool);
    function beamioAccountOf(address eoa) external view returns (address);
}

interface IUserCardFactoryAaOracleLib {
    function aaFactory() external view returns (address);
    function _aaFactory() external view returns (address);
}

/// @dev External library to keep AdminStatsQueryModuleV5 under EIP-170.
library MembershipFeeOpsLib {
    event MembershipFeesUpdated(uint256 tierCount);
    event MembershipFeePurchaseStaged(
        address indexed account,
        uint256 tierIndex,
        uint256 feePaid6,
        uint256 pointsCredit6,
        uint64 deadline
    );
    event MembershipFeePurchaseCleared(address indexed account);

    function _tiersLength() private view returns (uint256 n) {
        for (;;) {
            try IUserCardMembershipFeeCtxLib(address(this)).tiers(n) returns (uint256, uint256, uint256, bool) {
                unchecked {
                    ++n;
                }
            } catch {
                return n;
            }
        }
    }

    function _resolveAcct(address user) private view returns (address acct) {
        if (user == address(0)) revert BM_ZeroAddress();
        address gw = IUserCardMembershipFeeCtxLib(address(this)).factoryGateway();
        address aaFactory;
        try IUserCardFactoryAaOracleLib(gw)._aaFactory() returns (address f) {
            aaFactory = f;
        } catch {
            aaFactory = IUserCardFactoryAaOracleLib(gw).aaFactory();
        }
        if (aaFactory == address(0)) revert UC_GlobalMisconfigured();
        if (IBeamioAccountFactoryResolveLib(aaFactory).isBeamioAccount(user)) {
            return user;
        }
        acct = IBeamioAccountFactoryResolveLib(aaFactory).beamioAccountOf(user);
        if (acct == address(0)) revert UC_ResolveAccountFailed(user, aaFactory, acct);
        return acct;
    }

    function requireOwnerOrGateway() external view {
        address cardOwner = IUserCardMembershipFeeCtxLib(address(this)).owner();
        address gw = IUserCardMembershipFeeCtxLib(address(this)).factoryGateway();
        if (msg.sender != cardOwner && msg.sender != gw) revert BM_NotAuthorized();
    }

    function requireGatewayOrPaymaster() external view {
        address gw = IUserCardMembershipFeeCtxLib(address(this)).factoryGateway();
        if (msg.sender == gw) return;
        if (IUserCardFactoryPaymasterStatusLib(gw).isPaymaster(msg.sender)) return;
        revert UC_UnauthorizedGateway();
    }

    function resolveAcct(address user) external view returns (address) {
        return _resolveAcct(user);
    }

    function setMembershipFees(uint256[] calldata feeE6, uint8[] calldata durationKind) external {
        uint256 n = feeE6.length;
        if (n == 0 || n > MembershipFeeStorage.MAX_FEE_TIERS || durationKind.length != n) {
            revert UC_MembershipFeeLenMismatch();
        }
        MembershipFeeStorage.Layout storage l = MembershipFeeStorage.layout();
        uint256 priorFee;
        bool hasPrior;
        for (uint256 i = 0; i < n; i++) {
            bool active = MembershipFeeStorage.slotIsMembership(feeE6[i], durationKind[i]);
            if (active) {
                if (!MembershipFeeStorage.isValidDurationKind(durationKind[i])) revert UC_MembershipFeeInvalidDuration();
                if (hasPrior && feeE6[i] <= priorFee) revert UC_TiersNotIncreasing();
                l.feeE6[i] = feeE6[i];
                l.durationKind[i] = durationKind[i];
                priorFee = feeE6[i];
                hasPrior = true;
            } else {
                l.feeE6[i] = 0;
                l.durationKind[i] = MembershipFeeStorage.DURATION_NONE;
            }
        }
        emit MembershipFeesUpdated(n);
    }

    /**
     * @dev Constructor / BeaconProxy initializer helper. Linking the complete
     * validation loop keeps BeamioUserCard below EIP-170 while a newly created
     * direct-membership card still receives its full immutable-at-create fee
     * schedule in the same Factory transaction.
     */
    function configureInitialMembershipFees(uint256[] memory feeE6, uint8[] memory durationKind) external {
        uint256 n = feeE6.length;
        if (n == 0 || n > MembershipFeeStorage.MAX_FEE_TIERS || durationKind.length != n) {
            revert UC_MembershipFeeLenMismatch();
        }
        MembershipFeeStorage.Layout storage l = MembershipFeeStorage.layout();
        uint256 prior;
        for (uint256 i = 0; i < n; i++) {
            uint256 fee = feeE6[i];
            if (!MembershipFeeStorage.isValidDurationKind(durationKind[i])) {
                revert UC_MembershipFeeInvalidDuration();
            }
            if (i > 0 && fee <= prior) revert UC_TiersNotIncreasing();
            l.feeE6[i] = fee;
            l.durationKind[i] = durationKind[i];
            prior = fee;
        }
        emit MembershipFeesUpdated(n);
    }

    function membershipFees() external view returns (uint256[] memory feeE6, uint8[] memory durationKind) {
        uint256 chainN = _tiersLength();
        uint256 feeN = MembershipFeeStorage.feeTierCount();
        uint256 n = feeN > chainN ? feeN : chainN;
        feeE6 = new uint256[](n);
        durationKind = new uint8[](n);
        MembershipFeeStorage.Layout storage l = MembershipFeeStorage.layout();
        for (uint256 i = 0; i < n; i++) {
            feeE6[i] = l.feeE6[i];
            durationKind[i] = l.durationKind[i];
        }
    }

    function membershipFeeMode() external view returns (bool) {
        return MembershipFeeStorage.isFeeMode();
    }

    function stageMembershipFeePurchase(
        address user,
        uint256 tierIndex,
        uint256 feePaid6,
        uint256 pointsCredit6
    ) external {
        _stageMembershipFeePurchaseInternal(user, tierIndex, feePaid6, pointsCredit6, false, 0);
    }

    /// @dev Metadata-first cards may have fee/duration only in off-chain metadata until the first POS purchase.
    ///      When on-chain feeE6[tier] is zero, gateway/paymaster may bootstrap fee + duration from the purchase.
    function stageMembershipFeePurchaseWithBootstrap(
        address user,
        uint256 tierIndex,
        uint256 feePaid6,
        uint256 pointsCredit6,
        uint8 durationKind
    ) external {
        _stageMembershipFeePurchaseInternal(user, tierIndex, feePaid6, pointsCredit6, true, durationKind);
    }

    function _stageMembershipFeePurchaseInternal(
        address user,
        uint256 tierIndex,
        uint256 feePaid6,
        uint256 pointsCredit6,
        bool allowBootstrap,
        uint8 bootstrapDurationKind
    ) private {
        if (tierIndex >= MembershipFeeStorage.MAX_FEE_TIERS) revert UC_MustGrow();
        MembershipFeeStorage.Layout storage l = MembershipFeeStorage.layout();
        uint256 expectedFee = l.feeE6[tierIndex];
        if (expectedFee == 0) {
            bool freeClaim =
                feePaid6 == 0 && MembershipFeeStorage.isValidDurationKind(l.durationKind[tierIndex]);
            if (!freeClaim) {
                if (!allowBootstrap || feePaid6 == 0) revert UC_MembershipFeeMismatch();
                if (!MembershipFeeStorage.isValidDurationKind(bootstrapDurationKind)) revert UC_MembershipFeeInvalidDuration();
                l.feeE6[tierIndex] = feePaid6;
                l.durationKind[tierIndex] = bootstrapDurationKind;
                expectedFee = feePaid6;
            }
        } else {
            if (feePaid6 != expectedFee) revert UC_MembershipFeeMismatch();
            if (!MembershipFeeStorage.isValidDurationKind(l.durationKind[tierIndex])) revert UC_MembershipFeeInvalidDuration();
        }

        address acct = _resolveAcct(user);
        uint64 deadline = uint64(block.timestamp) + MembershipFeeStorage.PENDING_TTL_SECONDS;
        l.pendingByAcct[acct] = MembershipFeeStorage.PendingPurchase({
            tierIndex: tierIndex,
            feePaid6: feePaid6,
            pointsCredit6: pointsCredit6,
            deadline: deadline,
            active: true
        });
        emit MembershipFeePurchaseStaged(acct, tierIndex, feePaid6, pointsCredit6, deadline);
    }

    function clearMembershipFeePurchase(address user) external {
        address acct = _resolveAcct(user);
        delete MembershipFeeStorage.layout().pendingByAcct[acct];
        emit MembershipFeePurchaseCleared(acct);
    }

    /// @dev Kept external so AdminStats V5 does not inline the ChargeReward selector list (EIP-170).
    function isChargeRewardExtendedSelector(bytes4 sel) external pure returns (bool) {
        return sel == bytes4(keccak256("topupPromotionBonusRatioE6()"))
            || sel == bytes4(keccak256("setTopupPromotionBonusRatio(uint256)"))
            || sel == bytes4(keccak256("setTopupPromotionBonusRatioByAdmin(uint256)"))
            || sel == bytes4(keccak256("topupReward(uint256,uint256)"))
            || sel == bytes4(keccak256("topupReward(uint256,uint256,uint256)"))
            || sel == bytes4(keccak256("chargeReward(uint256,uint256)"))
            || sel == bytes4(keccak256("setBunitAirdropCaller(address)"))
            || sel == bytes4(keccak256("bunitAirdropCaller()"))
            || sel == bytes4(keccak256("recordBUnitInstallAttribution(address,address,uint8,uint256)"))
            || sel == bytes4(keccak256("convertReward13ToPointsRatioE6()"))
            || sel == bytes4(keccak256("convertReward13ToUsdcRatioE6()"))
            || sel == bytes4(keccak256("merchantOracleSpreadBps()"))
            || sel == bytes4(keccak256("quoteUsdcDepositForFiat6(uint256)"))
            || sel == bytes4(keccak256("quoteUsdcWithdrawForFiat6(uint256)"))
            || sel == bytes4(keccak256("applyDepositSpreadUsdc6(uint256)"))
            || sel == bytes4(keccak256("applyWithdrawSpreadUsdc6(uint256)"))
            || sel == bytes4(keccak256("setConvertReward13ToPointsRatio(uint256)"))
            || sel == bytes4(keccak256("setConvertReward13ToPointsRatioByAdmin(uint256)"))
            || sel == bytes4(keccak256("setConvertReward13ToUsdcRatio(uint256)"))
            || sel == bytes4(keccak256("setConvertReward13ToUsdcRatioByAdmin(uint256)"))
            || sel == bytes4(keccak256("setMerchantOracleSpreadBps(uint256)"))
            || sel == bytes4(keccak256("setMerchantOracleSpreadBpsByAdmin(uint256)"))
            || sel == bytes4(keccak256("convertReward13ToProgramPoints(address,uint256)"))
            || sel == bytes4(keccak256("convertReward13ToUsdcToAa(address,uint256)"))
            || sel == bytes4(keccak256("peerRedeem13ForContainerTopup(address,uint256,uint256,address)"))
            || sel == bytes4(keccak256("topupWithReward13Container(address,uint256,uint256,uint256,uint256,uint256,bytes32)"));
    }
}
