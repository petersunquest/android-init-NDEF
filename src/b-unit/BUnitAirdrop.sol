// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "../contracts/access/Ownable.sol";
import {IERC20} from "../contracts/token/ERC20/IERC20.sol";
import {EIP712} from "../contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

/**
 * @title BUnitAirdrop
 * @dev 管理 B-Units 空投，每个钱包仅可申领一次 20 BUint（免费池）。
 *      支持：1) 用户自领 claim()  2) 离线签字 + 代理提交 claimFor() 代付 gas。
 *      本合约需为 BeamioBUnits admin，以便 claim 时调用 mintReward。
 *      提供 B-Units 余额与 BeamioUserCard 资产查询接口。
 */

interface IBeamioIndexerDiamond {
    function getBeamioUserCardTokenIndexedBalance(address beamioUserCard, uint256 tokenId, address account) external view returns (uint256);
    function getAllCardsCount() external view returns (uint256);
    function getAllCardsPaged(uint256 offset, uint256 limit) external view returns (address[] memory);
}

struct CardBalance {
    address card;
    uint256 tokenId;
    uint256 balanceE6;
}

contract BUnitAirdrop is Ownable, EIP712 {
    /// @dev 当前 CoNET mainnet 上部署的 BeamioIndexerDiamond 地址（硬编码默认值）
    address private constant DEFAULT_BEAMIO_INDEXER = 0x0DBDF27E71f9c89353bC5e4dC27c9C5dAe0cc612;

    IERC20 public immutable bunit;

    /// @dev BeamioIndexerDiamond 地址，用于查询 BeamioUserCard 资产。Admin 可更改。
    address public beamioIndexerDiamond;

    /// @dev 固定空投数量：20 BUint (6 decimals)
    uint256 public constant CLAIM_AMOUNT = 20 * 1e6;

    mapping(address => bool) public admins;
    mapping(address => bool) public hasClaimed;   // 是否已申领（一人一次）
    mapping(address => uint256) public claimNonces;  // 离线签字 replay 防护

    bytes32 private constant CLAIM_TYPEHASH =
        keccak256("ClaimAirdrop(address claimant,uint256 nonce,uint256 deadline)");

    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);
    event BeamioIndexerDiamondUpdated(address indexed oldIndexer, address indexed newIndexer);
    event Claimed(address indexed account, uint256 amount);
    event ClaimedFor(address indexed account, uint256 amount, address indexed relayer);

    modifier onlyAdmin() {
        if (msg.sender != owner() && !admins[msg.sender]) revert Unauthorized();
        _;
    }

    error Unauthorized();
    error ClaimNotAvailable();
    error TransferFailed();
    error InvalidSignature();
    error SignatureExpired();

    constructor(address _bunit, address initialOwner) Ownable(initialOwner) EIP712("BUnitAirdrop", "1") {
        bunit = IERC20(_bunit);
        beamioIndexerDiamond = DEFAULT_BEAMIO_INDEXER;
    }

    /**
     * @dev Admin 更新 BeamioIndexerDiamond 地址。
     */
    function setBeamioIndexerDiamond(address _indexer) external onlyAdmin {
        address oldIndexer = beamioIndexerDiamond;
        beamioIndexerDiamond = _indexer;
        emit BeamioIndexerDiamondUpdated(oldIndexer, _indexer);
    }

    /**
     * @dev 添加 admin。
     */
    function addAdmin(address account) external onlyOwner {
        if (account == address(0)) revert Unauthorized();
        admins[account] = true;
        emit AdminAdded(account);
    }

    /**
     * @dev 移除 admin。
     */
    function removeAdmin(address account) external onlyOwner {
        admins[account] = false;
        emit AdminRemoved(account);
    }

    /**
     * @dev 返回 claimFor 的 EIP-712 摘要，供前端 signTypedData 后传给 claimFor。
     *      domain: { name: "BUnitAirdrop", version: "1", chainId, verifyingContract }
     *      types: { ClaimAirdrop: [{ name: "claimant", type: "address" }, { name: "nonce", type: "uint256" }, { name: "deadline", type: "uint256" }] }
     */
    function getClaimDigest(address claimant, uint256 nonce, uint256 deadline) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(CLAIM_TYPEHASH, claimant, nonce, deadline));
        return _hashTypedDataV4(structHash);
    }

    /**
     * @dev 申领 20 BUint（免费池）。每账号仅可申领一次，用户自付 gas。
     */
    function claim() external {
        _doClaim(msg.sender);
        emit Claimed(msg.sender, CLAIM_AMOUNT);
    }

    /**
     * @dev 离线签字代领。用户离线签 ClaimAirdrop(claimant, nonce, deadline)，
     *      代理（如 admin）调用此函数并代付 gas，BUint 转至 claimant。
     *      signature 为 65 字节 (r,s,v)。
     */
    function claimFor(
        address claimant,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (claimNonces[claimant] != nonce) revert InvalidSignature();

        bytes32 structHash = keccak256(
            abi.encode(CLAIM_TYPEHASH, claimant, nonce, deadline)
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        if (signer != claimant) revert InvalidSignature();

        claimNonces[claimant]++;
        _doClaim(claimant);
        emit ClaimedFor(claimant, CLAIM_AMOUNT, msg.sender);
    }

    /**
     * @dev 执行申领逻辑：校验未领过，mintReward（免费池）给 account。
     */
    function _doClaim(address account) internal {
        if (hasClaimed[account]) revert ClaimNotAvailable();

        hasClaimed[account] = true;

        (bool ok,) = address(bunit).call(
            abi.encodeWithSignature("mintReward(address,uint256)", account, CLAIM_AMOUNT)
        );
        if (!ok) revert TransferFailed();
    }

    // ==========================================
    // 查询接口
    // ==========================================

    /**
     * @dev 获取 address 的 B-Units 余额。
     */
    function getBUnitBalance(address account) external view returns (uint256) {
        return bunit.balanceOf(account);
    }

    /**
     * @dev 从 BeamioIndexerDiamond 获取 address 在指定 (cards, tokenIds) 上的 BeamioUserCard 资产余额。
     *      cards 与 tokenIds 长度必须相同。使用合约内配置的 beamioIndexerDiamond 地址。
     */
    function getBeamioUserCardBalances(
        address account,
        address[] calldata cards,
        uint256[] calldata tokenIds
    ) external view returns (CardBalance[] memory) {
        require(cards.length == tokenIds.length, "length mismatch");
        require(beamioIndexerDiamond != address(0), "indexer not set");
        CardBalance[] memory result = new CardBalance[](cards.length);
        IBeamioIndexerDiamond idx = IBeamioIndexerDiamond(beamioIndexerDiamond);
        for (uint256 i = 0; i < cards.length; i++) {
            result[i] = CardBalance({
                card: cards[i],
                tokenId: tokenIds[i],
                balanceE6: idx.getBeamioUserCardTokenIndexedBalance(cards[i], tokenIds[i], account)
            });
        }
        return result;
    }

    /**
     * @dev 从 BeamioIndexerDiamond Catalog 获取所有已注册卡片，返回 address 在各卡 tokenId=0 上的余额（仅 balance>0）。
     *      最多扫描 maxCards 张卡，避免 gas 超限。使用合约内配置的 beamioIndexerDiamond 地址。
     */
    function getBeamioUserCardBalancesFromCatalog(
        address account,
        uint256 maxCards
    ) external view returns (address[] memory cards, uint256[] memory balancesE6) {
        require(beamioIndexerDiamond != address(0), "indexer not set");
        IBeamioIndexerDiamond idx = IBeamioIndexerDiamond(beamioIndexerDiamond);
        uint256 total = idx.getAllCardsCount();
        if (total == 0) return (new address[](0), new uint256[](0));

        uint256 limit = maxCards > total ? total : maxCards;
        address[] memory allCards = idx.getAllCardsPaged(0, limit);

        address[] memory tmpCards = new address[](allCards.length);
        uint256[] memory tmpBalances = new uint256[](allCards.length);
        uint256 count = 0;

        for (uint256 i = 0; i < allCards.length; i++) {
            address card = allCards[i];
            if (card == address(0)) continue;
            uint256 bal = idx.getBeamioUserCardTokenIndexedBalance(card, 0, account);
            if (bal > 0) {
                tmpCards[count] = card;
                tmpBalances[count] = bal;
                count++;
            }
        }

        cards = new address[](count);
        balancesE6 = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            cards[i] = tmpCards[i];
            balancesE6[i] = tmpBalances[i];
        }
        return (cards, balancesE6);
    }
}
