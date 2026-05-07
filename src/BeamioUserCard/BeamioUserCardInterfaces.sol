// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// 从 BeamioUserCard.sol 拆出大块 interface，降低主合约 IR/bytecode 体积

interface IBeamioGatewayAAFactoryGetter {
    function _aaFactory() external view returns (address);
}

/// @dev Points 转账白名单校验（由主合约实现，供 external library delegatecall 路径通过 address(this) 查询）
interface IBeamioUserCardWhitelist {
    function isPointsTransferRecipientAllowed(address effectiveTo) external view returns (bool);
}

interface IBeamioAccountViewForOpenRelay {
    function factory() external view returns (address);
    function owner() external view returns (address);
}

interface IBeamioFactoryOpenRelayViews {
    function openContainerMintExecutor() external view returns (address);
    function isBeamioAccount(address account) external view returns (bool);
}

interface IBeamioUserCardFactoryPaymasterV07 {
    function defaultRedeemModule() external view returns (address);
    function defaultFaucetModule() external view returns (address);
    function defaultIssuedNftModule() external view returns (address);
    function defaultGovernanceModule() external view returns (address);
    function defaultMembershipStatsModule() external view returns (address);
    function defaultAdminStatsQueryModule() external view returns (address);
    function metadataBaseURI() external view returns (string memory);
}

interface IBeamioUserCardSelectorRouter {
    function selectorModuleKind(bytes4 sel) external pure returns (uint8);
}

interface IBeamioRedeemModuleVNext {
    function createRedeemAdmin(bytes32 hash, string calldata metadata, uint64 validAfter, uint64 validBefore) external;
    function createRedeemAdmin(bytes32 hash, string calldata metadata, uint64 validAfter, uint64 validBefore, uint256 mintLimit) external;
    function consumeRedeemAdmin(string calldata code) external returns (string memory metadata, uint256 mintLimit);
    function cancelRedeemAdmin(bytes32 hash) external;

