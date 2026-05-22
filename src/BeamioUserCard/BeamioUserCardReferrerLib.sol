// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./ReferrerStorage.sol";
import "./ReferrerRegistryLib.sol";
import "./IBeamioUserCardSelfDelegate.sol";

interface IERC1155BalanceView {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/// @dev Referrer registry, pagination views, and token #1 reward minting (external library).
library BeamioUserCardReferrerLib {
    uint256 internal constant REFERRER_REWARD_TOKEN_ID = 1;
    uint256 internal constant REWARD_RATIO_ONE_E6 = 1_000_000;

    function registerReferee(address refereeAA) external {
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        if (r.isReferee[refereeAA]) revert UC_RefereeAlreadyRegistered(refereeAA);
        r.isReferee[refereeAA] = true;
        ReferrerRegistryLib.onRegisterReferee(r, refereeAA);
    }

    function unregisterReferee(address refereeAA) external {
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        if (!r.isReferee[refereeAA]) revert UC_RefereeNotRegistered(refereeAA);
        delete r.isReferee[refereeAA];
        ReferrerRegistryLib.onUnregisterReferee(r, refereeAA);
    }

    function setRefereeReferrer(address refereeAA, address referrerAA) external {
        if (refereeAA == referrerAA) revert UC_RefereeSelfReferrer(refereeAA);
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        if (!r.isReferee[refereeAA]) revert UC_RefereeNotRegistered(refereeAA);
        if (!r.isReferee[referrerAA]) revert UC_ReferrerNotRegistered(referrerAA);
        if (r.referrerOfReferee[referrerAA] == refereeAA) revert UC_RefereeReferrerCycle(refereeAA, referrerAA);
        ReferrerRegistryLib.onSetRefereeReferrer(r, refereeAA, referrerAA);
    }

    function clearRefereeReferrer(address refereeAA) external {
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        if (!r.isReferee[refereeAA]) revert UC_RefereeNotRegistered(refereeAA);
        ReferrerRegistryLib.onClearRefereeReferrer(r, refereeAA);
    }

    function getReferrersPage(uint256 offset, uint256 pageSize)
        external
        view
        returns (address[] memory referrers, uint256[] memory referrerRewardBalances, uint256 total, uint256 nextOffset)
    {
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        (referrers, total, nextOffset) = ReferrerRegistryLib.getReferrersPage(r, offset, pageSize);
        referrerRewardBalances = new uint256[](referrers.length);
        for (uint256 i = 0; i < referrers.length; i++) {
            referrerRewardBalances[i] = IERC1155BalanceView(address(this)).balanceOf(referrers[i], REFERRER_REWARD_TOKEN_ID);
        }
    }

    function getRefereesByReferrerPage(address referrerAA, uint256 offset, uint256 pageSize)
        external
        view
        returns (address[] memory referees, uint256[] memory refereeChargeTotals6, uint256 total, uint256 nextOffset)
    {
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        (referees, total, nextOffset) = ReferrerRegistryLib.getRefereesByReferrerPage(r, referrerAA, offset, pageSize);
        refereeChargeTotals6 = new uint256[](referees.length);
        for (uint256 i = 0; i < referees.length; i++) {
            refereeChargeTotals6[i] = r.refereeChargePointsTotal6[referees[i]];
        }
    }

    function getRegisteredRefereesPage(uint256 offset, uint256 pageSize)
        external
        view
        returns (address[] memory referees, uint256 total, uint256 nextOffset)
    {
        return ReferrerRegistryLib.getRegisteredRefereesPage(ReferrerStorage.layout(), offset, pageSize);
    }

    function recordRefereeChargePoints(address payerAcct, uint256 pointsAmount) external {
        if (payerAcct == address(0) || pointsAmount == 0) return;
        ReferrerStorage.layout().refereeChargePointsTotal6[payerAcct] += pointsAmount;
    }

    function mintReferrerRewardIfConfigured(IBeamioUserCardSelfDelegate delegate, address refereeAcct, uint256 chargeRewardAmount)
        external
    {
        if (refereeAcct == address(0) || chargeRewardAmount == 0) return;
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        if (!r.isReferee[refereeAcct]) return;
        address referrerAcct = r.referrerOfReferee[refereeAcct];
        if (referrerAcct == address(0) || !r.isReferee[referrerAcct]) return;
        uint256 referrerReward = calcReferrerRewardFromChargeReward(chargeRewardAmount);
        if (referrerReward == 0) return;
        delegate.cardSelfMint(referrerAcct, REFERRER_REWARD_TOKEN_ID, referrerReward);
        delegate.cardSelfEmitReferrerRewardMinted(refereeAcct, referrerAcct, referrerReward);
    }

    function calcReferrerRewardFromChargeReward(uint256 chargeRewardAmount) public view returns (uint256) {
        if (chargeRewardAmount == 0) return 0;
        uint256 ratio = ReferrerStorage.layout().referrerRewardFromChargeRewardRatioE6;
        if (ratio == 0) return 0;
        return (chargeRewardAmount * ratio) / REWARD_RATIO_ONE_E6;
    }

    function referrerTotalCount() external view returns (uint256) {
        return ReferrerRegistryLib.referrerTotalCount(ReferrerStorage.layout());
    }

    function refereeCountByReferrer(address referrerAA) external view returns (uint256) {
        return ReferrerRegistryLib.refereeCountByReferrer(ReferrerStorage.layout(), referrerAA);
    }

    function registeredRefereeTotalCount() external view returns (uint256) {
        return ReferrerRegistryLib.registeredRefereeTotalCount(ReferrerStorage.layout());
    }
}
