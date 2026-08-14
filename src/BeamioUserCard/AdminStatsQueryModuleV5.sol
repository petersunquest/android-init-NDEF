// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AdminStatsQueryModuleV4.sol";
import "./MembershipFeeStorage.sol";
import "./MembershipFeeOpsLib.sol";

/**
 * @title BeamioUserCardAdminStatsQueryModuleV5
 * @notice Membership fee config + POS stage purchase (ROUTE_STATS_QUERY — works on existing cards).
 * @dev Heavy logic lives in MembershipFeeOpsLib (linked) to stay under EIP-170.
 */
contract BeamioUserCardAdminStatsQueryModuleV5 is BeamioUserCardAdminStatsQueryModuleV4 {
    uint8 private constant ROUTE_STATS_QUERY = type(uint8).max - 1;

    function selectorModuleKind(bytes4 sel) public pure virtual override returns (uint8) {
        if (
            sel == bytes4(keccak256("setMembershipFees(uint256[],uint8[])"))
                || sel == bytes4(keccak256("membershipFeeE6(uint256)"))
                || sel == bytes4(keccak256("membershipFeeDurationKind(uint256)"))
                || sel == bytes4(keccak256("membershipFees()"))
                || sel == bytes4(keccak256("membershipFeeMode()"))
                || sel == bytes4(keccak256("membershipFeePending(address)"))
                || sel == bytes4(keccak256("stageMembershipFeePurchase(address,uint256,uint256,uint256)"))
                || sel == bytes4(keccak256("clearMembershipFeePurchase(address)"))
        ) {
            return ROUTE_STATS_QUERY;
        }
        return super.selectorModuleKind(sel);
    }

    function setMembershipFees(uint256[] calldata feeE6, uint8[] calldata durationKind) external {
        MembershipFeeOpsLib.requireOwnerOrGateway();
        MembershipFeeOpsLib.setMembershipFees(feeE6, durationKind);
    }

    function membershipFeeE6(uint256 tierIndex) external view returns (uint256) {
        return MembershipFeeStorage.layout().feeE6[tierIndex];
    }

    function membershipFeeDurationKind(uint256 tierIndex) external view returns (uint8) {
        return MembershipFeeStorage.layout().durationKind[tierIndex];
    }

    function membershipFees() external view returns (uint256[] memory feeE6, uint8[] memory durationKind) {
        return MembershipFeeOpsLib.membershipFees();
    }

    function membershipFeeMode() external view returns (bool) {
        return MembershipFeeOpsLib.membershipFeeMode();
    }

    function membershipFeePending(address user)
        external
        view
        returns (uint256 tierIndex, uint256 feePaid6, uint256 pointsCredit6, uint64 deadline, bool active)
    {
        address acct = MembershipFeeOpsLib.resolveAcct(user);
        MembershipFeeStorage.PendingPurchase storage p = MembershipFeeStorage.layout().pendingByAcct[acct];
        return (p.tierIndex, p.feePaid6, p.pointsCredit6, p.deadline, p.active);
    }

    function stageMembershipFeePurchase(
        address user,
        uint256 tierIndex,
        uint256 feePaid6,
        uint256 pointsCredit6
    ) external {
        MembershipFeeOpsLib.requireGatewayOrPaymaster();
        MembershipFeeOpsLib.stageMembershipFeePurchase(user, tierIndex, feePaid6, pointsCredit6);
    }

    function clearMembershipFeePurchase(address user) external {
        MembershipFeeOpsLib.requireGatewayOrPaymaster();
        MembershipFeeOpsLib.clearMembershipFeePurchase(user);
    }
}
