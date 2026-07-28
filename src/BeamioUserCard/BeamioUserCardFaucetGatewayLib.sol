// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./AdminStatsStorage.sol";
import "./FaucetStorage.sol";
import "./BeamioERC1155Logic.sol";
import "./BeamioUserCardInterfaces.sol";
import "./BeamioUserCardModuleKinds.sol";
import "./IBeamioUserCardSelfDelegate.sol";

library BeamioUserCardFaucetGatewayLib {
    uint256 internal constant POINTS_ID = BeamioERC1155Logic.POINTS_ID;
    uint8 internal constant MODULE_FAUCET = BeamioUserCardModuleKinds.FAUCET;
    uint8 internal constant MODULE_MEMBERSHIP_STATS = BeamioUserCardModuleKinds.MEMBERSHIP_STATS;

    function faucetByGateway(IBeamioUserCardSelfDelegate delegate, address userEOA, uint256 id, uint256 amount)
        external
    {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (amount == 0) revert UC_AmountZero();

        bytes memory data = delegate.cardSelfCallModule(
            MODULE_FAUCET,
            abi.encodeWithSelector(IBeamioFaucetModuleV1.validateAndRecordFreeFaucet.selector, userEOA, id, amount)
        );
        (uint256 outId, uint256 outAmount) = abi.decode(data, (uint256, uint256));

        address acct = delegate.cardSelfToAccount(userEOA);
        delegate.cardSelfCallModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.syncActiveToBestValid.selector, acct)
        );
        bool hadValidCard = delegate.cardSelfHasValidCard(acct);
        if (outId == POINTS_ID && outAmount > 0) {
            delegate.cardSelfRequirePointsMintAllowsFirstMembership(acct, outAmount);
        }
        delegate.cardSelfMint(acct, outId, outAmount);
        uint256 pointsDelta6 = (outId == POINTS_ID) ? outAmount : 0;
        (uint256 issuedBefore, uint256 upgradedBefore) = delegate.cardSelfMembershipFlowTotals();
        if (!hadValidCard) {
            if (pointsDelta6 > 0) {
                delegate.cardSelfCallModule(
                    MODULE_MEMBERSHIP_STATS,
                    abi.encodeWithSelector(
                        IBeamioMembershipStatsModuleV1.issueCardByPointsDelta_AssumingNoValidCard.selector,
                        acct,
                        pointsDelta6
                    )
                );
            }
        } else if (pointsDelta6 > 0) {
            delegate.cardSelfCallModule(
                MODULE_MEMBERSHIP_STATS,
                abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.maybeUpgrade.selector, acct, pointsDelta6)
            );
        }
        delegate.cardSelfRecordAdminMembershipFlow(delegate.cardSelfOwner(), issuedBefore, upgradedBefore);
        delegate.cardSelfEmitFaucetClaimed(
            outId, userEOA, acct, outAmount, FaucetStorage.layout().faucetClaimed[outId][userEOA]
        );
    }

    function mintFaucetByGateway(IBeamioUserCardSelfDelegate delegate, address userEOA, uint256 id, uint256 amount6)
        external
    {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (amount6 == 0) revert UC_AmountZero();

        bytes memory data = delegate.cardSelfCallModule(
            MODULE_FAUCET,
            abi.encodeWithSelector(IBeamioFaucetModuleV1.validateAndRecordPaidFaucet.selector, userEOA, id, amount6)
        );
        (uint256 outId, uint256 outAmount) = abi.decode(data, (uint256, uint256));

        address acct = delegate.cardSelfToAccount(userEOA);
        delegate.cardSelfCallModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.syncActiveToBestValid.selector, acct)
        );
        if (outId == POINTS_ID && outAmount > 0) {
            delegate.cardSelfRequirePointsMintAllowsFirstMembership(acct, outAmount);
        }
        delegate.cardSelfMint(acct, outId, outAmount);
        uint256 pointsDelta6 = (outId == POINTS_ID) ? outAmount : 0;
        if (pointsDelta6 > 0) {
            (uint256 issuedBefore, uint256 upgradedBefore) = delegate.cardSelfMembershipFlowTotals();
            delegate.cardSelfCallModule(
                MODULE_MEMBERSHIP_STATS,
                abi.encodeWithSelector(
                    IBeamioMembershipStatsModuleV1.maybeIssueOnlyIfNoneOrExpiredByPointsDelta.selector,
                    acct,
                    pointsDelta6
                )
            );
            delegate.cardSelfCallModule(
                MODULE_MEMBERSHIP_STATS,
                abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.maybeUpgrade.selector, acct, pointsDelta6)
            );
            delegate.cardSelfRecordAdminMembershipFlow(delegate.cardSelfOwner(), issuedBefore, upgradedBefore);
        }
        delegate.cardSelfEmitFaucetClaimed(
            outId, userEOA, acct, outAmount, FaucetStorage.layout().faucetClaimed[outId][userEOA]
        );
    }
}
