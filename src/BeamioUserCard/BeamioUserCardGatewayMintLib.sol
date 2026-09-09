// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./AdminStatsStorage.sol";
import "./BeamioERC1155Logic.sol";
import "./BeamioUserCardInterfaces.sol";
import "./BeamioUserCardModuleKinds.sol";
import "./IBeamioUserCardSelfDelegate.sol";
import "./MembershipFeeStorage.sol";
import "./TopupMintAmountCodec.sol";

interface IGatewayMintCardFactoryGw {
    function factoryGateway() external view returns (address);
    function owner() external view returns (address);
}

interface IGatewayMintFactoryChargeReward {
    function defaultChargeRewardModule() external view returns (address);
}

/// @dev Linked library: gateway / admin points mint + same-cycle top-up #13 via ChargeReward.recordTopupCumulativeStat.
library BeamioUserCardGatewayMintLib {
    uint256 internal constant POINTS_ID = BeamioERC1155Logic.POINTS_ID;
    uint8 internal constant MODULE_GOVERNANCE = BeamioUserCardModuleKinds.GOVERNANCE;
    uint8 internal constant MODULE_MEMBERSHIP_STATS = BeamioUserCardModuleKinds.MEMBERSHIP_STATS;
    uint8 internal constant MODULE_CHARGE_REWARD = BeamioUserCardModuleKinds.CHARGE_REWARD;

    function _chargeRewardModule() private view returns (address module) {
        address gw = IGatewayMintCardFactoryGw(address(this)).factoryGateway();
        if (gw == address(0) || gw.code.length == 0) return address(0);
        module = IGatewayMintFactoryChargeReward(gw).defaultChargeRewardModule();
    }

    /// @dev Same execution cycle as #0 mint: METRIC_TOPUP + proportional #13 via
    ///      ChargeReward.recordTopupCumulativeStat (topupActorRewardRatioE6 / referrer ratio E6).
    ///      Passes raw `points6` (may be TopupMintAmountCodec-packed); ChargeReward unpacks paid for #13.
    /// Direct module DELEGATECALL keeps msg.sender = Factory gateway (onlyGatewayOrFactoryPaymaster).
    /// Soft-fail: #0 top-up must not revert when #13 ratio path fails.
    function _recordTopupCumulativeStatInSameCall(address userEOA, uint256 points6Raw) private {
        address module = _chargeRewardModule();
        if (module == address(0) || module.code.length == 0) return;
        (bool ok,) = module.delegatecall(
            abi.encodeWithSelector(
                bytes4(keccak256("recordTopupCumulativeStat(address,uint256)")), userEOA, points6Raw
            )
        );
        ok; // intentionally ignore — do not block #0 mint
    }

    /// @dev Unpack total for #0 mint / limits / membership; keep raw for #13 path.
    function _totalPoints6(uint256 points6Raw) private pure returns (uint256) {
        (uint256 total,) = TopupMintAmountCodec.unpack(points6Raw);
        return total;
    }

    function _applyPointsMembershipSideEffects(IBeamioUserCardSelfDelegate delegate, address acct, uint256 points6)
        private
    {
        delegate.cardSelfCallModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(
                IBeamioMembershipStatsModuleV1.maybeIssueOnlyIfNoneOrExpiredByPointsDelta.selector, acct, points6
            )
        );
        delegate.cardSelfCallModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.maybeUpgrade.selector, acct, points6)
        );
    }

    function mintPointsByGatewayWithOperator(
        IBeamioUserCardSelfDelegate delegate,
        address userEOA,
        uint256 points6,
        address operator
    ) external {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (operator == address(0)) revert BM_ZeroAddress();
        uint256 totalPoints6 = _totalPoints6(points6);
        if (totalPoints6 == 0) revert UC_AmountZero();

        address acct = delegate.cardSelfToAccount(userEOA);
        delegate.cardSelfCallModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.syncActiveToBestValid.selector, acct)
        );
        delegate.cardSelfRequirePointsMintAllowsFirstMembership(acct, totalPoints6);
        (uint256 issuedBefore, uint256 upgradedBefore) = delegate.cardSelfMembershipFlowTotals();
        delegate.cardSelfMint(acct, POINTS_ID, totalPoints6);
        _applyPointsMembershipSideEffects(delegate, acct, totalPoints6);
        delegate.cardSelfRecordAdminUsdcMint(operator, totalPoints6);
        delegate.cardSelfRecordAdminMembershipFlow(operator, issuedBefore, upgradedBefore);
        _recordTopupCumulativeStatInSameCall(userEOA, points6);
        delegate.cardSelfEmitPointsMintedByGateway(userEOA, acct, totalPoints6);
    }

    function mintPointsByAdmin(IBeamioUserCardSelfDelegate delegate, address user, uint256 points6) external {
        if (user == address(0)) revert BM_ZeroAddress();
        uint256 totalPoints6 = _totalPoints6(points6);
        if (totalPoints6 == 0) {
            if (!MembershipFeeStorage.isFeeMode()) revert UC_AmountZero();
            address membershipAcct = delegate.cardSelfToAccount(user);
            (uint256 issuedBefore, uint256 upgradedBefore) = delegate.cardSelfMembershipFlowTotals();
            delegate.cardSelfCallModule(
                MODULE_MEMBERSHIP_STATS,
                abi.encodeWithSelector(
                    IBeamioMembershipStatsModuleV1.maybeIssueOnlyIfNoneOrExpiredByPointsDelta.selector,
                    membershipAcct,
                    0
                )
            );
            delegate.cardSelfRecordAdminMembershipFlow(
                IGatewayMintCardFactoryGw(address(this)).owner(), issuedBefore, upgradedBefore
            );
            return;
        }

        address acct = delegate.cardSelfToAccount(user);
        delegate.cardSelfCallModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.syncActiveToBestValid.selector, acct)
        );
        delegate.cardSelfRequirePointsMintAllowsFirstMembership(acct, totalPoints6);
        (uint256 issuedBefore, uint256 upgradedBefore) = delegate.cardSelfMembershipFlowTotals();
        delegate.cardSelfMint(acct, POINTS_ID, totalPoints6);
        _applyPointsMembershipSideEffects(delegate, acct, totalPoints6);
        delegate.cardSelfRecordAdminMembershipFlow(
            IGatewayMintCardFactoryGw(address(this)).owner(), issuedBefore, upgradedBefore
        );
        // Owner-direct mint: ChargeReward gateway auth fails → soft-skip #13 (ok).
        _recordTopupCumulativeStatInSameCall(user, points6);
        delegate.cardSelfEmitAdminPointsMinted(acct, totalPoints6);
    }

    function mintPointsByAdminWithOperator(
        IBeamioUserCardSelfDelegate delegate,
        address user,
        uint256 points6,
        address operator
    ) external {
        if (user == address(0) || operator == address(0)) revert BM_ZeroAddress();
        uint256 totalPoints6 = _totalPoints6(points6);
        if (totalPoints6 == 0) {
            if (!MembershipFeeStorage.isFeeMode()) revert UC_AmountZero();
            address membershipAcct = delegate.cardSelfToAccount(user);
            (uint256 issuedBefore, uint256 upgradedBefore) = delegate.cardSelfMembershipFlowTotals();
            delegate.cardSelfCallModule(
                MODULE_MEMBERSHIP_STATS,
                abi.encodeWithSelector(
                    IBeamioMembershipStatsModuleV1.maybeIssueOnlyIfNoneOrExpiredByPointsDelta.selector,
                    membershipAcct,
                    0
                )
            );
            delegate.cardSelfRecordAdminMembershipFlow(operator, issuedBefore, upgradedBefore);
            return;
        }
        delegate.cardSelfCallModule(
            MODULE_GOVERNANCE,
            abi.encodeWithSelector(
                IBeamioGovernanceModuleV1.enforceAndRecordAdminAirdropLimit.selector, operator, totalPoints6
            )
        );

        address acct = delegate.cardSelfToAccount(user);
        delegate.cardSelfCallModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.syncActiveToBestValid.selector, acct)
        );
        delegate.cardSelfRequirePointsMintAllowsFirstMembership(acct, totalPoints6);
        (uint256 issuedBefore, uint256 upgradedBefore) = delegate.cardSelfMembershipFlowTotals();
        delegate.cardSelfMint(acct, POINTS_ID, totalPoints6);
        delegate.cardSelfRecordAdminStatsMint(operator, totalPoints6);
        _applyPointsMembershipSideEffects(delegate, acct, totalPoints6);
        delegate.cardSelfRecordAdminMembershipFlow(operator, issuedBefore, upgradedBefore);
        // NFC / POS top-up via Factory executeForAdmin — #0 + #13 (paid base) in this call.
        _recordTopupCumulativeStatInSameCall(user, points6);
        delegate.cardSelfEmitAdminPointsMinted(acct, totalPoints6);
    }
}
