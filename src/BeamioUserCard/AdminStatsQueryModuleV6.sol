// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAdminStatsSelectorRouter {
    function selectorModuleKind(bytes4 sel) external view returns (uint8);
}

/**
 * @title BeamioUserCardAdminStatsQueryModuleV6
 * @notice EIP-170-safe **router**: Referrer Registry reads → `referrerViews`;
 *         everything else → existing AdminStats V5 (membership fee, etc.).
 * @dev Card always `delegatecall`s `defaultAdminStatsQueryModule`. This router
 *      re-`delegatecall`s the correct impl so storage context stays the card.
 *      Closes V4/V5 gap where ShareReferee writes landed but read views were
 *      never routed → BM_CallFailed.
 */
contract BeamioUserCardAdminStatsQueryModuleV6 {
    uint8 private constant ROUTE_STATS_QUERY = type(uint8).max - 1;
    uint8 private constant ROUTE_CHARGE_REWARD = 5;

    address public immutable v5;
    address public immutable referrerViews;

    error ZeroImpl();

    constructor(address v5_, address referrerViews_) {
        if (v5_ == address(0) || referrerViews_ == address(0)) revert ZeroImpl();
        v5 = v5_;
        referrerViews = referrerViews_;
    }

    function selectorModuleKind(bytes4 sel) external view returns (uint8) {
        if (_isReferrerRegistryView(sel)) return ROUTE_STATS_QUERY;
        // Live V5 may predate Unified #13 / topupActor routes — hardcode here.
        if (_isChargeRewardUnified13(sel)) return ROUTE_CHARGE_REWARD;
        return IAdminStatsSelectorRouter(v5).selectorModuleKind(sel);
    }

    function _isReferrerRegistryView(bytes4 sel) private pure returns (bool) {
        return sel == bytes4(keccak256("referrerTotalCount()"))
            || sel == bytes4(keccak256("registeredRefereeTotalCount()"))
            || sel == bytes4(keccak256("refereeCountByReferrer(address)"))
            || sel == bytes4(keccak256("getReferrersPage(uint256,uint256)"))
            || sel == bytes4(keccak256("getRefereesByReferrerPage(address,uint256,uint256)"))
            || sel == bytes4(keccak256("getRegisteredRefereesPage(uint256,uint256)"))
            || sel == bytes4(keccak256("refereeReferrer(address)"))
            || sel == bytes4(keccak256("refereeChargePointsTotal6(address)"))
            || sel == bytes4(keccak256("getReferrerRefereeLedger(address,address)"));
    }

    function _isChargeRewardUnified13(bytes4 sel) private pure returns (bool) {
        return sel == bytes4(keccak256("topupActorRewardRatioE6()"))
            || sel == bytes4(keccak256("setTopupActorRewardRatio(uint256)"))
            || sel == bytes4(keccak256("setTopupActorRewardRatioByAdmin(uint256)"))
            || sel == bytes4(keccak256("recordTopupCumulativeStat(address,uint256)"))
            || sel == bytes4(keccak256("recordChargeReferrerReward(address,uint256)"));
    }

    fallback() external payable {
        address target = _isReferrerRegistryView(msg.sig) ? referrerViews : v5;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {
        revert();
    }
}
