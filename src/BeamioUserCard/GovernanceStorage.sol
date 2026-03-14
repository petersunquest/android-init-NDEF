// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* =========================================================
   GovernanceStorage (delegatecall storage in card)
   ========================================================= */

library GovernanceStorage {
    bytes32 internal constant SLOT = keccak256("beamio.usercard.governance.storage.v1");

    struct Proposal {
        address target;
        uint256 v1;
        uint256 v2;
        uint256 v3;
        bytes4 selector;
        uint256 approvals;
        bool executed;
    }

    struct Layout {
        uint256 threshold;
        mapping(address => bool) isAdmin;
        address[] adminList;
        mapping(uint256 => Proposal) proposals;
        mapping(uint256 => mapping(address => bool)) isApproved;
        uint256 proposalCount;
        mapping(address => string) adminMetadata; // 添加时写入，移除时保留（adminMetadata 可查历史）
        mapping(address => address) adminParent; // 谁添加了该 admin；owner 添加的为 address(0)
        mapping(address => address[]) adminChildren; // 该 admin 添加的子 admin 列表
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly { l.slot := slot }
    }
}
