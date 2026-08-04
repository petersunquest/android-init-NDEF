// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

/// @dev 本链离线签字 StableSwap 的 EIP-712 digest / recover（外部 library，减轻 Peer bytecode）。
library ConetTreasuryPeerStableSwapSigLib {
    bytes32 internal constant STABLE_SWAP_TYPEHASH = keccak256(
        "StableSwap(address user,uint8 burnAssetKind,uint256 amount,uint256 destinationChainId,address recipient,uint8 creditAssetKind,uint256 minCreditAmount,uint256 nonce,uint256 deadline)"
    );

    error InvalidSignature();

    function digest(
        bytes32 domainSeparator,
        address user,
        uint8 burnAssetKind,
        uint256 amount,
        uint256 destinationChainId,
        address recipient,
        uint8 creditAssetKind,
        uint256 minCreditAmount,
        uint256 nonce,
        uint256 deadline
    ) public pure returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                STABLE_SWAP_TYPEHASH,
                user,
                burnAssetKind,
                amount,
                destinationChainId,
                recipient,
                creditAssetKind,
                minCreditAmount,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function recoverUser(
        bytes32 domainSeparator,
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
    ) external pure returns (address signer) {
        bytes32 d = digest(
            domainSeparator,
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
        signer = ECDSA.recover(d, signature);
        if (signer != user) revert InvalidSignature();
    }
}
