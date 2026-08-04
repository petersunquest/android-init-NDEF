// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./AdminStatsStorage.sol";
import "./BeamioERC1155Logic.sol";
import "./BeamioUserCardInterfaces.sol";
import "./BeamioUserCardModuleKinds.sol";
import "./IBeamioUserCardSelfDelegate.sol";

library BeamioUserCardGatewayMintLib {
    uint256 internal constant POINTS_ID = BeamioERC1155Logic.POINTS_ID;
    uint8 internal constant MODULE_GOVERNANCE = BeamioUserCardModuleKinds.GOVERNANCE;
    uint8 internal constant MODULE_MEMBERSHIP_STATS = BeamioUserCardModuleKinds.MEMBERSHIP_STATS;

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
        if (points6 == 0) revert UC_AmountZero();

        address acct = delegate.cardSelfToAccount(userEOA);
        delegate.cardSelfCallModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.syncActiveToBestValid.selector, acct)
        );
        delegate.cardSelfRequirePointsMintAllowsFirstMembership(acct, points6);
        (uint256 issuedBefore, uint256 upgradedBefore) = delegate.cardSelfMembershipFlowTotals();
        delegate.cardSelfMint(acct, POINTS_ID, points6);
        _applyPointsMembershipSideEffects(delegate, acct, points6);
        delegate.cardSelfRecordAdminUsdcMint(operator, points6);
        delegate.cardSelfRecordAdminMembershipFlow(operator, issuedBefore, upgradedBefore);
        delegate.cardSelfEmitPointsMintedByGateway(userEOA, acct, points6);
    }

    function mintPointsByAdmin(IBeamioUserCardSelfDelegate delegate, address user, uint256 points6) external {
        if (user == address(0)) revert BM_ZeroAddress();
        if (points6 == 0) revert UC_AmountZero();

        address acct = delegate.cardSelfToAccount(user);
        delegate.cardSelfCallModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.syncActiveToBestValid.selector, acct)
        );
        delegate.cardSelfRequirePointsMintAllowsFirstMembership(acct, points6);
        (uint256 issuedBefore, uint256 upgradedBefore) = delegate.cardSelfMembershipFlowTotals();
        delegate.cardSelfMint(acct, POINTS_ID, points6);
        _applyPointsMembershipSideEffects(delegate, acct, points6);
        delegate.cardSelfRecordAdminMembershipFlow(delegate.cardSelfOwner(), issuedBefore, upgradedBefore);
        delegate.cardSelfEmitAdminPointsMinted(acct, points6);
    }

    function mintPointsByAdminWithOperator(
        IBeamioUserCardSelfDelegate delegate,
        address user,
        uint256 points6,
        address operator
    ) external {
        if (user == address(0) || operator == address(0)) revert BM_ZeroAddress();
        if (points6 == 0) revert UC_AmountZero();
        delegate.cardSelfCallModule(
            MODULE_GOVERNANCE,
            abi.encodeWithSelector(IBeamioGovernanceModuleV1.enforceAndRecordAdminAirdropLimit.selector, operator, points6)
        );

        address acct = delegate.cardSelfToAccount(user);
        delegate.cardSelfCallModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.syncActiveToBestValid.selector, acct)
        );
        delegate.cardSelfRequirePointsMintAllowsFirstMembership(acct, points6);
        (uint256 issuedBefore, uint256 upgradedBefore) = delegate.cardSelfMembershipFlowTotals();
        delegate.cardSelfMint(acct, POINTS_ID, points6);
        delegate.cardSelfRecordAdminStatsMint(operator, points6);
        _applyPointsMembershipSideEffects(delegate, acct, points6);
        delegate.cardSelfRecordAdminMembershipFlow(operator, issuedBefore, upgradedBefore);
        delegate.cardSelfEmitAdminPointsMinted(acct, points6);
    }
}
