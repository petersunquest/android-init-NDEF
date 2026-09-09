// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./AdminStatsStorage.sol";
import "./RedeemStorage.sol";
import "./BeamioERC1155Logic.sol";
import "./BeamioUserCardInterfaces.sol";
import "./BeamioUserCardModuleKinds.sol";
import "./IBeamioUserCardSelfDelegate.sol";

interface IRedeemGatewayCardOwner {
    function owner() external view returns (address);
}

/// @dev Linked library: gateway redeem-admin / redeem / redeemBatch (EIP-170 shrink).
library BeamioUserCardRedeemGatewayLib {
    uint256 internal constant POINTS_ID = BeamioERC1155Logic.POINTS_ID;
    uint256 internal constant ISSUED_NFT_START_ID = BeamioERC1155Logic.ISSUED_NFT_START_ID;
    uint8 internal constant MODULE_REDEEM = BeamioUserCardModuleKinds.REDEEM;
    uint8 internal constant MODULE_ISSUED_NFT = BeamioUserCardModuleKinds.ISSUED_NFT;
    uint8 internal constant MODULE_GOVERNANCE = BeamioUserCardModuleKinds.GOVERNANCE;
    uint8 internal constant MODULE_MEMBERSHIP_STATS = BeamioUserCardModuleKinds.MEMBERSHIP_STATS;

    function _getRedeemCreator(string calldata code) private view returns (address creator) {
        if (bytes(code).length == 0) return address(0);
        bytes32 hash = keccak256(bytes(code));
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.Redeem storage r = l.redeems[hash];
        if (r.active) return r.creator;
        RedeemStorage.RedeemPool storage p = l.pools[hash];
        if (p.active) return p.creator;
        return address(0);
    }

    function _getRedeemRecommender(string calldata code) private view returns (address recommender) {
        if (bytes(code).length == 0) return address(0);
        bytes32 hash = keccak256(bytes(code));
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.Redeem storage r = l.redeems[hash];
        if (r.active) return r.recommender;
        RedeemStorage.RedeemPool storage p = l.pools[hash];
        if (p.active) return p.recommender;
        return address(0);
    }

    function _mintIssuedNftChecked(IBeamioUserCardSelfDelegate delegate, address acct, uint256 tokenId, uint256 amount)
        private
    {
        delegate.cardSelfCallModule(
            MODULE_ISSUED_NFT,
            abi.encodeWithSelector(
                IBeamioIssuedNftModuleV1.validateAndRecordMintIssuedNft.selector, acct, tokenId, amount
            )
        );
        delegate.cardSelfMint(acct, tokenId, amount);
        delegate.cardSelfEmitIssuedNftMinted(tokenId, acct, amount);
    }

    function _peekGiftRedeemSplit(string calldata code)
        private
        view
        returns (bool isGift, uint256 membershipFeeE6, uint256 topupCreditE6)
    {
        if (bytes(code).length == 0) return (false, 0, 0);
        bytes32 hash = keccak256(bytes(code));
        RedeemStorage.GiftRedeemSplit storage g = RedeemStorage.layout().giftSplits[hash];
        return (g.isGift, uint256(g.membershipFeeE6), uint256(g.topupCreditE6));
    }

    function _applyRedeemMintsAndMembership(
        IBeamioUserCardSelfDelegate delegate,
        address acct,
        address userEOA,
        address creator,
        address recommender,
        uint256 points6,
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        bool isGift,
        uint256 giftMembershipFeeE6,
        uint256 giftTopupCreditE6
    ) private {
        if (tokenIds.length != amounts.length) revert UC_RedeemDelegateFailed("");

        delegate.cardSelfCallModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.syncActiveToBestValid.selector, acct)
        );
        bool hasValidCard = (delegate.cardSelfActiveMembershipId(acct) != 0);

        // Discover Gift redeem: fee/topup split (see giftSplits). Non-member → membership NFT from fee + #0 topup only.
        if (isGift && giftMembershipFeeE6 > 0) {
            uint256 credit6 = hasValidCard ? (giftMembershipFeeE6 + giftTopupCreditE6) : giftTopupCreditE6;
            if (credit6 > 0) {
                delegate.cardSelfMint(acct, POINTS_ID, credit6);
                address statsMintOp = creator != address(0) ? creator : IRedeemGatewayCardOwner(address(this)).owner();
                AdminStatsStorage.recordMint(statsMintOp, credit6);
                delegate.cardSelfRecordAdminRedeemMint(recommender, credit6);
            }
            address statsOperator = creator != address(0) ? creator : IRedeemGatewayCardOwner(address(this)).owner();
            (uint256 issuedBefore, uint256 upgradedBefore) = delegate.cardSelfMembershipFlowTotals();
            if (!hasValidCard) {
                // Issue base membership NFT (tierIndex 0) — do not use pending + issueCardByPointsDelta
                // (merchant fee metadata may change after gift purchase).
                delegate.cardSelfCallModule(
                    MODULE_MEMBERSHIP_STATS,
                    abi.encodeWithSelector(
                        IBeamioMembershipStatsModuleV1.mintMemberCardInternal.selector, userEOA, uint256(0)
                    )
                );
            } else if (credit6 > 0) {
                delegate.cardSelfCallModule(
                    MODULE_MEMBERSHIP_STATS,
                    abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.maybeUpgrade.selector, acct, credit6)
                );
            }
            delegate.cardSelfRecordAdminMembershipFlow(statsOperator, issuedBefore, upgradedBefore);
            return;
        }

        uint256 totalPoints6 = 0;
        bool pointsInBundle = false;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (tokenIds[i] == POINTS_ID) {
                totalPoints6 += amounts[i];
                pointsInBundle = true;
            }
        }
        if (!pointsInBundle) totalPoints6 = points6;

        // Gift without membership fee: full points6 (#0 principal + Multiplier) — skip min threshold gate
        // when isGift so purchased gift credit always lands.
        uint256 minReq = delegate.cardSelfMinThresholdPoints6();
        if (!isGift && !hasValidCard && minReq != 0 && totalPoints6 < minReq) revert UC_BelowMinThreshold();

        if (totalPoints6 > 0) {
            delegate.cardSelfMint(acct, POINTS_ID, totalPoints6);
            address statsMintOp = creator != address(0) ? creator : IRedeemGatewayCardOwner(address(this)).owner();
            AdminStatsStorage.recordMint(statsMintOp, totalPoints6);
            delegate.cardSelfRecordAdminRedeemMint(recommender, totalPoints6);
        }

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 amt = amounts[i];
            if (amt == 0) revert UC_AmountZero();
            if (tokenIds[i] == POINTS_ID) continue;
            if (tokenIds[i] >= ISSUED_NFT_START_ID) {
                _mintIssuedNftChecked(delegate, acct, tokenIds[i], amt);
            } else {
                delegate.cardSelfMint(acct, tokenIds[i], amt);
            }
        }

        address statsOperator2 = creator != address(0) ? creator : IRedeemGatewayCardOwner(address(this)).owner();
        (uint256 issuedBefore2, uint256 upgradedBefore2) = delegate.cardSelfMembershipFlowTotals();
        if (!hasValidCard) {
            delegate.cardSelfCallModule(
                MODULE_MEMBERSHIP_STATS,
                abi.encodeWithSelector(
                    IBeamioMembershipStatsModuleV1.issueCardByPointsDelta_AssumingNoValidCard.selector,
                    acct,
                    totalPoints6
                )
            );
        } else {
            delegate.cardSelfCallModule(
                MODULE_MEMBERSHIP_STATS,
                abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.maybeUpgrade.selector, acct, totalPoints6)
            );
        }
        delegate.cardSelfRecordAdminMembershipFlow(statsOperator2, issuedBefore2, upgradedBefore2);
    }

    function redeemAdminByGateway(IBeamioUserCardSelfDelegate delegate, string calldata code, address to) external {
        if (to == address(0)) revert BM_ZeroAddress();
        bytes memory out = delegate.cardSelfCallModule(
            MODULE_REDEEM, abi.encodeWithSelector(IBeamioRedeemModuleVNext.consumeRedeemAdmin.selector, code)
        );
        (string memory metadata, uint256 mintLimit) = abi.decode(out, (string, uint256));
        uint256 newThreshold = 1;
        if (mintLimit > 0) {
            delegate.cardSelfCallModule(
                MODULE_GOVERNANCE,
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
            delegate.cardSelfCallModule(
                MODULE_GOVERNANCE,
                abi.encodeWithSelector(
                    bytes4(keccak256("adminManager(address,bool,uint256,string)")), to, true, newThreshold, metadata
                )
            );
        }
    }

    function _redeemSingleByGateway(IBeamioUserCardSelfDelegate delegate, string calldata code, address userEOA)
        private
    {
        address creator = _getRedeemCreator(code);
        address recommender = _getRedeemRecommender(code);
        (bool isGift, uint256 giftFeeE6, uint256 giftTopupE6) = _peekGiftRedeemSplit(code);
        bytes memory data = delegate.cardSelfCallModule(
            MODULE_REDEEM, abi.encodeWithSelector(IBeamioRedeemModuleVNext.consumeRedeem.selector, code, userEOA)
        );
        (uint256 points6, uint256 attr, uint256[] memory tokenIds, uint256[] memory amounts) =
            abi.decode(data, (uint256, uint256, uint256[], uint256[]));
        attr;
        address acct = delegate.cardSelfToAccount(userEOA);
        _applyRedeemMintsAndMembership(
            delegate, acct, userEOA, creator, recommender, points6, tokenIds, amounts, isGift, giftFeeE6, giftTopupE6
        );
    }

    function redeemByGateway(IBeamioUserCardSelfDelegate delegate, string calldata code, address userEOA) external {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        _redeemSingleByGateway(delegate, code, userEOA);
    }

    function redeemBatchByGateway(IBeamioUserCardSelfDelegate delegate, string[] calldata codes, address userEOA)
        external
    {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (codes.length == 0) revert UC_InvalidProposal();
        // Discover Gift is single-code; batch of 1 uses gift fee/NFT split path.
        if (codes.length == 1) {
            _redeemSingleByGateway(delegate, codes[0], userEOA);
            return;
        }
        address creator = _getRedeemCreator(codes[0]);
        address recommender = _getRedeemRecommender(codes[0]);
        bytes memory data = delegate.cardSelfCallModule(
            MODULE_REDEEM, abi.encodeWithSelector(IBeamioRedeemModuleVNext.consumeRedeemBatch.selector, codes, userEOA)
        );
        (uint256 points6, uint256 attr, uint256[] memory tokenIds, uint256[] memory amounts) =
            abi.decode(data, (uint256, uint256, uint256[], uint256[]));
        attr;
        address acct = delegate.cardSelfToAccount(userEOA);
        _applyRedeemMintsAndMembership(
            delegate, acct, userEOA, creator, recommender, points6, tokenIds, amounts, false, 0, 0
        );
    }
}
