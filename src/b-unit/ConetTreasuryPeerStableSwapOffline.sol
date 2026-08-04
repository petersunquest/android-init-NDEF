// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ConetTreasuryPeerStableSwapSigLib} from "./ConetTreasuryPeerStableSwapSigLib.sol";

interface IConetTreasuryPeerStableSwapFor {
    function bridgeStableSwapFor(
        address user,
        uint8 burnAssetKind,
        uint256 amount,
        uint256 destinationChainId,
        address recipient,
        uint8 creditAssetKind,
        uint256 minCreditAmount
    ) external;

    function treasury() external view returns (address);
}

interface IConetTreasuryGovernanceOffline {
    function isMiner(address account) external view returns (bool);
}

/**
 * @title ConetTreasuryPeerStableSwapOffline
 * @notice 本链离线签字 StableSwap：EIP-712 + nonce 在此合约；验签后调 Peer.bridgeStableSwapFor。
 *         EIP-712 domain.name = "ConetTreasuryPeer", version = "1", verifyingContract = Peer（与产品文档一致）。
 *         首期强制 destinationChainId == block.chainid == 224422。
 */
contract ConetTreasuryPeerStableSwapOffline {
    uint256 public constant CONET_CHAIN_ID = 224422;

    address public immutable peer;
    bytes32 public immutable DOMAIN_SEPARATOR;

    mapping(address => uint256) public stableSwapNonces;

    error NotMiner();
    error InvalidTarget();
    error SignatureExpired();
    error InvalidSignature();

    event PeerStableSwapOfflineExecuted(
        address indexed user,
        uint8 burnAssetKind,
        uint256 amount,
        uint8 creditAssetKind,
        uint256 destinationChainId,
        address recipient,
        uint256 nonce
    );

    modifier onlyMiner() {
        address treasury = IConetTreasuryPeerStableSwapFor(peer).treasury();
        if (!IConetTreasuryGovernanceOffline(treasury).isMiner(msg.sender)) revert NotMiner();
        _;
    }

    constructor(address peer_) {
        if (peer_ == address(0)) revert InvalidTarget();
        peer = peer_;
        // verifyingContract = Peer（签字绑定 Peer 地址；本合约为执行入口）
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("ConetTreasuryPeer")),
                keccak256(bytes("1")),
                block.chainid,
                peer_
            )
        );
    }

    function getStableSwapDigest(
        address user,
        uint8 burnAssetKind,
        uint256 amount,
        uint256 destinationChainId,
        address recipient,
        uint8 creditAssetKind,
        uint256 minCreditAmount,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        return ConetTreasuryPeerStableSwapSigLib.digest(
            DOMAIN_SEPARATOR,
            user,
            burnAssetKind,
            amount,
            destinationChainId,
            recipient,
            creditAssetKind,
            minCreditAmount,
            nonce,
            deadline
        );
    }

    /**
     * @notice 用户签 EIP-712 `StableSwap` 后，任何人可代付 gas 提交。
     *         USDC→* 须 user 已 `approve(ConetTreasury, amount)`（或 Relayer 先提交 EIP-2612 permit）。
     */
    function bridgeStableSwapWithSignature(
        address user,
        uint8 burnAssetKind,
        uint256 amount,
        uint256 destinationChainId,
        address recipient,
        uint8 creditAssetKind,
        uint256 minCreditAmount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (user == address(0)) revert InvalidTarget();
        if (block.timestamp > deadline) revert SignatureExpired();
        if (stableSwapNonces[user] != nonce) revert InvalidSignature();
        if (destinationChainId != block.chainid || block.chainid != CONET_CHAIN_ID) revert InvalidTarget();

        ConetTreasuryPeerStableSwapSigLib.recoverUser(
            DOMAIN_SEPARATOR,
            user,
            burnAssetKind,
            amount,
            destinationChainId,
            recipient,
            creditAssetKind,
            minCreditAmount,
            nonce,
            deadline,
            signature
        );

        stableSwapNonces[user] = nonce + 1;

        IConetTreasuryPeerStableSwapFor(peer).bridgeStableSwapFor(
            user,
            burnAssetKind,
            amount,
            destinationChainId,
            recipient,
            creditAssetKind,
            minCreditAmount
        );

        emit PeerStableSwapOfflineExecuted(
            user, burnAssetKind, amount, creditAssetKind, destinationChainId, recipient, nonce
        );
    }
}
