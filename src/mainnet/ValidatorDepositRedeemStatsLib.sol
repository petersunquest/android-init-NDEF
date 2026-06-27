// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {NodeBundle} from "./ValidatorDepositRedeemTypes.sol";

/// @dev Per-subject GB + CNET income totals (18 decimals). {cumulative} for GB beneficiary = net id=0 balance;
///      for GB node = gross {nodeTotalIssued}; for CNET = reward indexer cumulative.
struct IncomeTotals {
    uint256 cumulative;
    uint256 hour;
    uint256 day;
    uint256 week;
    uint256 month;
    uint256 year;
}

/// @dev One DePIN node row: parallel GB (on-chain mint stats) + CNET (reward indexer stats).
struct NodeIncomeRow {
    address nodeWallet;
    string depinNodeIp;
    IncomeTotals gb;
    IncomeTotals cnet;
}

/// @dev Unified beneficiary income snapshot: beneficiary-level totals + per-node breakdown.
struct UnifiedIncomeStats {
    address beneficiary;
    IncomeTotals gbBeneficiary;
    IncomeTotals cnetBeneficiary;
    NodeIncomeRow[] nodes;
}

/// @dev ConetGB1155 income views used by {ValidatorDepositRedeemStatsLib} (issueGBForNode node buckets + wallet buckets).
interface IConetGB1155Income {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function nodeTotalIssued(address node) external view returns (uint256);
    function nodeIssuedThisHourOf(address node) external view returns (uint256);
    function nodeIssuedTodayOf(address node) external view returns (uint256);
    function nodeIssuedThisWeekOf(address node) external view returns (uint256);
    function nodeIssuedThisMonthOf(address node) external view returns (uint256);
    function nodeIssuedThisYearOf(address node) external view returns (uint256);
    function issuedThisHourOf(address account) external view returns (uint256);
    function issuedTodayOf(address account) external view returns (uint256);
    function issuedThisWeekOf(address account) external view returns (uint256);
    function issuedThisMonthOf(address account) external view returns (uint256);
    function issuedThisYearOf(address account) external view returns (uint256);
}

/// @dev ValidatorNodeRewardIndexer summary views (off-chain measured CNET rewards).
interface IRewardIndexerSummary {
    function getNodeRewardSummary(address nodeWallet, uint256 anchorTs)
        external
        view
        returns (uint256 cumulative, uint256 hour, uint256 day, uint256 week, uint256 month, uint256 year);

    function getBeneficiaryRewardSummary(address beneficiary, uint256 anchorTs)
        external
        view
        returns (uint256 cumulative, uint256 hour, uint256 day, uint256 week, uint256 month, uint256 year);
}

/// @dev Minimal read surface on {ValidatorDepositRedeem} used by {resolveUnifiedFromRedeem}.
interface IRedeemUnifiedReader {
    function resolveNodeBundle(address maybeWallet, string calldata conetDepinNodeIp)
        external
        view
        returns (NodeBundle memory);

    function gbToken() external view returns (address);

    function rewardIndexer() external view returns (address);
}

/**
 * @title ValidatorDepositRedeemStatsLib
 * @notice External library: aggregate GB (ConetGB1155) + CNET (ValidatorNodeRewardIndexer) income stats.
 *         Linked from {ValidatorDepositRedeem} so the main contract stays within EIP-170 while exposing a single
 *         on-chain entry point for RPC reads (no centralized API).
 */
