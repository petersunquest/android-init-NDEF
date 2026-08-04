// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {NodeBundle, AirdropState} from "./ValidatorDepositRedeemTypes.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";
import {CoNETIncomePeriodLib} from "../b-unit/CoNETIncomePeriodLib.sol";

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

/// @dev GBDepinAirdrop paid-GB period summary views (9-decimal raw).
interface IGBDepinPaidSummary {
    function paidGbSummaryOf(address beneficiary, uint256 anchorTs)
        external
        view
        returns (CoNETIncomePeriodLib.IncomePeriodSummary memory);

    function paidGbSummaryOfGuardianNode(uint256 guardianNodeId, uint256 anchorTs)
        external
        view
        returns (CoNETIncomePeriodLib.IncomePeriodSummary memory);
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

    // ---- CNET airdrop claim (offloaded from {ValidatorDepositRedeem} to stay within EIP-170) ----
    // MUST stay byte-identical to the ClaimAirdrop type string the off-chain signer uses.
    bytes32 private constant CLAIM_AIRDROP_TYPEHASH =
        keccak256("ClaimAirdrop(address beneficiary,uint256 amount,uint256 nonce,uint256 deadline)");

    /// @dev Emitted (via delegatecall, from the host address) when an airdrop claim is paid.
    event AirdropClaimed(address indexed beneficiary, uint256 amount);

