// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {NodeBundle} from "../ValidatorDepositRedeemTypes.sol";

/// @dev Mock gb token: every IConetGB1155Income view returns 0 (mirrors live behavior for this beneficiary).
contract MockGbZero {
    function balanceOf(address, uint256) external pure returns (uint256) { return 0; }
    function nodeTotalIssued(address) external pure returns (uint256) { return 0; }
    function nodeIssuedThisHourOf(address) external pure returns (uint256) { return 0; }
    function nodeIssuedTodayOf(address) external pure returns (uint256) { return 0; }
    function nodeIssuedThisWeekOf(address) external pure returns (uint256) { return 0; }
    function nodeIssuedThisMonthOf(address) external pure returns (uint256) { return 0; }
    function nodeIssuedThisYearOf(address) external pure returns (uint256) { return 0; }
    function issuedThisHourOf(address) external pure returns (uint256) { return 0; }
    function issuedTodayOf(address) external pure returns (uint256) { return 0; }
    function issuedThisWeekOf(address) external pure returns (uint256) { return 0; }
    function issuedThisMonthOf(address) external pure returns (uint256) { return 0; }
    function issuedThisYearOf(address) external pure returns (uint256) { return 0; }
}

/// @dev Mock reward indexer: summaries return all zero.
contract MockIdxZero {
    function getNodeRewardSummary(address, uint256)
        external pure returns (uint256, uint256, uint256, uint256, uint256, uint256)
    { return (0, 0, 0, 0, 0, 0); }
    function getBeneficiaryRewardSummary(address, uint256)
        external pure returns (uint256, uint256, uint256, uint256, uint256, uint256)
    { return (0, 0, 0, 0, 0, 0); }
}

/// @dev Mock reader that reproduces the exact live resolveNodeBundle output for beneficiary 0x2D31...fCE8.
contract MockUnifiedReader {
    address public immutable gbToken;
    address public immutable rewardIndexer;
    address private immutable _ben;
    address private immutable _w0;
    address private immutable _w1;

    constructor(address gb, address idx, address ben, address w0, address w1) {
        gbToken = gb;
        rewardIndexer = idx;
        _ben = ben;
        _w0 = w0;
        _w1 = w1;
    }

    function resolveNodeBundle(address, string calldata) external view returns (NodeBundle memory b) {
        b.beneficiary = _ben;
        b.guardianNodeIds = new uint256[](2);
        b.guardianNodeIds[0] = 100;
        b.guardianNodeIds[1] = 101;
        b.depinNodeIps = new string[](2);
        b.depinNodeIps[0] = "217.160.189.159";
        b.depinNodeIps[1] = "93.93.112.187";
        b.nodeWallets = new address[](2);
        b.nodeWallets[0] = _w0;
        b.nodeWallets[1] = _w1;
        b.validatorPubkeys = new bytes[](2);
        b.validatorPubkeys[0] = hex"8b19b871d48111f98e0b77be93c2b85eb6b80a0623c9a467cc73bbe1d5c4fd6c84b5499de06ed591845d671981c2c4ab";
        b.validatorPubkeys[1] = hex"";
        b.validatorActive = new bool[](2);
        b.validatorActive[0] = true;
        b.validatorActive[1] = false;
        b.validatorNodeCount = 2;
        b.gbMiningNodeCount = 2;
        b.claimCount = 2;
        b.nativeBalance = 0;
        b.gbBalance = 0;
        b.usdcBalance = 0;
    }
}