library ValidatorDepositRedeemStatsLib {
    uint256 internal constant GB_NET_TOTAL_ID = 0;

    function _readGbBeneficiary(IConetGB1155Income gb, address beneficiary) private view returns (IncomeTotals memory t) {
        if (address(gb) == address(0) || beneficiary == address(0)) return t;
        t.cumulative = gb.balanceOf(beneficiary, GB_NET_TOTAL_ID);
        t.hour = gb.issuedThisHourOf(beneficiary);
        t.day = gb.issuedTodayOf(beneficiary);
        t.week = gb.issuedThisWeekOf(beneficiary);
        t.month = gb.issuedThisMonthOf(beneficiary);
        t.year = gb.issuedThisYearOf(beneficiary);
    }

    function _readGbNode(IConetGB1155Income gb, address nodeWallet) private view returns (IncomeTotals memory t) {
        if (address(gb) == address(0) || nodeWallet == address(0)) return t;
        t.cumulative = gb.nodeTotalIssued(nodeWallet);
        t.hour = gb.nodeIssuedThisHourOf(nodeWallet);
        t.day = gb.nodeIssuedTodayOf(nodeWallet);
        t.week = gb.nodeIssuedThisWeekOf(nodeWallet);
        t.month = gb.nodeIssuedThisMonthOf(nodeWallet);
        t.year = gb.nodeIssuedThisYearOf(nodeWallet);
    }

    function _readCnetBeneficiary(IRewardIndexerSummary idx, address beneficiary, uint256 anchorTs)
        private
        view
        returns (IncomeTotals memory t)
    {
        if (address(idx) == address(0) || beneficiary == address(0)) return t;
        (t.cumulative, t.hour, t.day, t.week, t.month, t.year) = idx.getBeneficiaryRewardSummary(beneficiary, anchorTs);
    }

    function _readCnetNode(IRewardIndexerSummary idx, address nodeWallet, uint256 anchorTs)
        private
        view
        returns (IncomeTotals memory t)
    {
        if (address(idx) == address(0) || nodeWallet == address(0)) return t;
        (t.cumulative, t.hour, t.day, t.week, t.month, t.year) = idx.getNodeRewardSummary(nodeWallet, anchorTs);
    }

    /// @notice Build unified GB + CNET income stats for a beneficiary and its parallel node wallet / IP lists.
    function assembleUnifiedIncomeStats(
        address gbToken,
        address rewardIndexer,
        address beneficiary,
        address[] memory nodeWallets,
        string[] memory depinNodeIps,
        uint256 anchorTs
    ) internal view returns (UnifiedIncomeStats memory stats) {
        stats.beneficiary = beneficiary;
        if (beneficiary == address(0)) {
            stats.nodes = new NodeIncomeRow[](0);
            return stats;
        }

        IConetGB1155Income gb = IConetGB1155Income(gbToken);
        IRewardIndexerSummary idx = IRewardIndexerSummary(rewardIndexer);
        stats.gbBeneficiary = _readGbBeneficiary(gb, beneficiary);
        stats.cnetBeneficiary = _readCnetBeneficiary(idx, beneficiary, anchorTs);

        uint256 n = nodeWallets.length;
        stats.nodes = new NodeIncomeRow[](n);
        for (uint256 i = 0; i < n; i++) {
            address w = nodeWallets[i];
            stats.nodes[i].nodeWallet = w;
            if (i < depinNodeIps.length) {
                stats.nodes[i].depinNodeIp = depinNodeIps[i];
            }
            if (w != address(0)) {
                stats.nodes[i].gb = _readGbNode(gb, w);
                stats.nodes[i].cnet = _readCnetNode(idx, w, anchorTs);
            }
        }
    }

    /**
     * @notice Single RPC entry: resolve beneficiary (wallet / node wallet / IP) via {ValidatorDepositRedeem},
     *         then aggregate GB + CNET income stats (internal staticcalls to {gbToken} + {rewardIndexer}).
     */
    function resolveUnifiedFromRedeem(
        address redeem,
        address maybeWallet,
        string calldata conetDepinNodeIp,
        uint256 anchorTs
    ) external view returns (UnifiedIncomeStats memory stats) {
        IRedeemUnifiedReader reader = IRedeemUnifiedReader(redeem);
        NodeBundle memory b = reader.resolveNodeBundle(maybeWallet, conetDepinNodeIp);
        return
            assembleUnifiedIncomeStats(
                reader.gbToken(),
                reader.rewardIndexer(),
                b.beneficiary,
                b.nodeWallets,
                b.depinNodeIps,
                anchorTs
            );
    }
}
