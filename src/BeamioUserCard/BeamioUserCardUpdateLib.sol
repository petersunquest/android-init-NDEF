// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./ChargeRewardStorage.sol";
import "./ReferrerStorage.sol";
import "./TotalSupplyStorage.sol";
import "./BeamioERC1155Logic.sol";
import "./BeamioUserCardTypes.sol";
import "./BeamioUserCardTransferLib.sol";
import "./BeamioUserCardInterfaces.sol";
import "./BeamioUserCardModuleKinds.sol";
import "./IBeamioUserCardSelfDelegate.sol";
import "./BeamioUserCardReferrerLib.sol";

/// @dev ERC1155 `_update` post-processing and charge-reward mint path.
library BeamioUserCardUpdateLib {
    uint256 internal constant POINTS_ID = BeamioERC1155Logic.POINTS_ID;
    uint256 internal constant POINTS_ONE = 1_000_000;
    uint256 internal constant CHARGE_REWARD_TOKEN_ID = 2;
    uint256 internal constant REWARD_RATIO_ONE_E6 = 1_000_000;
    uint256 internal constant NFT_START_ID = BeamioERC1155Logic.NFT_START_ID;
    uint256 internal constant ISSUED_NFT_START_ID = BeamioERC1155Logic.ISSUED_NFT_START_ID;
    uint8 internal constant MODULE_MEMBERSHIP_STATS = BeamioUserCardModuleKinds.MEMBERSHIP_STATS;

    function processUpdatePost(
        IBeamioUserCardSelfDelegate delegate,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values,
        UpdatePreResult memory pre
    ) external {
        bool isRealTransfer = (from != address(0) && to != address(0));
        if (isRealTransfer) {
            bool syncReceiverMembership;
            for (uint256 i = 0; i < ids.length; i++) {
                uint256 mid = ids[i];
                if (mid < NFT_START_ID || mid >= ISSUED_NFT_START_ID) continue;
                if (values[i] == 0) continue;
                delegate.cardSelfCallModule(
                    MODULE_MEMBERSHIP_STATS,
                    abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.removeNft.selector, from, mid)
                );
                delegate.cardSelfAppendMembershipNftIfMissing(pre.effectiveTo, mid);
                syncReceiverMembership = true;
            }
            if (syncReceiverMembership) {
                delegate.cardSelfCallModule(
                    MODULE_MEMBERSHIP_STATS,
                    abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.syncActiveToBestValid.selector, pre.effectiveTo)
                );
            }
        }
        if (isRealTransfer && (pre.pointTransferCount > 0 || pre.pointTransferAmount > 0)) {
            BeamioUserCardReferrerLib.recordRefereeChargePoints(from, pre.pointTransferAmount);
            mintChargeRewardForPointsDebit(delegate, from, pre.pointTransferAmount);
            BeamioUserCardTransferLib.recordPointTransferStats(
                from, to, pre.beneficiaryAdmin, pre.upperAdmin, pre.pointTransferCount, pre.pointTransferAmount,
                delegate.cardSelfOwner()
            );
        }

        if (delegate.cardSelfUpgradeType() == 2 && isRealTransfer) {
            delegate.cardSelfCallModule(
                MODULE_MEMBERSHIP_STATS,
                abi.encodeWithSelector(
                    IBeamioMembershipStatsModuleV1.handlePointsTransferForUpgradeType2.selector,
                    from,
                    pre.effectiveTo,
                    ids,
                    values
                )
            );
        }

        if (from == address(0)) {
            TotalSupplyStorage.Layout storage ts = TotalSupplyStorage.layout();
            for (uint256 i = 0; i < ids.length; i++) {
                uint256 v = values[i];
                ts.totalSupplyById[ids[i]] += v;
                ts.totalSupplyAll += v;
            }
        }

        if (to == address(0)) {
            TotalSupplyStorage.Layout storage ts = TotalSupplyStorage.layout();
            uint256 totalBurnValue = 0;
            for (uint256 i = 0; i < ids.length; i++) {
                uint256 v = values[i];
                unchecked {
                    ts.totalSupplyById[ids[i]] -= v;
                    totalBurnValue += v;
                }
            }
            unchecked { ts.totalSupplyAll -= totalBurnValue; }
        }

        for (uint256 i = 0; i < pre.burnedCount; i++) {
            delegate.cardSelfCallModule(
                MODULE_MEMBERSHIP_STATS,
                abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.removeNft.selector, pre.burnedFrom[i], pre.burnedIds[i])
            );
        }

        if (from != address(0)) {
            bool pointsLeaveFrom;
            for (uint256 i = 0; i < ids.length; i++) {
                if (ids[i] == POINTS_ID && values[i] > 0) {
                    pointsLeaveFrom = true;
                    break;
                }
            }
            if (pointsLeaveFrom && delegate.cardSelfUpgradeType() == 1) {
                delegate.cardSelfCallModule(
                    MODULE_MEMBERSHIP_STATS,
                    abi.encodeWithSelector(
                        IBeamioMembershipStatsModuleV1.alignMembershipTierToPointsBalance.selector, from, false
                    )
                );
            }
        }
    }

    function mintChargeRewardForPointsDebit(IBeamioUserCardSelfDelegate delegate, address payerAcct, uint256 pointsDebited6)
        public
    {
        if (payerAcct == address(0) || pointsDebited6 == 0) return;
        uint256 ratio = ChargeRewardStorage.layout().chargeRewardRatioE6;
        if (ratio == 0) return;

        uint256 price = delegate.cardSelfPointsUnitPriceInCurrencyE6();
        uint256 amountFiat6 = (pointsDebited6 * price) / POINTS_ONE;
        if (amountFiat6 == 0) return;
        uint256 reward = (amountFiat6 * ratio) / REWARD_RATIO_ONE_E6;
        if (reward == 0) return;

        delegate.cardSelfMint(payerAcct, CHARGE_REWARD_TOKEN_ID, reward);
        delegate.cardSelfEmitChargeRewardAirdropped(
            _ownerOfAccountOrSelf(payerAcct), payerAcct, delegate.cardSelfCurrencyType(), amountFiat6, reward
        );
        // Referrer #1 base = charge amountFiat6 (not token #2 reward).
        BeamioUserCardReferrerLib.mintReferrerRewardForChargeIfConfigured(delegate, payerAcct, amountFiat6);
    }

    function _ownerOfAccountOrSelf(address acct) private view returns (address) {
        if (acct.code.length == 0) return acct;
        (bool ok, bytes memory ret) = acct.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || ret.length < 32) return acct;
        address eoa = abi.decode(ret, (address));
        return eoa == address(0) ? acct : eoa;
    }
}
