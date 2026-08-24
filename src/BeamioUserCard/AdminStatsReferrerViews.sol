// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BeamioUserCardReferrerLib.sol";

/**
 * @title BeamioUserCardAdminStatsReferrerViews
 * @notice Standalone Referrer Registry **read** views (ROUTE_STATS_QUERY payload).
 * @dev Kept separate from AdminStats V5 so the factory can bind a tiny V6 **router**
 *      without exceeding EIP-170 (V5 alone is already ~24.0 KiB).
 */
contract BeamioUserCardAdminStatsReferrerViews {
    function referrerTotalCount() external view returns (uint256) {
        return BeamioUserCardReferrerLib.referrerTotalCount();
    }

    function registeredRefereeTotalCount() external view returns (uint256) {
        return BeamioUserCardReferrerLib.registeredRefereeTotalCount();
    }

    function refereeCountByReferrer(address referrerEOA) external view returns (uint256) {
        return BeamioUserCardReferrerLib.refereeCountByReferrer(referrerEOA);
    }

    function getReferrersPage(uint256 offset, uint256 pageSize)
        external
        view
        returns (address[] memory referrers, uint256[] memory referrerRewardBalances, uint256 total, uint256 nextOffset)
    {
        return BeamioUserCardReferrerLib.getReferrersPage(offset, pageSize);
    }

    function getRefereesByReferrerPage(address referrerEOA, uint256 offset, uint256 pageSize)
        external
        view
        returns (address[] memory referees, uint256[] memory refereeChargeTotals6, uint256 total, uint256 nextOffset)
    {
        return BeamioUserCardReferrerLib.getRefereesByReferrerPage(referrerEOA, offset, pageSize);
    }

    function getRegisteredRefereesPage(uint256 offset, uint256 pageSize)
        external
        view
        returns (address[] memory referees, uint256 total, uint256 nextOffset)
    {
        return BeamioUserCardReferrerLib.getRegisteredRefereesPage(offset, pageSize);
    }

    function refereeReferrer(address referee) external view returns (address) {
        return BeamioUserCardReferrerLib.refereeReferrer(referee);
    }

    function refereeChargePointsTotal6(address referee) external view returns (uint256) {
        return BeamioUserCardReferrerLib.refereeChargePointsTotal6(referee);
    }

    /// @notice Cumulative #13 + fiat bases for (referrer, referee).
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
}
