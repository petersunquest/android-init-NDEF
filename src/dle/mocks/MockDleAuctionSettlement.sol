// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @notice Local-only ERC-721 fixture used by the DLE mock-L1 auction tests.
/// @dev This contract is intentionally not a production collection.
contract MockDleAuctionNft is ERC721 {
    uint256 public nextTokenId = 1;

    constructor() ERC721("DLE Mock Auction NFT", "DLE-AUCTION") {}

    function mint(address to) external returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        _safeMint(to, tokenId);
    }
}

/// @notice Local-only settlement escrow for a certificate-driven DLE match.
/// @dev `certificateAuthority` represents the already verified Archive/on-demand
/// certificate bridge. It is deliberately configurable only in this mock
/// environment and must not be treated as a production settlement design.
contract MockDleAuctionSettlement is IERC721Receiver {
    error NotCertificateAuthority();
    error ListingExists();
    error ListingMissing();
    error ListingExpired();
    error CertificateAlreadySettled();
    error InvalidRecipient();
    error InvalidCommittee();

    struct Listing {
        address seller;
        address subjectNft;
        uint256 subjectNftId;
        address quoteAsset;
        uint256 askAmount;
        uint64 deadline;
        bool settled;
    }

    address public immutable certificateAuthority;
    mapping(bytes32 => Listing) public listings;
    mapping(bytes32 => bool) public settledCertificate;

    event Listed(
        bytes32 indexed sellerOrderHash,
        address indexed seller,
        address indexed subjectNft,
        uint256 subjectNftId,
        address quoteAsset,
        uint256 askAmount,
        uint64 deadline
    );
    event Settled(
        bytes32 indexed certificateHash,
        bytes32 indexed sellerOrderHash,
        address indexed buyer,
        uint256 clearingAmount,
        uint256 feeAmount,
        address scanner,
        uint256 scannerReward,
        uint256 committeeReward
    );

    constructor(address certificateAuthority_) {
        if (certificateAuthority_ == address(0)) revert InvalidRecipient();
        certificateAuthority = certificateAuthority_;
    }

    function list(
        bytes32 sellerOrderHash,
        address subjectNft,
        uint256 subjectNftId,
        address quoteAsset,
        uint256 askAmount,
        uint64 deadline
    ) external {
        if (
            sellerOrderHash == bytes32(0) ||
            subjectNft == address(0) ||
            quoteAsset == address(0) ||
            askAmount == 0 ||
            deadline <= block.timestamp
        ) revert InvalidRecipient();
        if (listings[sellerOrderHash].seller != address(0)) revert ListingExists();

        listings[sellerOrderHash] = Listing({
            seller: msg.sender,
            subjectNft: subjectNft,
            subjectNftId: subjectNftId,
            quoteAsset: quoteAsset,
            askAmount: askAmount,
            deadline: deadline,
            settled: false
        });
        IERC721(subjectNft).safeTransferFrom(msg.sender, address(this), subjectNftId);
        emit Listed(sellerOrderHash, msg.sender, subjectNft, subjectNftId, quoteAsset, askAmount, deadline);
    }

    /// @notice Atomically exchanges a listed NFT for ERC-20 and splits 1 bps.
    /// @param committee Signers already accepted by the off-chain certificate.
    /// The scanner receives 50% of the fee, the signers split the other 50%.
    function settle(
        bytes32 certificateHash,
        bytes32 sellerOrderHash,
        address buyer,
        uint256 clearingAmount,
        address scanner,
        address[] calldata committee
    ) external {
        if (msg.sender != certificateAuthority) revert NotCertificateAuthority();
        if (settledCertificate[certificateHash]) revert CertificateAlreadySettled();
        if (buyer == address(0) || scanner == address(0) || committee.length == 0) revert InvalidRecipient();

        Listing storage listing = listings[sellerOrderHash];
        if (listing.seller == address(0)) revert ListingMissing();
        if (listing.settled || block.timestamp > listing.deadline) revert ListingExpired();
        if (clearingAmount < listing.askAmount) revert InvalidRecipient();

        uint256 feeAmount = clearingAmount / 10_000;
        uint256 scannerReward = feeAmount / 2;
        uint256 committeeReward = feeAmount - scannerReward;
        uint256 perCommittee = committeeReward / committee.length;
        uint256 committeeRemainder = committeeReward - (perCommittee * committee.length);

        settledCertificate[certificateHash] = true;
        listing.settled = true;
        IERC20 quote = IERC20(listing.quoteAsset);
        if (!quote.transferFrom(buyer, listing.seller, clearingAmount - feeAmount)) revert InvalidRecipient();
        if (scannerReward != 0 && !quote.transferFrom(buyer, scanner, scannerReward)) revert InvalidRecipient();
        for (uint256 i; i < committee.length; ++i) {
            if (committee[i] == address(0)) revert InvalidCommittee();
            uint256 reward = perCommittee + (i == 0 ? committeeRemainder : 0);
            if (reward != 0 && !quote.transferFrom(buyer, committee[i], reward)) revert InvalidRecipient();
        }
        IERC721(listing.subjectNft).safeTransferFrom(address(this), buyer, listing.subjectNftId);

        emit Settled(
            certificateHash,
            sellerOrderHash,
            buyer,
            clearingAmount,
            feeAmount,
            scanner,
            scannerReward,
            committeeReward
        );
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
