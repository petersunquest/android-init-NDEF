// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IMyBrandsUserCard {
    struct NFTDetail {
        uint256 tokenId;
        uint256 attribute;
        uint256 tierIndexOrMax;
        uint256 expiry;
        bool isExpired;
    }

    function getOwnershipByEOA(address userEOA)
        external
        view
        returns (uint256 pt, NFTDetail[] memory nfts);

    function currency() external view returns (uint8);

    function owner() external view returns (address);

    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/**
 * @title BeamioMyBrandsDashboard
 * @notice Read-only aggregator for SilentPassUI My Brands (30s side tick).
 * @dev Client supplies trusted `cards[]` (from getWalletAssets / myCards). One
 *      `snapshotCards` eth_call returns per-card ownership + currency + reward +
 *      program stat balances (#3–#30) for EOA and optional AA.
 *      Coupon/catalog discovery stays off-chain (API tokenId lists); use
 *      `balanceBatch` to filter balances in one call.
 *
 *      UUPS upgradeable; canonical address = ERC1967 proxy.
 */
contract BeamioMyBrandsDashboard is Initializable, UUPSUpgradeable {
    uint256 public constant MAX_CARDS = 32;
    uint256 public constant MAX_TOKEN_IDS = 64;
    uint256 public constant MAX_ACCOUNTS = 4;
    uint256 public constant STAT_TOKEN_ID_MIN = 3;
    uint256 public constant STAT_TOKEN_ID_MAX = 30;
    uint256 public constant STAT_COUNT = 28; // 3..30 inclusive
    uint256 public constant DEFAULT_REWARD_TOKEN_ID = 2;

    mapping(address => bool) public admins;

    struct MembershipNft {
        uint256 tokenId;
        uint256 attribute;
        uint256 tierIndexOrMax;
        uint256 expiry;
        bool isExpired;
    }

    struct CardSlice {
        address card;
        /// @dev false when card has no code or a required view reverts
        bool ok;
        uint8 currency;
        address owner;
        uint256 points;
        uint256 rewardBalance;
        MembershipNft[] membershipNfts;
        /// @dev index i => balanceOf(eoa, tokenId = i + 3)
        uint256[28] statBalancesEoa;
        /// @dev index i => balanceOf(aa, tokenId = i + 3); zeros if aaOptional == 0
        uint256[28] statBalancesAa;
        bool hasAnyProgramAsset;
    }

    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);

    modifier onlyAdmin() {
        require(admins[msg.sender], "MyBrandsDashboard: not admin");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialAdmin) external initializer {
        __UUPSUpgradeable_init();
        address a = initialAdmin == address(0) ? msg.sender : initialAdmin;
        admins[a] = true;
        emit AdminAdded(a);
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}

    function version() external pure returns (uint256) {
        return 1;
    }

    function addAdmin(address admin) external onlyAdmin {
        require(admin != address(0), "MyBrandsDashboard: zero");
        admins[admin] = true;
        emit AdminAdded(admin);
    }

    function removeAdmin(address admin) external onlyAdmin {
        admins[admin] = false;
        emit AdminRemoved(admin);
    }

    /**
     * @notice Batch My Brands card slice for consumer EOA (+ optional AA).
     * @param cards Merchant program card addresses (max 32)
     * @param eoa Consumer main wallet
     * @param aaOptional Smart wallet; address(0) skips AA stats; reward still uses eoa
     * @param rewardTokenId Reward ERC-1155 id (use 2 for charge reward; 0 treated as 2)
     */
    function snapshotCards(
        address[] calldata cards,
        address eoa,
        address aaOptional,
        uint256 rewardTokenId
    ) external view returns (CardSlice[] memory slices) {
        require(eoa != address(0), "MyBrandsDashboard: eoa zero");
        require(cards.length <= MAX_CARDS, "MyBrandsDashboard: too many cards");
        uint256 rid = rewardTokenId == 0 ? DEFAULT_REWARD_TOKEN_ID : rewardTokenId;
        address rewardHolder = aaOptional != address(0) ? aaOptional : eoa;

        slices = new CardSlice[](cards.length);
        for (uint256 i = 0; i < cards.length;) {
            slices[i] = _readCardSlice(cards[i], eoa, aaOptional, rewardHolder, rid);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Flat balanceOf batch: result[a * tokenIds.length + t] = balanceOf(accounts[a], tokenIds[t]).
     * @dev Used for coupon/catalog filtering when API already supplies tokenIds.
     */
    function balanceBatch(address card, address[] calldata accounts, uint256[] calldata tokenIds)
        external
        view
        returns (uint256[] memory balances)
    {
        require(card != address(0), "MyBrandsDashboard: card zero");
        require(accounts.length > 0 && accounts.length <= MAX_ACCOUNTS, "MyBrandsDashboard: accounts");
        require(tokenIds.length > 0 && tokenIds.length <= MAX_TOKEN_IDS, "MyBrandsDashboard: tokenIds");
        require(card.code.length > 0, "MyBrandsDashboard: no code");

        uint256 n = accounts.length * tokenIds.length;
        balances = new uint256[](n);
        IMyBrandsUserCard c = IMyBrandsUserCard(card);
        for (uint256 a = 0; a < accounts.length;) {
            for (uint256 t = 0; t < tokenIds.length;) {
                uint256 idx = a * tokenIds.length + t;
                try c.balanceOf(accounts[a], tokenIds[t]) returns (uint256 bal) {
                    balances[idx] = bal;
                } catch {
                    balances[idx] = 0;
                }
                unchecked {
                    ++t;
                }
            }
            unchecked {
                ++a;
            }
        }
    }

    function _readCardSlice(
        address card,
        address eoa,
        address aaOptional,
        address rewardHolder,
        uint256 rewardTokenId
    ) internal view returns (CardSlice memory s) {
        s.card = card;
        if (card == address(0) || card.code.length == 0) {
            return s;
        }

        IMyBrandsUserCard c = IMyBrandsUserCard(card);

        try c.currency() returns (uint8 cur) {
            s.currency = cur;
        } catch {
            return s;
        }

        try c.owner() returns (address own) {
            s.owner = own;
        } catch {
            // owner optional — continue
        }

        try c.getOwnershipByEOA(eoa) returns (uint256 pt, IMyBrandsUserCard.NFTDetail[] memory nfts) {
            s.points = pt;
            s.membershipNfts = new MembershipNft[](nfts.length);
            for (uint256 j = 0; j < nfts.length;) {
                s.membershipNfts[j] = MembershipNft({
                    tokenId: nfts[j].tokenId,
                    attribute: nfts[j].attribute,
                    tierIndexOrMax: nfts[j].tierIndexOrMax,
                    expiry: nfts[j].expiry,
                    isExpired: nfts[j].isExpired
                });
                unchecked {
                    ++j;
                }
            }
        } catch {
            return s;
        }

        try c.balanceOf(rewardHolder, rewardTokenId) returns (uint256 rb) {
            s.rewardBalance = rb;
        } catch {
            // keep 0
        }

        bool anyStat;
        for (uint256 k = 0; k < STAT_COUNT;) {
            uint256 tokenId = STAT_TOKEN_ID_MIN + k;
            try c.balanceOf(eoa, tokenId) returns (uint256 balE) {
                s.statBalancesEoa[k] = balE;
                if (balE > 0) anyStat = true;
            } catch {}
            if (aaOptional != address(0)) {
                try c.balanceOf(aaOptional, tokenId) returns (uint256 balA) {
                    s.statBalancesAa[k] = balA;
                    if (balA > 0) anyStat = true;
                } catch {}
            }
            unchecked {
                ++k;
            }
        }

        s.hasAnyProgramAsset = s.points > 0 || s.membershipNfts.length > 0 || anyStat;
        s.ok = true;
    }

    uint256[49] private __gap;
}
