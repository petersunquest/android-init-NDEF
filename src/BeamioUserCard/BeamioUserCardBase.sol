// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BeamioERC1155Logic.sol";
import "./BeamioCurrency.sol";
import "./Errors.sol";
import "./GovernanceStorage.sol";
import "./BeamioUserCardAdminPartyMixin.sol";

import "../contracts/token/ERC1155/ERC1155.sol";
import "../contracts/access/Ownable.sol";
import "../contracts/utils/ReentrancyGuard.sol";

interface IBeamioGatewayAAFactoryGetter {
    function _aaFactory() external view returns (address);
}

interface IBeamioUserCardFactoryPaymasterV07 {
    function defaultRedeemModule() external view returns (address);
    function defaultFaucetModule() external view returns (address);
    function defaultIssuedNftModule() external view returns (address);
    function defaultGovernanceModule() external view returns (address);
    function defaultMembershipStatsModule() external view returns (address);
}

interface IBeamioMembershipStatsModuleV1 {
    function mintMemberCardInternal(address user, uint256 tierIndex) external;
    function removeNft(address user, uint256 id) external;
    function maybeUpgradeByPointsBalance(address acct) external;
    function maybeUpgrade(address acct, uint256 pointsDelta6) external;
    function syncActiveToBestValid(address user) external;
    function maybeIssueOnlyIfNoneOrExpiredByPointsDelta(address acctOrEOA, uint256 pointsDelta6) external;
    function issueCardByPointsDelta_AssumingNoValidCard(address acct, uint256 pointsDelta6) external;
    function handlePointsTransferForUpgradeType2(
        address from,
        address effectiveTo,
        uint256[] memory ids,
        uint256[] memory values
    ) external;
}

