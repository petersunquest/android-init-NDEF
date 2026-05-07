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

    event IssuedNftCreated(uint256 indexed tokenId, bytes32 title, uint64 validAfter, uint64 validBefore, uint256 maxSupply, uint256 priceInCurrency6, bytes32 sharedMetadataHash);
    event IssuedNftMinted(uint256 indexed tokenId, address indexed recipient, uint256 amount);
    event IssuedNftBurned(uint256 indexed tokenId, address indexed holder, uint256 amount);

    constructor() ERC1155("") {}

    modifier onlyOwnerOrGateway() {
        address cardOwner = IUserCardCtx(address(this)).owner();
        address gw = IUserCardCtx(address(this)).factoryGateway();
        if (msg.sender != cardOwner && msg.sender != gw) revert BM_NotAuthorized();
        _;
    }

    modifier onlyGateway() {
        if (msg.sender != IUserCardCtx(address(this)).factoryGateway()) revert UC_UnauthorizedGateway();
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
        l.issuedNftTitle[tokenId] = title;
        l.issuedNftValidAfter[tokenId] = validAfter;
        l.issuedNftValidBefore[tokenId] = validBefore;
        l.issuedNftMaxSupply[tokenId] = maxSupply;
        l.issuedNftPriceInCurrency6[tokenId] = priceInCurrency6;
        l.issuedNftSharedMetadataHash[tokenId] = sharedMetadataHash;

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

    /// @notice Gateway/owner burn issued NFT balance from a holder account (POS consume path).
    /// @dev `holder` should be the user's AA account in production flow.
    function burnIssuedNftByGateway(address holder, uint256 tokenId, uint256 amount) external onlyOwnerOrGateway {
        if (holder == address(0)) revert BM_ZeroAddress();
        if (tokenId < ISSUED_NFT_START_ID) revert UC_InvalidTokenId(tokenId, ISSUED_NFT_START_ID);
        if (amount == 0) revert UC_AmountZero();

        uint256 maxSupply = IssuedNftStorage.layout().issuedNftMaxSupply[tokenId];
        if (maxSupply == 0) revert UC_InvalidTokenId(tokenId, 0);

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
        uint256 cnt = l.issuedNftMintedCount[tokenId];
        if (cnt + amount > maxSupply) revert UC_InsufficientBalance(address(this), tokenId, maxSupply - cnt, amount);

        l.issuedNftUserSigClaimUsed[claimKey] = true;
        l.issuedNftMintedCount[tokenId] = cnt + amount;

        emit IssuedNftMinted(tokenId, recipientAcct, amount);
    }
}