    /// @notice ClaimAirdrop EIP-712 digest a beneficiary signs (off-chain helper; reads the host domain separator).
    function claimAirdropDigest(
        bytes32 domainSeparator,
        address beneficiary,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) external pure returns (bytes32) {
        bytes32 sh = keccak256(abi.encode(CLAIM_AIRDROP_TYPEHASH, beneficiary, amount, nonce, deadline));
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, sh));
    }

    /**
     * @notice Full gas-sponsored airdrop claim: expiry + nonce + EIP-712 signature checks, then pay CNET from the
     *         host (redeem) balance and emit {AirdropClaimed}. Called via delegatecall from {ValidatorDepositRedeem}
     *         (storage, balance, msg context, and the emitted event's address are all the host's).
     * @dev    The host only needs to wrap this in its reentrancy guard. {nonces} is the host's shared beneficiary
     *         nonce mapping; {s} is the host airdrop ledger.
     * @return paid The CNET amount transferred (== amount on success).
     */
    function claimAirdrop(
        AirdropState storage s,
        mapping(address => uint256) storage nonces,
        bytes32 domainSeparator,
        address beneficiary,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature,
        uint256 vestingDuration
    ) external returns (uint256 paid) {
        require(block.timestamp <= deadline, "ValidatorRedeem: expired");
        require(nonces[beneficiary] == nonce, "ValidatorRedeem: bad nonce");
        nonces[beneficiary]++;
        bytes32 sh = keccak256(abi.encode(CLAIM_AIRDROP_TYPEHASH, beneficiary, amount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, sh));
        require(ECDSA.recover(digest, signature) == beneficiary, "ValidatorRedeem: bad sig");
        paid = _settleAirdrop(s, beneficiary, amount, vestingDuration);
        emit AirdropClaimed(beneficiary, paid);
    }

    /// @dev Linearly-vested CNET airdrop amount for a beneficiary at the current block time.
    ///      0 before the start; full accrued once start + {vestingDuration} has elapsed.
    function _vestedAirdrop(AirdropState storage s, address beneficiary, uint256 vestingDuration)
        private
        view
        returns (uint256)
    {
        uint64 startAt = s.claimableAt;
        if (startAt == 0 || block.timestamp < uint256(startAt)) return 0;
        uint256 accrued = s.accrued[beneficiary];
        uint256 elapsed = block.timestamp - uint256(startAt);
        if (vestingDuration == 0 || elapsed >= vestingDuration) return accrued;
        return (accrued * elapsed) / vestingDuration;
    }

    function _settleAirdrop(AirdropState storage s, address beneficiary, uint256 amount, uint256 vestingDuration)
        private
        returns (uint256)
    {
        require(s.claimableAt != 0 && block.timestamp >= s.claimableAt, "ValidatorRedeem: airdrop closed");
        require(amount > 0, "ValidatorRedeem: zero amount");
        uint256 vested = _vestedAirdrop(s, beneficiary, vestingDuration);
        uint256 claimable = vested > s.claimed[beneficiary] ? vested - s.claimed[beneficiary] : 0;
        require(amount <= claimable, "ValidatorRedeem: exceeds claimable");
        require(address(this).balance >= amount, "ValidatorRedeem: insufficient balance");
        s.claimed[beneficiary] += amount;
        (bool ok, ) = payable(beneficiary).call{value: amount}("");
        require(ok, "ValidatorRedeem: native transfer failed");
        return amount;
    }

    function _incomeTotalsFromSummary(CoNETIncomePeriodLib.IncomePeriodSummary memory s)
        private
        pure
        returns (IncomeTotals memory t)
    {
        t.cumulative = s.cumulative;
        t.hour = s.hour;
        t.day = s.day;
        t.week = s.week;
        t.month = s.month;
        t.year = s.year;
    }

    function _maxIncomeTotals(IncomeTotals memory a, IncomeTotals memory b)
        private
        pure
        returns (IncomeTotals memory o)
    {
        o.cumulative = a.cumulative >= b.cumulative ? a.cumulative : b.cumulative;
        o.hour = a.hour >= b.hour ? a.hour : b.hour;
        o.day = a.day >= b.day ? a.day : b.day;
        o.week = a.week >= b.week ? a.week : b.week;
        o.month = a.month >= b.month ? a.month : b.month;
        o.year = a.year >= b.year ? a.year : b.year;
    }

    /// @dev Exposed for {ValidatorDepositRedeem} host-side CL settle merge (avoids storage refs in external library calls).
    function maxIncomeTotals(IncomeTotals memory a, IncomeTotals memory b) external pure returns (IncomeTotals memory) {
        return _maxIncomeTotals(a, b);
    }

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

    function _readGbBeneficiaryMerged(
        IConetGB1155Income gb,
        IGBDepinPaidSummary depin,
        address beneficiary,
        uint256 anchorTs
    ) private view returns (IncomeTotals memory t) {
        t = _readGbBeneficiary(gb, beneficiary);
        if (address(depin) == address(0)) return t;
        try depin.paidGbSummaryOf(beneficiary, anchorTs) returns (CoNETIncomePeriodLib.IncomePeriodSummary memory s) {
            return _maxIncomeTotals(t, _incomeTotalsFromSummary(s));
        } catch {
            return t;
        }
    }

    function _readGbNodeMerged(
        IConetGB1155Income gb,
        IGBDepinPaidSummary depin,
        address nodeWallet,
        uint256 guardianNodeId,
        uint256 anchorTs
    ) private view returns (IncomeTotals memory t) {
        t = _readGbNode(gb, nodeWallet);
        if (address(depin) == address(0) || guardianNodeId == 0) return t;
        try depin.paidGbSummaryOfGuardianNode(guardianNodeId, anchorTs) returns (
            CoNETIncomePeriodLib.IncomePeriodSummary memory s
        ) {
            return _maxIncomeTotals(t, _incomeTotalsFromSummary(s));
        } catch {
            return t;
        }
    }

    /**
     * @notice Single RPC entry: resolve beneficiary via {ValidatorDepositRedeem}, aggregate GB + CNET stats.
     *         CL settle period buckets are merged on the host contract (storage refs cannot cross external library calls).
     */
    function resolveUnifiedFromRedeem(
        address redeem,
        address maybeWallet,
        string calldata conetDepinNodeIp,
        uint256 anchorTs,
        address gbDepinAirdrop
    ) external view returns (UnifiedIncomeStats memory stats) {
        IRedeemUnifiedReader reader = IRedeemUnifiedReader(redeem);
        NodeBundle memory b = reader.resolveNodeBundle(maybeWallet, conetDepinNodeIp);
        stats.beneficiary = b.beneficiary;
        if (b.beneficiary == address(0)) {
            stats.nodes = new NodeIncomeRow[](0);
            return stats;
        }
        IConetGB1155Income gb = IConetGB1155Income(reader.gbToken());
        IGBDepinPaidSummary depin = IGBDepinPaidSummary(gbDepinAirdrop);
        IRewardIndexerSummary idx = IRewardIndexerSummary(reader.rewardIndexer());
        stats.gbBeneficiary = _readGbBeneficiaryMerged(gb, depin, b.beneficiary, anchorTs);
        stats.cnetBeneficiary = _readCnetBeneficiary(idx, b.beneficiary, anchorTs);
        uint256 n = b.nodeWallets.length;
        stats.nodes = new NodeIncomeRow[](n);
        for (uint256 i = 0; i < n; i++) {
            address w = b.nodeWallets[i];
            stats.nodes[i].nodeWallet = w;
            if (i < b.depinNodeIps.length) stats.nodes[i].depinNodeIp = b.depinNodeIps[i];
            uint256 gid = i < b.guardianNodeIds.length ? b.guardianNodeIds[i] : 0;
            if (w != address(0)) {
                stats.nodes[i].gb = _readGbNodeMerged(gb, depin, w, gid, anchorTs);
                stats.nodes[i].cnet = _readCnetNode(idx, w, anchorTs);
            }
        }
    }
}