abstract contract BeamioUserCardBase is ERC1155, Ownable, ReentrancyGuard, BeamioUserCardAdminPartyMixin {
    uint256 public constant POINTS_ID = BeamioERC1155Logic.POINTS_ID;
    uint8 public constant POINTS_DECIMALS = BeamioERC1155Logic.POINTS_DECIMALS;
    uint256 internal constant POINTS_ONE = 10 ** uint256(POINTS_DECIMALS);

    uint256 public constant NFT_START_ID = BeamioERC1155Logic.NFT_START_ID;
    uint256 public constant ISSUED_NFT_START_ID = BeamioERC1155Logic.ISSUED_NFT_START_ID;

    address public gateway;
    address public debugGateway;

    BeamioCurrency.CurrencyType public currency;
    uint256 public pointsUnitPriceInCurrencyE6;
    uint256 public expirySeconds;

    mapping(address => bool) public transferWhitelist;
    bool public transferWhitelistEnabled;

    mapping(uint256 => uint256) public expiresAt;
    mapping(uint256 => uint256) public attributes;
    mapping(uint256 => uint256) public tokenTierIndexOrMax;
    mapping(address => uint256[]) public _userOwnedNfts;

    mapping(address => uint256) public activeMembershipId;
    mapping(address => uint256) public activeTierIndexOrMax;
    mapping(uint256 => uint256) public activeMembershipCountByTokenId;
    mapping(uint256 => uint256) public activeMembershipCountByTierIndex;
    uint256 public totalMembershipIssued;
    uint256 public totalMembershipUpgraded;
    uint256 public totalActiveMemberships;
    mapping(uint256 => uint256) public totalMembershipIssuedByTierIndex;

    struct NFTDetail {
        uint256 tokenId;
        uint256 attribute;
        uint256 tierIndexOrMax;
        uint256 expiry;
        bool isExpired;
    }

    struct Tier {
        uint256 minUsdc6;
        uint256 attr;
        uint256 tierExpirySeconds;
    }

    Tier[] public tiers;
    uint256 public defaultAttrWhenNoTiers;

    uint256 internal _currentIndex = NFT_START_ID;

    /// @dev 0=按单次 topup/redeem pointsDelta；1=按余额；2=按累计向 admin 转 points。constructor 写入后不可改。
    uint8 public upgradeType;

    event MemberNFTIssued(address indexed user, uint256 indexed tokenId, uint256 tierIndexOrMax, uint256 minUsdc6, uint256 expiry);
    event MemberNFTUpgraded(address indexed user, uint256 indexed oldActiveTokenId, uint256 indexed newTokenId, uint256 oldTierIndexOrMax, uint256 newTierIndex, uint256 newExpiry);
    event AdminCardMinted(address indexed beneficiaryAccount, uint256 indexed tokenId, uint256 attr, uint256 expiry);

    modifier onlyAuthorizedGateway() {
        address gw = debugGateway == address(0) ? gateway : debugGateway;
        if (msg.sender != gw) revert UC_UnauthorizedGateway();
        _;
    }

    modifier onlyAdmin() {
        if (!GovernanceStorage.layout().isAdmin[msg.sender]) revert UC_NotAdmin();
        _;
    }

    constructor(string memory uri_, address initialOwner) ERC1155(uri_) Ownable(initialOwner) {}

    function factoryGateway() public view returns (address) {
        return gateway;
    }

    function _revertDelegate(bytes memory data) internal pure {
        if (data.length > 0) assembly { revert(add(data, 32), mload(data)) }
        revert UC_RedeemDelegateFailed(data);
    }

    function _requireOwnerOrGateway() internal view {
        address gw = debugGateway == address(0) ? gateway : debugGateway;
        if (msg.sender != owner() && msg.sender != gw) revert BM_NotAuthorized();
    }

    function _toAccount(address maybeEoaOrAcct) internal view returns (address acct) {
        address f = IBeamioFactoryOracle(factoryGateway()).aaFactory();
        if (f == address(0)) revert UC_GlobalMisconfigured();

        if (IBeamioAccountFactoryV07(f).isBeamioAccount(maybeEoaOrAcct)) {
            if (maybeEoaOrAcct.code.length == 0) revert UC_NoBeamioAccount();
            return maybeEoaOrAcct;
        }
        return _resolveAccount(maybeEoaOrAcct);
    }

    function _resolveAccount(address eoa) internal view returns (address) {
        address aaFactory = IBeamioGatewayAAFactoryGetter(factoryGateway())._aaFactory();
        if (aaFactory == address(0)) revert UC_GlobalMisconfigured();

        address acct = IBeamioAccountFactoryV07(aaFactory).beamioAccountOf(eoa);
        if (acct == address(0) || acct.code.length == 0) revert UC_ResolveAccountFailed(eoa, aaFactory, acct);
        return acct;
    }

    function _effectiveExpirySeconds(uint256 tierIndex) internal view returns (uint256) {
        uint256 ts = tiers[tierIndex].tierExpirySeconds;
        return ts > 0 ? ts : expirySeconds;
    }

    function _isExpired(uint256 tokenId) internal view returns (bool) {
        uint256 exp = expiresAt[tokenId];
        return exp != 0 && block.timestamp > exp;
    }

    function _hasValidCard(address acct) internal view returns (bool) {
        uint256 id = activeMembershipId[acct];
        return id != 0 && balanceOf(acct, id) > 0 && !_isExpired(id);
    }

    function _isTrackableTierIndex(uint256 tierIndex) internal view returns (bool) {
        return tierIndex != type(uint256).max && tierIndex < tiers.length;
    }

    function _incrementActiveMembershipCounters(uint256 tokenId, uint256 tierIndex) internal {
        if (tokenId == 0) return;
        totalActiveMemberships += 1;
        activeMembershipCountByTokenId[tokenId] += 1;
        if (_isTrackableTierIndex(tierIndex)) activeMembershipCountByTierIndex[tierIndex] += 1;
    }

    function _decrementActiveMembershipCounters(uint256 tokenId, uint256 tierIndex) internal {
        if (tokenId == 0) return;
        if (totalActiveMemberships > 0) totalActiveMemberships -= 1;
        uint256 byToken = activeMembershipCountByTokenId[tokenId];
        if (byToken > 0) activeMembershipCountByTokenId[tokenId] = byToken - 1;
        if (_isTrackableTierIndex(tierIndex)) {
            uint256 byTier = activeMembershipCountByTierIndex[tierIndex];
            if (byTier > 0) activeMembershipCountByTierIndex[tierIndex] = byTier - 1;
        }
    }

    function _recordMembershipIssuedTotal(uint256 tierIndexOrMax) internal {
        totalMembershipIssued += 1;
        if (_isTrackableTierIndex(tierIndexOrMax)) totalMembershipIssuedByTierIndex[tierIndexOrMax] += 1;
    }

    function _recordMembershipUpgradedTotal() internal {
        totalMembershipUpgraded += 1;
    }

    function _setActiveMembershipWithCounters(address acct, uint256 newId, uint256 newTierIndexOrMax) internal {
        uint256 oldId = activeMembershipId[acct];
        uint256 oldTierIndexOrMax = activeTierIndexOrMax[acct];
        if (oldId == newId && oldTierIndexOrMax == newTierIndexOrMax) return;
        _decrementActiveMembershipCounters(oldId, oldTierIndexOrMax);
        activeMembershipId[acct] = newId;
        activeTierIndexOrMax[acct] = newTierIndexOrMax;
        _incrementActiveMembershipCounters(newId, newTierIndexOrMax);
    }

    function _mintMembershipNft(address acct, uint256 tierIndexOrMax, uint256 attr, uint256 expiry) internal returns (uint256 newId) {
        newId = _currentIndex++;
        _mint(acct, newId, 1, "");
        expiresAt[newId] = expiry;
        attributes[newId] = attr;
        tokenTierIndexOrMax[newId] = tierIndexOrMax;
        _userOwnedNfts[acct].push(newId);
    }

    /// @dev 升级不 mint 新 ERC1155 id：原地更新同一枚会员 NFT 的 tier / attr / expiry，并修正按 tier 维度的 active 计数。
    function _upgradeMembershipInPlace(
        address acct,
        uint256 tokenId,
        uint256 oldTierIdx,
        uint256 newTierIdx,
        uint256 newAttr,
        uint256 newExpiry
    ) internal {
        if (balanceOf(acct, tokenId) == 0) return;
        if (_isTrackableTierIndex(oldTierIdx)) {
            uint256 c = activeMembershipCountByTierIndex[oldTierIdx];
            if (c > 0) activeMembershipCountByTierIndex[oldTierIdx] = c - 1;
        }
        if (_isTrackableTierIndex(newTierIdx)) {
            activeMembershipCountByTierIndex[newTierIdx] += 1;
        }
        attributes[tokenId] = newAttr;
        tokenTierIndexOrMax[tokenId] = newTierIdx;
        expiresAt[tokenId] = newExpiry;
        activeTierIndexOrMax[acct] = newTierIdx;
    }

    function _tierMinPoints6(uint256 i) internal view returns (uint256) {
        return tiers[i].minUsdc6;
    }

    function _tierIndexWithMinThreshold() internal view returns (uint256) {
        if (tiers.length == 0) return type(uint256).max;
        uint256 idx = 0;
        uint256 minVal = tiers[0].minUsdc6;
        for (uint256 i = 1; i < tiers.length; i++) {
            if (tiers[i].minUsdc6 < minVal) {
                minVal = tiers[i].minUsdc6;
                idx = i;
            }
        }
        return idx;
    }

    function _tierFromPointsBalance(uint256 points6) internal view returns (bool ok, uint256 tierIndex, uint256 attr) {
        if (tiers.length == 0) return (true, type(uint256).max, defaultAttrWhenNoTiers);
        uint256 bestIdx = type(uint256).max;
        uint256 bestMin = 0;
        for (uint256 i = 0; i < tiers.length; i++) {
            if (points6 >= tiers[i].minUsdc6 && tiers[i].minUsdc6 > bestMin) {
                bestMin = tiers[i].minUsdc6;
                bestIdx = i;
            }
        }
        if (bestIdx == type(uint256).max) return (false, 0, 0);
        return (true, bestIdx, tiers[bestIdx].attr);
    }

    function _tierFromPointsDelta(uint256 pointsDelta6) internal view returns (bool ok, uint256 tierIndex, uint256 attr) {
        uint256 bestIdx = type(uint256).max;
        for (uint256 i = 0; i < tiers.length; i++) {
            if (pointsDelta6 >= tiers[i].minUsdc6) {
                if (bestIdx == type(uint256).max || tiers[i].minUsdc6 > tiers[bestIdx].minUsdc6) bestIdx = i;
            }
        }
        if (bestIdx == type(uint256).max) return (false, 0, 0);
        return (true, bestIdx, tiers[bestIdx].attr);
    }

    function _nextTierIndexAbove(uint256 currentTierIdx) internal view returns (uint256) {
        if (currentTierIdx >= tiers.length) return type(uint256).max;
        uint256 currentMin = tiers[currentTierIdx].minUsdc6;
        uint256 nextIdx = type(uint256).max;
        uint256 nextMin = type(uint256).max;
        for (uint256 i = 0; i < tiers.length; i++) {
            uint256 m = tiers[i].minUsdc6;
            if (m > currentMin && m < nextMin) {
                nextMin = m;
                nextIdx = i;
            }
        }
        return nextIdx;
    }

    function _findBestValidMembership(address user) internal view returns (uint256 bestId, uint256 bestTierIndexOrMax) {
        uint256[] storage nftIds = _userOwnedNfts[user];
        uint256 fallbackId = 0;
        bestTierIndexOrMax = type(uint256).max;

        for (uint256 i = 0; i < nftIds.length; i++) {
            uint256 id = nftIds[i];
            if (balanceOf(user, id) == 0) continue;
            if (_isExpired(id)) continue;

            uint256 tierIdx = tokenTierIndexOrMax[id];
            if (!_isTrackableTierIndex(tierIdx)) {
                if (fallbackId == 0) fallbackId = id;
                continue;
            }

            if (bestId == 0 || !_isTrackableTierIndex(bestTierIndexOrMax) || tiers[tierIdx].minUsdc6 > tiers[bestTierIndexOrMax].minUsdc6) {
                bestId = id;
                bestTierIndexOrMax = tierIdx;
            }
        }

        if (bestId == 0 && fallbackId != 0) {
            bestId = fallbackId;
            bestTierIndexOrMax = tokenTierIndexOrMax[fallbackId];
        }
    }

}
