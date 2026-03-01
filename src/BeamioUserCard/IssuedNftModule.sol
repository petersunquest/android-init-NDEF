// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./IssuedNftStorage.sol";
import "./BeamioERC1155Logic.sol";

interface IUserCardCtx {
    function owner() external view returns (address);
    function factoryGateway() external view returns (address);
}

/**
 * @title BeamioUserCardIssuedNftModuleV1
 * @notice Delegatecall module for issued NFT definition and mint recording. Card does _mint after validateAndRecordMint.
 */
contract BeamioUserCardIssuedNftModuleV1 {
    uint256 private constant ISSUED_NFT_START_ID = BeamioERC1155Logic.ISSUED_NFT_START_ID;

    event IssuedNftCreated(uint256 indexed tokenId, bytes32 title, uint64 validAfter, uint64 validBefore, uint256 maxSupply, uint256 priceInCurrency6, bytes32 sharedMetadataHash);
    event IssuedNftMinted(uint256 indexed tokenId, address indexed recipient, uint256 amount);

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
}
