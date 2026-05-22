// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./AdminStatsStorage.sol";
import "./BeamioERC1155Logic.sol";
import "./BeamioUserCardInterfaces.sol";
import "./BeamioUserCardModuleKinds.sol";
import "./BeamioUserCardTransferLib.sol";
import "./IBeamioUserCardSelfDelegate.sol";
import "./BeamioUserCardIssuedNftGatewayLib.sol";

library BeamioUserCardRedeemGatewayLib {
    uint256 internal constant POINTS_ID = BeamioERC1155Logic.POINTS_ID;
    uint256 internal constant ISSUED_NFT_START_ID = BeamioERC1155Logic.ISSUED_NFT_START_ID;
    uint8 internal constant MODULE_REDEEM = BeamioUserCardModuleKinds.REDEEM;
    uint8 internal constant MODULE_GOVERNANCE = BeamioUserCardModuleKinds.GOVERNANCE;
    uint8 internal constant MODULE_MEMBERSHIP_STATS = BeamioUserCardModuleKinds.MEMBERSHIP_STATS;

    function redeemAdminByGateway(IBeamioUserCardSelfDelegate delegate, string calldata code, address to, address module)
        external
    {
        if (to == address(0)) revert BM_ZeroAddress();
        bytes memory out = delegate.cardSelfCallModule(
            MODULE_REDEEM,
            abi.encodeWithSelector(IBeamioRedeemModuleVNext.consumeRedeemAdmin.selector, code)
        );
        (string memory metadata, uint256 mintLimit) = abi.decode(out, (string, uint256));
        uint256 newThreshold = 1;
        bool ok;
        if (mintLimit > 0) {
            ok = delegate.cardSelfGovernanceDelegate(
                module,
                abi.encodeWithSelector(
                    bytes4(keccak256("adminManager(address,bool,uint256,string,uint256)")),
                    to,
                    true,
                    newThreshold,
                    metadata,
                    mintLimit
                )
            );
        } else {
            ok = delegate.cardSelfGovernanceDelegate(
                module,
                abi.encodeWithSelector(
                    bytes4(keccak256("adminManager(address,bool,uint256,string)")),
                    to,
                    true,
                    newThreshold,
                    metadata
                )
            );
        }
        if (!ok) revert UC_InvalidProposal();
    }

    function redeemByGateway(IBeamioUserCardSelfDelegate delegate, string calldata code, address userEOA) external {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        (address creator, address recommender) = BeamioUserCardTransferLib.getRedeemCreatorAndRecommender(code);
        bytes memory data = delegate.cardSelfCallModule(
            MODULE_REDEEM,
            abi.encodeWithSelector(IBeamioRedeemModuleVNext.consumeRedeem.selector, code, userEOA)
        );
        (uint256 points6, uint256 attr, uint256[] memory tokenIds, uint256[] memory amounts) =
            abi.decode(data, (uint256, uint256, uint256[], uint256[]));
        attr;
        applyRedeemBundleToUser(delegate, userEOA, creator, recommender, points6, tokenIds, amounts, data);
    }

    function redeemBatchByGateway(IBeamioUserCardSelfDelegate delegate, string[] calldata codes, address userEOA)
        external
    {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (codes.length == 0) revert UC_InvalidProposal();
        (address creator, address recommender) =
            codes.length > 0 ? BeamioUserCardTransferLib.getRedeemCreatorAndRecommender(codes[0]) : (address(0), address(0));
        bytes memory data = delegate.cardSelfCallModule(
            MODULE_REDEEM,
            abi.encodeWithSelector(IBeamioRedeemModuleVNext.consumeRedeemBatch.selector, codes, userEOA)
        );
        (uint256 points6, uint256 attr, uint256[] memory tokenIds, uint256[] memory amounts) =
            abi.decode(data, (uint256, uint256, uint256[], uint256[]));
        attr;
        applyRedeemBundleToUser(delegate, userEOA, creator, recommender, points6, tokenIds, amounts, data);
    }

    function applyRedeemBundleToUser(
        IBeamioUserCardSelfDelegate delegate,
        address userEOA,
        address creator,
        address recommender,
        uint256 points6,
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        bytes memory redeemErrCtx
    ) public {
        if (tokenIds.length != amounts.length) revert UC_RedeemDelegateFailed(redeemErrCtx);

        address acct = delegate.cardSelfToAccount(userEOA);
        delegate.cardSelfCallModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.syncActiveToBestValid.selector, acct)
        );
        bool hasValidCard = delegate.cardSelfHasValidCard(acct);

        uint256 totalPoints6 = 0;
        bool pointsInBundle = false;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (tokenIds[i] == POINTS_ID) {
                totalPoints6 += amounts[i];
                pointsInBundle = true;
            }
        }
        if (!pointsInBundle) totalPoints6 = points6;

        if (totalPoints6 > 0) {
            delegate.cardSelfRequirePointsMintAllowsFirstMembership(acct, totalPoints6);
            delegate.cardSelfMint(acct, POINTS_ID, totalPoints6);
            delegate.cardSelfRecordAdminStatsMint(creator != address(0) ? creator : delegate.cardSelfOwner(), totalPoints6);
            delegate.cardSelfRecordAdminRedeemMint(recommender, totalPoints6);
        }

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 amt = amounts[i];
            if (amt == 0) revert UC_AmountZero();
            if (tokenIds[i] == POINTS_ID) continue;
            if (tokenIds[i] >= ISSUED_NFT_START_ID) {
                BeamioUserCardIssuedNftGatewayLib.mintIssuedNftChecked(delegate, acct, tokenIds[i], amt);
            } else {
                delegate.cardSelfMint(acct, tokenIds[i], amt);
            }
        }

        address statsOperator = creator != address(0) ? creator : delegate.cardSelfOwner();
        (uint256 issuedBefore, uint256 upgradedBefore) = delegate.cardSelfMembershipFlowTotals();
        if (!hasValidCard) {
            delegate.cardSelfCallModule(
                MODULE_MEMBERSHIP_STATS,
                abi.encodeWithSelector(
                    IBeamioMembershipStatsModuleV1.issueCardByPointsDelta_AssumingNoValidCard.selector, acct, totalPoints6
                )
            );
        } else {
            delegate.cardSelfCallModule(
                MODULE_MEMBERSHIP_STATS,
                abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.maybeUpgrade.selector, acct, totalPoints6)
            );
        }
        delegate.cardSelfRecordAdminMembershipFlow(statsOperator, issuedBefore, upgradedBefore);
    }
}