    function createRedeem(
        bytes32 hash,
        uint256 points6,
        uint256 attr,
        uint64 validAfter,
        uint64 validBefore,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external;

    function cancelRedeem(string calldata code) external;

    function consumeRedeem(string calldata code, address to)
        external
        returns (uint256 points6, uint256 attr, uint256[] memory tokenIds, uint256[] memory amounts);

    function createRedeemBatch(
        bytes32[] calldata hashes,
        uint256 points6,
        uint256 attr,
        uint64 validAfter,
        uint64 validBefore,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external;

    function consumeRedeemBatch(string[] calldata codes, address to)
        external
        returns (uint256 points6, uint256 attr, uint256[] memory tokenIds, uint256[] memory amounts);

    function createRedeemPool(
        bytes32 poolHash,
        uint64 validAfter,
        uint64 validBefore,
        uint256[][] calldata tokenIdsList,
        uint256[][] calldata amountsList,
        uint32[] calldata counts
    ) external;

    function terminateRedeemPool(bytes32 poolHash) external;

    function consumeRedeemPool(string calldata code, address user)
        external
        returns (uint256[] memory tokenIds, uint256[] memory amounts);

    function createRedeemWithCreator(bytes32 hash, uint256 points6, uint256 attr, uint64 validAfter, uint64 validBefore, uint256[] calldata tokenIds, uint256[] calldata amounts, address creator) external;
    function createRedeemWithCreatorAndRecommender(bytes32 hash, uint256 points6, uint256 attr, uint64 validAfter, uint64 validBefore, uint256[] calldata tokenIds, uint256[] calldata amounts, address creator, address recommender) external;
    function createRedeemBatchWithCreator(bytes32[] calldata hashes, uint256 points6, uint256 attr, uint64 validAfter, uint64 validBefore, uint256[] calldata tokenIds, uint256[] calldata amounts, address creator) external;
    function createRedeemBatchWithCreatorAndRecommender(bytes32[] calldata hashes, uint256 points6, uint256 attr, uint64 validAfter, uint64 validBefore, uint256[] calldata tokenIds, uint256[] calldata amounts, address creator, address recommender) external;
    function createRedeemPoolWithCreator(bytes32 poolHash, uint64 validAfter, uint64 validBefore, uint256[][] calldata tokenIdsList, uint256[][] calldata amountsList, uint32[] calldata counts, address creator) external;
    function createRedeemPoolWithCreatorAndRecommender(bytes32 poolHash, uint64 validAfter, uint64 validBefore, uint256[][] calldata tokenIdsList, uint256[][] calldata amountsList, uint32[] calldata counts, address creator, address recommender) external;
    function getRedeemCreator(string calldata code) external view returns (address creator);
    function getRedeemRecommender(string calldata code) external view returns (address recommender);
    function getRedeemAdminStatus(bytes32 hash) external view returns (bool active);
    function getRedeemAdminList() external view returns (bytes32[] memory);
}

interface IBeamioFaucetModuleV1 {
    function setFaucetConfig(uint256 id, uint64 validUntil, uint64 perClaimMax, uint128 maxPerUser, uint128 maxGlobal, bool enabled, uint8 currency, uint128 priceInCurrency6) external;
    function validateAndRecordFreeFaucet(address userEOA, uint256 id, uint256 amount) external returns (uint256 outId, uint256 outAmount);
    function validateAndRecordPaidFaucet(address userEOA, uint256 id, uint256 amount6) external returns (uint256 outId, uint256 outAmount);
}

interface IBeamioIssuedNftModuleV1 {
    function issuedNftSharedMetadataHash(uint256 tokenId) external view returns (bytes32);
    function issuedNftMaxSupply(uint256 tokenId) external view returns (uint256);
    function issuedNftMintedCount(uint256 tokenId) external view returns (uint256);
    function burnIssuedNftByGateway(address holder, uint256 tokenId, uint256 amount) external;
    function createIssuedNft(bytes32 title, uint64 validAfter, uint64 validBefore, uint256 maxSupply, uint256 priceInCurrency6, bytes32 sharedMetadataHash) external returns (uint256 tokenId);
    function validateAndRecordMintIssuedNft(address acct, uint256 tokenId, uint256 amount) external;
    /// @notice Exactly 1 NFT; per userEOA per tokenId at most once; maxSupply enforced
    function validateAndRecordMintIssuedNftUserSigClaim(address userEOA, address recipientAcct, uint256 tokenId) external;
}

interface IBeamioGovernanceModuleV1 {
    function adminManager(address to, bool admin, uint256 newThreshold, string calldata metadata) external;
    function adminManager(address to, bool admin, uint256 newThreshold, string calldata metadata, uint256 mintLimit) external;
    function adminManagerByAdmin(address to, bool admin, uint256 newThreshold, string calldata metadata, address authorizer) external;
    function adminManagerByAdmin(address to, bool admin, uint256 newThreshold, string calldata metadata, address authorizer, uint256 mintLimit) external;
    function setAdminAirdropLimit(address adminAddr, uint256 mintLimit) external;
    function setAdminAirdropLimitByAdmin(address adminAddr, uint256 mintLimit, address authorizer) external;
    function enforceAndRecordAdminAirdropLimit(address admin, uint256 points6) external;
    function clearAdminStatsAndAirdropUsageForSubordinate(address subordinate, address authorizer) external;
    function resetAdminLimit(address adminAddr) external;
    function resetAdminLimitByAdmin(address adminAddr, address authorizer) external;
    function createProposal(bytes4 selector, address target, uint256 v1, uint256 v2, uint256 v3) external returns (uint256 id);
    function approveProposalByGateway(uint256 id, address adminSigner) external;
    function approveProposal(uint256 id) external;
    function executeProposal(uint256 id) external returns (bytes4 selector, address target, uint256 v1, uint256 v2, uint256 v3);
}

interface IBeamioMembershipStatsModuleV1 {
    function mintMemberCardInternal(address user, uint256 tierIndex) external;
    function removeNft(address user, uint256 id) external;
    /// @param allowUpgrade true：余额达到更高档时上调；false：仅当余额不足以支撑当前档时下调到可达档（转出/销毁 points 后）
    function alignMembershipTierToPointsBalance(address acct, bool allowUpgrade) external;
    function maybeUpgradeByPointsBalance(address acct) external;
    function maybeUpgrade(address acct, uint256 pointsDelta6) external;
    function syncActiveToBestValid(address user) external;
    function maybeIssueOnlyIfNoneOrExpiredByPointsDelta(address acctOrEOA, uint256 pointsDelta6) external;
    function issueCardByPointsDelta_AssumingNoValidCard(address acct, uint256 pointsDelta6) external;
    /// @dev upgradeType==2：主合约 delegatecall，模块内汇总并升级（卡侧仅 abi.encode，体积更小）
    function handlePointsTransferForUpgradeType2(
        address from,
        address effectiveTo,
        uint256[] memory ids,
        uint256[] memory values
    ) external;
}
