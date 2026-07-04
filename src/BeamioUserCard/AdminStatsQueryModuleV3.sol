// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AdminStatsQueryModuleV2.sol";
import "./UserCumulativeStatLib.sol";
import "./BeamioUserCardTypes.sol";
import "./BeamioUserCardInterfaces.sol";

interface ICardProgramHoldingsView {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function getOwnership(address user) external view returns (uint256 pt, NFTDetail[] memory nfts);
}

interface IBeamioAccountFactoryResolve {
    function beamioAccountOf(address eoa) external view returns (address);
}

/**
 * @title BeamioUserCardAdminStatsQueryModuleV3
 * @notice Adds `userHasAnyProgramAsset` — existence check with early exit (points, membership NFTs, L0/L1 stat tokens).
 */
contract BeamioUserCardAdminStatsQueryModuleV3 is BeamioUserCardAdminStatsQueryModuleV2 {
    uint8 private constant ROUTE_STATS_QUERY = type(uint8).max - 1;
    uint256 private constant POINTS_ID = 0;

    function selectorModuleKind(bytes4 sel) public pure override returns (uint8) {
        if (sel == bytes4(keccak256("userHasAnyProgramAsset(address)"))) {
            return ROUTE_STATS_QUERY;
        }
        return super.selectorModuleKind(sel);
    }

    /// @notice True when user holds any program asset on this card (AA points/membership and/or L0·L1 stat on EOA or AA).
    /// @dev Does not scan unbounded issued-coupon token ids; returns on first balance > 0.
    function userHasAnyProgramAsset(address userEOA) external view returns (bool) {
        ICardProgramHoldingsView card = ICardProgramHoldingsView(address(this));

        uint256[] memory ids = UserCumulativeStatLib.cardLevelStatTokenIds();
        for (uint256 i = 0; i < ids.length; i++) {
            if (card.balanceOf(userEOA, ids[i]) > 0) return true;
        }

        (address aa, bool hasAa) = _tryResolveAa(userEOA);
        if (hasAa) {
            if (aa != userEOA) {
                for (uint256 i = 0; i < ids.length; i++) {
                    if (card.balanceOf(aa, ids[i]) > 0) return true;
                }
            }
            (uint256 pt, NFTDetail[] memory nfts) = card.getOwnership(aa);
            if (pt > 0 || nfts.length > 0) return true;
            return false;
        }

        return card.balanceOf(userEOA, POINTS_ID) > 0;
    }

    function _tryResolveAa(address userEOA) internal view returns (address aa, bool hasAa) {
        address gw = IUserCardCtx(address(this)).factoryGateway();
        address aaFactory = IBeamioGatewayAAFactoryGetter(gw)._aaFactory();
        if (aaFactory == address(0)) return (userEOA, false);
        address a = IBeamioAccountFactoryResolve(aaFactory).beamioAccountOf(userEOA);
        if (a == address(0) || a.code.length == 0) return (userEOA, false);
        return (a, true);
    }
}
