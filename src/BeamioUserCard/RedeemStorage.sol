// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* =========================================================
   RedeemStorage (delegatecall storage in card)
   - NO magic hex slot: use keccak256("...") constant
   - One-time Redeem 与 RedeemPool 共用 hash 空间：统一用 keccak256(code) 作为 key，
     外部可用统一查询检查 string 是否有效，统一 consume 函数内按类型分发处理。
   ========================================================= */

library RedeemStorage {
    bytes32 internal constant SLOT = keccak256("beamio.usercard.redeem.storage.v1");

    // ===== One-time Redeem（一次一码，hash=keccak256(code)）=====
    struct Redeem {
        uint128 points6;
        uint32  attr;
        bool    active;

        uint64  validAfter;   // 0 => immediate
        uint64  validBefore;  // 0 => forever

        uint256[] tokenIds;
        uint256[] amounts;
        /// @dev 创建者（owner 或 admin），兑换时计入其 admin 统计及 parent 链
        address creator;
        /// @dev 推荐 admin；兑换成功后单独计入其 redeem_mint 计数及 parent 链
        address recommender;
    }

    // ===== RedeemPool（可重复密码，每用户一次，hash=keccak256(password)）=====
    struct PoolContainer {
        uint32 remaining;
        uint256[] tokenIds;
        uint256[] amounts;
    }

    struct RedeemPool {
        bool   active;
        uint64 validAfter;
        uint64 validBefore;

        uint32 totalRemaining;
        uint32 cursor;

        PoolContainer[] containers;
        /// @dev 创建者（owner 或 admin），兑换时计入其 admin 统计及 parent 链
        address creator;
        /// @dev 推荐 admin；兑换成功后单独计入其 redeem_mint 计数及 parent 链
        address recommender;
    }

    // ===== RedeemAdmin（通过秘密 code 添加 admin，hash=keccak256(secretCode)）=====
    struct RedeemAdmin {
        bool   active;
        string metadata;
        uint64 validAfter;
        uint64 validBefore;
    }

    struct Layout {
        mapping(bytes32 => Redeem) redeems;   // one-time: hash=keccak256(code)
        mapping(bytes32 => RedeemPool) pools; // pool: hash=keccak256(password)，与 redeems 共用 hash 空间但互斥
        mapping(bytes32 => mapping(address => bool)) poolClaimed;  // poolHash => user => claimed
        mapping(bytes32 => RedeemAdmin) redeemAdmins; // hash=keccak256(secretCode)，与 redeems/pools 独立
        /// @dev Enumerable: unredeemed redeem-admin hashes (consumed are removed)
        bytes32[] redeemAdminHashes;
        mapping(bytes32 => uint256) redeemAdminIndex; // hash => index in redeemAdminHashes (1-based, 0 = not in list)
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly { l.slot := slot }
    }
}
