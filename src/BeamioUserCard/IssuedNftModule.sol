// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./IssuedNftStorage.sol";
import "./BeamioERC1155Logic.sol";
import "../contracts/token/ERC1155/ERC1155.sol";

interface IUserCardCtx {
    function owner() external view returns (address);
    function factoryGateway() external view returns (address);
}

/**
 * @title BeamioUserCardIssuedNftModuleV1
 * @notice Delegatecall module for issued NFT definition and mint recording. Card does _mint after validateAndRecordMint.
 */
contract BeamioUserCardIssuedNftModuleV1 is ERC1155 {
    uint256 private constant ISSUED_NFT_START_ID = BeamioERC1155Logic.ISSUED_NFT_START_ID;
    uint256 public constant CARD_REFERRAL_CLICK_TOKEN_ID = 10;
    uint256 public constant CARD_REFERRAL_CLAIM_TOKEN_ID = 11;
    uint256 public constant CARD_REFERRAL_BURN_TOKEN_ID = 12;
    uint256 public constant COUPON_REFERRAL_CLICK_OFFSET = 200_000_000_000;
    uint256 public constant COUPON_REFERRAL_CLAIM_OFFSET = 300_000_000_000;
    uint256 public constant COUPON_REFERRAL_BURN_OFFSET = 400_000_000_000;
    uint256 public constant ISSUED_NFT_TRAFFIC_OFFSET = 500_000_000_000;

    uint8 public constant STAT_KIND_REFERRAL_CLICK = 1;
    uint8 public constant STAT_KIND_REFERRAL_CLAIM = 2;
    uint8 public constant STAT_KIND_REFERRAL_BURN = 3;
    uint8 public constant STAT_KIND_TRAFFIC = 4;

    event IssuedNftCreated(uint256 indexed tokenId, bytes32 title, uint64 validAfter, uint64 validBefore, uint256 maxSupply, uint256 priceInCurrency6, bytes32 sharedMetadataHash);
    event IssuedNftMinted(uint256 indexed tokenId, address indexed recipient, uint256 amount);
    event IssuedNftBurned(uint256 indexed tokenId, address indexed holder, uint256 amount);
    event IssuedNftStatTokenInitialized(uint256 indexed tokenId, uint256 indexed parentTokenId, uint8 indexed statKind);
    event ReferralStatRecorded(uint256 indexed tokenId, address indexed wallet, uint8 indexed statKind, uint256 amount);
    event IssuedNftShareRecorded(uint256 indexed tokenId, address indexed wallet, uint256 shareCount, bool counted);
    event IssuedNftLikeUpdated(uint256 indexed tokenId, address indexed wallet, bool liked, uint256 likeCount);
    event IssuedNftCommentRecorded(uint256 indexed tokenId, address indexed wallet, bytes32 indexed commentIpfsHash, uint256 commentCount);
    event IssuedNftAccessRecorded(uint256 indexed tokenId, address indexed wallet, uint256 trafficGB18, uint256 accessCount);
    event IssuedNftPurchaseRecorded(uint256 indexed tokenId, address indexed wallet, uint256 amount6, uint256 purchaseCount);

    constructor() ERC1155("") {}

    modifier onlyOwnerOrGateway() {
        address cardOwner = IUserCardCtx(address(this)).owner();
        address gw = IUserCardCtx(address(this)).factoryGateway();
        if (msg.sender != cardOwner && msg.sender != gw) revert BM_NotAuthorized();
        _;
    }

    modifier onlyGateway() {
        // External routes enter through the factory gateway; card-internal flows
        // call modules through cardSelfCallModule, where msg.sender is the card.
        if (msg.sender != address(this) && msg.sender != IUserCardCtx(address(this)).factoryGateway()) {
            revert UC_UnauthorizedGateway();
        }
        _;
    }

    modifier onlyOwnerAdminOrGateway() {
        if (!_isOwnerAdminOrGateway(msg.sender)) revert BM_NotAuthorized();
        _;
    }

    function createIssuedNft(
        bytes32 title,
        uint64 validAfter,
        uint64 validBefore,
        uint256 maxSupply,
        uint256 priceInCurrency6,
        bytes32 sharedMetadataHash
    ) external onlyOwnerOrGateway returns (uint256 tokenId) {
        if (maxSupply == 0) revert UC_AmountZero();
        if (validBefore != 0 && validBefore < validAfter) revert UC_InvalidDateRange(validAfter, validBefore);

        IssuedNftStorage.Layout storage l = IssuedNftStorage.layout();
        tokenId = l.issuedNftIndex++;
        if (tokenId >= COUPON_REFERRAL_CLICK_OFFSET) revert UC_InvalidTokenId(tokenId, COUPON_REFERRAL_CLICK_OFFSET);
        l.issuedNftTitle[tokenId] = title;
        l.issuedNftValidAfter[tokenId] = validAfter;
        l.issuedNftValidBefore[tokenId] = validBefore;
        l.issuedNftMaxSupply[tokenId] = maxSupply;
        l.issuedNftPriceInCurrency6[tokenId] = priceInCurrency6;
        l.issuedNftSharedMetadataHash[tokenId] = sharedMetadataHash;
        _initializeIssuedNftStatTokens(l, tokenId);

        emit IssuedNftCreated(tokenId, title, validAfter, validBefore, maxSupply, priceInCurrency6, sharedMetadataHash);
    }

    /// @notice EIP-1155 URI / coupon series registration: hash committed at createIssuedNft (card fallback delegatecalls here)
    function issuedNftSharedMetadataHash(uint256 tokenId) external view returns (bytes32) {
        return IssuedNftStorage.layout().issuedNftSharedMetadataHash[tokenId];
    }

    /// @notice Read max supply for an issued NFT series.
    function issuedNftMaxSupply(uint256 tokenId) external view returns (uint256) {
        return IssuedNftStorage.layout().issuedNftMaxSupply[tokenId];
    }

    /// @notice Read minted count for an issued NFT series.
    function issuedNftMintedCount(uint256 tokenId) external view returns (uint256) {
        return IssuedNftStorage.layout().issuedNftMintedCount[tokenId];
    }

    function isIssuedNftStatToken(uint256 tokenId) external view returns (bool) {
        return IssuedNftStorage.layout().issuedNftIsStatToken[tokenId];
    }

    function issuedNftStatTokenInfo(uint256 tokenId)
        external
        view
        returns (bool isStatToken, uint256 parentTokenId, uint8 statKind)
    {
        IssuedNftStorage.Layout storage l = IssuedNftStorage.layout();
        return (l.issuedNftIsStatToken[tokenId], l.issuedNftStatParentTokenId[tokenId], l.issuedNftStatKind[tokenId]);
    }

    function issuedNftReferralStatTokenId(uint256 tokenId, uint8 statKind) external pure returns (uint256) {
        return _issuedNftReferralStatTokenId(tokenId, statKind);
    }

    function issuedNftTrafficStatTokenId(uint256 tokenId) external pure returns (uint256) {
        return tokenId + ISSUED_NFT_TRAFFIC_OFFSET;
    }

    /// @notice Gateway/owner burn issued NFT balance from a holder account (POS consume path).
    /// @dev `holder` should be the user's AA account in production flow.
    function burnIssuedNftByGateway(address holder, uint256 tokenId, uint256 amount) external onlyOwnerOrGateway {
        if (holder == address(0)) revert BM_ZeroAddress();
        if (tokenId < ISSUED_NFT_START_ID) revert UC_InvalidTokenId(tokenId, ISSUED_NFT_START_ID);
        if (amount == 0) revert UC_AmountZero();

        uint256 maxSupply = IssuedNftStorage.layout().issuedNftMaxSupply[tokenId];
        if (maxSupply == 0) revert UC_InvalidTokenId(tokenId, 0);
        _requireRealIssuedNft(tokenId);

        _burn(holder, tokenId, amount);
        emit IssuedNftBurned(tokenId, holder, amount);
    }

    /// @notice Validate and record mint; card does _mint(acct, tokenId, amount) after.
    function validateAndRecordMintIssuedNft(address acct, uint256 tokenId, uint256 amount) external onlyGateway {
        if (acct == address(0)) revert BM_ZeroAddress();
        if (amount == 0) revert UC_AmountZero();
        if (tokenId < ISSUED_NFT_START_ID) revert UC_InvalidTokenId(tokenId, ISSUED_NFT_START_ID);

        IssuedNftStorage.Layout storage l = IssuedNftStorage.layout();
        uint256 maxSupply = l.issuedNftMaxSupply[tokenId];
        if (maxSupply == 0) revert UC_InvalidTokenId(tokenId, 0);
        _requireRealIssuedNft(tokenId);
        uint256 cnt = l.issuedNftMintedCount[tokenId];
        if (cnt + amount > maxSupply) revert UC_InsufficientBalance(address(this), tokenId, maxSupply - cnt, amount);
        l.issuedNftMintedCount[tokenId] = cnt + amount;

        emit IssuedNftMinted(tokenId, acct, amount);
    }

    /// @notice Free user-signed mint path (via Factory): exactly 1; one claim per userEOA per tokenId.
    /// @dev Card must gate priceInCurrency6==0 to avoid bypassing paid purchase.
    function validateAndRecordMintIssuedNftUserSigClaim(address userEOA, address recipientAcct, uint256 tokenId) external onlyGateway {
        if (userEOA == address(0) || recipientAcct == address(0)) revert BM_ZeroAddress();
        if (tokenId < ISSUED_NFT_START_ID) revert UC_InvalidTokenId(tokenId, ISSUED_NFT_START_ID);

        IssuedNftStorage.Layout storage l = IssuedNftStorage.layout();
        bytes32 claimKey = keccak256(abi.encode(userEOA, tokenId));
        if (l.issuedNftUserSigClaimUsed[claimKey]) revert UC_IssuedNftSigClaimAlreadyUsed(userEOA, tokenId);

        uint256 price = l.issuedNftPriceInCurrency6[tokenId];
        if (price != 0) revert UC_IssuedNftSigClaimNotFree(tokenId, price);

        uint256 amount = 1;
        uint256 maxSupply = l.issuedNftMaxSupply[tokenId];
        if (maxSupply == 0) revert UC_InvalidTokenId(tokenId, 0);
        _requireRealIssuedNft(tokenId);
        uint256 cnt = l.issuedNftMintedCount[tokenId];
        if (cnt + amount > maxSupply) revert UC_InsufficientBalance(address(this), tokenId, maxSupply - cnt, amount);

        l.issuedNftUserSigClaimUsed[claimKey] = true;
        l.issuedNftMintedCount[tokenId] = cnt + amount;

        emit IssuedNftMinted(tokenId, recipientAcct, amount);
    }

    /// @notice 检查 issued NFT 是否在有效期内
    function isIssuedNftValid(uint256 tokenId) external view returns (bool) {
        if (tokenId < ISSUED_NFT_START_ID) return false;
        IssuedNftStorage.Layout storage l = IssuedNftStorage.layout();
        if (l.issuedNftIsStatToken[tokenId]) return false;
        uint64 va = l.issuedNftValidAfter[tokenId];
        uint64 vb = l.issuedNftValidBefore[tokenId];
        uint256 ts = block.timestamp;
        if (va != 0 && ts < va) return false;
        if (vb != 0 && ts > vb) return false;
        return true;
    }

    function recordCardReferralStat(address wallet, uint256 tokenId, uint256 amount) external onlyOwnerAdminOrGateway {
        if (wallet == address(0)) revert BM_ZeroAddress();
        if (amount == 0) revert UC_AmountZero();
        uint8 statKind = _cardReferralStatKind(tokenId);
        _mint(wallet, tokenId, amount, "");
        emit ReferralStatRecorded(tokenId, wallet, statKind, amount);
    }

    function recordIssuedNftReferralStat(uint256 tokenId, address wallet, uint8 statKind, uint256 amount)
        external
        onlyOwnerAdminOrGateway
        returns (uint256 statTokenId)
    {
        if (wallet == address(0)) revert BM_ZeroAddress();
        if (amount == 0) revert UC_AmountZero();
        _requireRealIssuedNft(tokenId);
        statTokenId = _issuedNftReferralStatTokenId(tokenId, statKind);
        _requireStatToken(statTokenId);
        _mint(wallet, statTokenId, amount, "");
        emit ReferralStatRecorded(statTokenId, wallet, statKind, amount);
    }

    function recordIssuedNftTraffic(uint256 tokenId, address wallet, uint256 trafficGB18)
        external
        onlyOwnerAdminOrGateway
        returns (uint256 statTokenId)
    {
        if (wallet == address(0)) revert BM_ZeroAddress();
        if (trafficGB18 == 0) revert UC_AmountZero();
        _requireRealIssuedNft(tokenId);
        statTokenId = tokenId + ISSUED_NFT_TRAFFIC_OFFSET;
        _requireStatToken(statTokenId);
        IssuedNftStorage.Layout storage l = IssuedNftStorage.layout();
        l.issuedNftTrafficGB18[tokenId] += trafficGB18;
        IssuedNftStorage.UserContentStats storage u = l.issuedNftUserContentStats[tokenId][wallet];
        u.trafficGB18 += trafficGB18;
        _mint(wallet, statTokenId, trafficGB18, "");
        emit ReferralStatRecorded(statTokenId, wallet, STAT_KIND_TRAFFIC, trafficGB18);
    }

    function recordIssuedNftShare(uint256 tokenId, address wallet) external returns (bool counted, uint256 shareCount) {
        _requireWalletSelfOrRecorder(wallet);
        _requireRealIssuedNft(tokenId);
        IssuedNftStorage.Layout storage l = IssuedNftStorage.layout();
        bytes32 key = _walletTokenKey(wallet, tokenId);
        if (!l.issuedNftSharedByWallet[key]) {
            l.issuedNftSharedByWallet[key] = true;
            l.issuedNftShareCount[tokenId] += 1;
            counted = true;
        }
        shareCount = l.issuedNftShareCount[tokenId];
        emit IssuedNftShareRecorded(tokenId, wallet, shareCount, counted);
    }

    function setIssuedNftLike(uint256 tokenId, address wallet, bool liked) external returns (uint256 likeCount) {
        _requireWalletSelfOrRecorder(wallet);
        _requireRealIssuedNft(tokenId);
        IssuedNftStorage.Layout storage l = IssuedNftStorage.layout();
        bytes32 key = _walletTokenKey(wallet, tokenId);
        bool old = l.issuedNftLikedByWallet[key];
        if (old != liked) {
            l.issuedNftLikedByWallet[key] = liked;
            if (liked) l.issuedNftLikeCount[tokenId] += 1;
            else l.issuedNftLikeCount[tokenId] -= 1;
        }
        likeCount = l.issuedNftLikeCount[tokenId];
        emit IssuedNftLikeUpdated(tokenId, wallet, liked, likeCount);
    }

    function recordIssuedNftComment(uint256 tokenId, address wallet, bytes32 commentIpfsHash)
        external
        returns (uint256 commentCount)
    {
        _requireWalletSelfOrRecorder(wallet);
        _requireRealIssuedNft(tokenId);
        if (commentIpfsHash == bytes32(0)) revert BM_InvalidSecret();
        IssuedNftStorage.Layout storage l = IssuedNftStorage.layout();
        l.issuedNftCommentCount[tokenId] += 1;
        commentCount = l.issuedNftCommentCount[tokenId];
        emit IssuedNftCommentRecorded(tokenId, wallet, commentIpfsHash, commentCount);
    }

    function recordIssuedNftAccess(uint256 tokenId, address wallet, uint256 trafficGB18)
        external
        returns (uint256 accessCount)
    {
        _requireWalletSelfOrRecorder(wallet);
        _requireRealIssuedNft(tokenId);
        IssuedNftStorage.Layout storage l = IssuedNftStorage.layout();
        l.issuedNftAccessCount[tokenId] += 1;
        if (l.issuedNftFirstAccessAt[tokenId] == 0) l.issuedNftFirstAccessAt[tokenId] = uint64(block.timestamp);
        if (trafficGB18 != 0) l.issuedNftTrafficGB18[tokenId] += trafficGB18;
        IssuedNftStorage.UserContentStats storage u = l.issuedNftUserContentStats[tokenId][wallet];
        u.accessCount += 1;
        if (u.firstAccessAt == 0) u.firstAccessAt = uint64(block.timestamp);
        if (trafficGB18 != 0) u.trafficGB18 += trafficGB18;
        accessCount = l.issuedNftAccessCount[tokenId];
        emit IssuedNftAccessRecorded(tokenId, wallet, trafficGB18, accessCount);
    }

    function recordIssuedNftPurchase(uint256 tokenId, address wallet, uint256 amount6)
        external
        onlyOwnerAdminOrGateway
        returns (uint256 purchaseCount)
    {
        if (wallet == address(0)) revert BM_ZeroAddress();
        _requireRealIssuedNft(tokenId);
        IssuedNftStorage.Layout storage l = IssuedNftStorage.layout();
        l.issuedNftPurchaseCount[tokenId] += 1;
        if (amount6 != 0) l.issuedNftSalesAmount6[tokenId] += amount6;
        IssuedNftStorage.UserContentStats storage u = l.issuedNftUserContentStats[tokenId][wallet];
        u.purchaseCount += 1;
        if (amount6 != 0) u.purchaseAmount6 += amount6;
        if (u.firstPurchaseAt == 0) u.firstPurchaseAt = uint64(block.timestamp);
        purchaseCount = l.issuedNftPurchaseCount[tokenId];
        emit IssuedNftPurchaseRecorded(tokenId, wallet, amount6, purchaseCount);
    }

    function issuedNftSocialStats(uint256 tokenId)
        external
        view
        returns (uint256 shareCount, uint256 likeCount, uint256 commentCount)
    {
        IssuedNftStorage.Layout storage l = IssuedNftStorage.layout();
        return (l.issuedNftShareCount[tokenId], l.issuedNftLikeCount[tokenId], l.issuedNftCommentCount[tokenId]);
    }

    function issuedNftSharedByWallet(uint256 tokenId, address wallet) external view returns (bool) {
        return IssuedNftStorage.layout().issuedNftSharedByWallet[_walletTokenKey(wallet, tokenId)];
    }

    function issuedNftLikedByWallet(uint256 tokenId, address wallet) external view returns (bool) {
        return IssuedNftStorage.layout().issuedNftLikedByWallet[_walletTokenKey(wallet, tokenId)];
    }

    function issuedNftContentStats(uint256 tokenId)
        external
        view
        returns (
            uint256 accessCount,
            uint64 firstAccessAt,
            uint256 trafficGB18,
            uint256 salesAmount6,
            uint256 purchaseCount
        )
    {
        IssuedNftStorage.Layout storage l = IssuedNftStorage.layout();
        return (
            l.issuedNftAccessCount[tokenId],
            l.issuedNftFirstAccessAt[tokenId],
            l.issuedNftTrafficGB18[tokenId],
            l.issuedNftSalesAmount6[tokenId],
            l.issuedNftPurchaseCount[tokenId]
        );
    }

    function issuedNftUserContentStats(uint256 tokenId, address wallet)
        external
        view
        returns (
            uint256 purchaseCount,
            uint256 purchaseAmount6,
            uint64 firstPurchaseAt,
            uint64 firstAccessAt,
            uint256 accessCount,
            uint256 trafficGB18
        )
    {
        IssuedNftStorage.UserContentStats storage u =
            IssuedNftStorage.layout().issuedNftUserContentStats[tokenId][wallet];
        return (u.purchaseCount, u.purchaseAmount6, u.firstPurchaseAt, u.firstAccessAt, u.accessCount, u.trafficGB18);
    }

    /// @notice Whether `userEOA` has consumed the EIP-712 free claim slot for `tokenId`.
    function issuedNftUserSigClaimUsed(address userEOA, uint256 tokenId) external view returns (bool) {
        bytes32 key = keccak256(abi.encode(userEOA, tokenId));
        return IssuedNftStorage.layout().issuedNftUserSigClaimUsed[key];
    }

    function _initializeIssuedNftStatTokens(IssuedNftStorage.Layout storage l, uint256 parentTokenId) private {
        _initializeIssuedNftStatToken(l, parentTokenId, parentTokenId + COUPON_REFERRAL_CLICK_OFFSET, STAT_KIND_REFERRAL_CLICK);
        _initializeIssuedNftStatToken(l, parentTokenId, parentTokenId + COUPON_REFERRAL_CLAIM_OFFSET, STAT_KIND_REFERRAL_CLAIM);
        _initializeIssuedNftStatToken(l, parentTokenId, parentTokenId + COUPON_REFERRAL_BURN_OFFSET, STAT_KIND_REFERRAL_BURN);
        _initializeIssuedNftStatToken(l, parentTokenId, parentTokenId + ISSUED_NFT_TRAFFIC_OFFSET, STAT_KIND_TRAFFIC);
    }

    function _initializeIssuedNftStatToken(
        IssuedNftStorage.Layout storage l,
        uint256 parentTokenId,
        uint256 statTokenId,
        uint8 statKind
    ) private {
        l.issuedNftMaxSupply[statTokenId] = type(uint256).max;
        l.issuedNftIsStatToken[statTokenId] = true;
        l.issuedNftStatParentTokenId[statTokenId] = parentTokenId;
        l.issuedNftStatKind[statTokenId] = statKind;
        emit IssuedNftStatTokenInitialized(statTokenId, parentTokenId, statKind);
    }

    function _requireRealIssuedNft(uint256 tokenId) private view {
        IssuedNftStorage.Layout storage l = IssuedNftStorage.layout();
        if (tokenId < ISSUED_NFT_START_ID) revert UC_InvalidTokenId(tokenId, ISSUED_NFT_START_ID);
        if (l.issuedNftMaxSupply[tokenId] == 0) revert UC_InvalidTokenId(tokenId, 0);
        if (l.issuedNftIsStatToken[tokenId]) revert UC_InvalidTokenId(tokenId, 0);
    }

    function _requireStatToken(uint256 tokenId) private view {
        if (!IssuedNftStorage.layout().issuedNftIsStatToken[tokenId]) revert UC_InvalidTokenId(tokenId, 0);
    }

    function _issuedNftReferralStatTokenId(uint256 tokenId, uint8 statKind) private pure returns (uint256) {
        if (statKind == STAT_KIND_REFERRAL_CLICK) return tokenId + COUPON_REFERRAL_CLICK_OFFSET;
        if (statKind == STAT_KIND_REFERRAL_CLAIM) return tokenId + COUPON_REFERRAL_CLAIM_OFFSET;
        if (statKind == STAT_KIND_REFERRAL_BURN) return tokenId + COUPON_REFERRAL_BURN_OFFSET;
        revert UC_InvalidTokenId(uint256(statKind), 0);
    }

    function _cardReferralStatKind(uint256 tokenId) private pure returns (uint8) {
        if (tokenId == CARD_REFERRAL_CLICK_TOKEN_ID) return STAT_KIND_REFERRAL_CLICK;
        if (tokenId == CARD_REFERRAL_CLAIM_TOKEN_ID) return STAT_KIND_REFERRAL_CLAIM;
        if (tokenId == CARD_REFERRAL_BURN_TOKEN_ID) return STAT_KIND_REFERRAL_BURN;
        revert UC_InvalidTokenId(tokenId, CARD_REFERRAL_CLICK_TOKEN_ID);
    }

    function _walletTokenKey(address wallet, uint256 tokenId) private pure returns (bytes32) {
        return keccak256(abi.encode(wallet, tokenId));
    }

    function _requireWalletSelfOrRecorder(address wallet) private view {
        if (wallet == address(0)) revert BM_ZeroAddress();
        if (msg.sender == wallet || _isOwnerAdminOrGateway(msg.sender)) return;
        revert BM_NotAuthorized();
    }

    function _isOwnerAdminOrGateway(address actor) private view returns (bool) {
        if (actor == address(this)) return true;
        if (actor == IUserCardCtx(address(this)).owner()) return true;
        if (actor == IUserCardCtx(address(this)).factoryGateway()) return true;
        (bool ok, bytes memory ret) = address(this).staticcall(abi.encodeWithSignature("isAdmin(address)", actor));
        return ok && ret.length >= 32 && abi.decode(ret, (bool));
    }
}
