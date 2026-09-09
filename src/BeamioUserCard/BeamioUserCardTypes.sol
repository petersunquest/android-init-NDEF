// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev 与 BeamioUserCard 中 tiers 存储布局一致；供主合约与 Factory 等共用。
///      升级模式由卡级 `upgradeType` 决定（constructor 固定），不再使用 per-tier 标志。
struct Tier {
    uint256 minUsdc6; // Tier thresholds are points-based (semantic: minPointsDelta6), not direct USDC balances.
    uint256 attr;
    uint256 tierExpirySeconds; // 0 => use global expirySeconds
}

/// @dev Runtime tier layout for BeamioUserCard. Kept separate from legacy
///      module-view tiers, which predate the upgrade-by-balance flag.
struct UserCardTier {
    uint256 minUsdc6;
    uint256 attr;
    uint256 tierExpirySeconds;
    bool upgradeByBalance;
}

/// @dev Complete immutable-at-create tier schedule passed through a Beacon
///      proxy initializer. A card uses either direct fees or threshold tiers.
struct UserCardInitialTierConfig {
    uint8 qualificationMode;
    UserCardTier[] tiers;
    uint256[] membershipFeeE6;
    uint8[] membershipDurationKind;
}

/// @dev ERC1155 `_update` 前置扫描结果（主合约与 BeamioUserCardTransferLib 共用）
struct UpdatePreResult {
    address effectiveTo;
    address beneficiaryAdmin;
    address upperAdmin;
    uint256 pointTransferCount;
    uint256 pointTransferAmount;
    address[] burnedFrom;
    uint256[] burnedIds;
    uint256 burnedCount;
}

/// @dev 用户 NFT 明细（主合约 getOwnership 与 ViewsLib 共用）
struct NFTDetail {
    uint256 tokenId;
    uint256 attribute;
    uint256 tierIndexOrMax;
    uint256 expiry;
    bool isExpired;
}
