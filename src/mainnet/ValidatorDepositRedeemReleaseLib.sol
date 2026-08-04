// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ValidatorBinding} from "./ValidatorDepositRedeemTypes.sol";

interface IGuardianNodesReleaseReader {
    function id2ip(uint256 id) external view returns (string memory);
}

interface ITransferMarketGuard {
    function nodeOrder(uint256 guardianId) external view returns (uint256);
}

/**
 * @title ValidatorDepositRedeemReleaseLib
 * @notice External library: redeem-admin release of a Guardian node id back to the free pool (EIP-170 offload).
 *         Clears beneficiary + DePIN IP ownership so {_allocateGuardianNodesFromGuardian} can reuse the id.
 */
library ValidatorDepositRedeemReleaseLib {
    event GuardianNodeReleased(
        uint256 indexed guardianId,
        address indexed fromBeneficiary,
        string ip,
        address nodeWallet
    );

    function releaseOneGuardianId(
        mapping(uint256 => address) storage guardianIdBeneficiary,
        mapping(address => uint256[]) storage beneficiaryGuardianIds,
        mapping(address => address[]) storage beneficiaryGuardianNodeWallets,
        mapping(uint256 => bool) storage guardianIdGbMining,
        mapping(bytes32 => address) storage depinIpBeneficiary,
        mapping(address => address) storage nodeWalletBeneficiary,
        mapping(address => mapping(bytes32 => bool)) storage walletDepinIpSeen,
        mapping(address => string[]) storage walletDepinNodeIps,
        mapping(address => uint256) storage validatorNodeCountOf,
        mapping(address => uint256) storage gbMiningNodeCountOf,
        mapping(uint256 => ValidatorBinding) storage nodeValidator,
        address guardianNodes,
        address from,
        uint256 guardianId
    ) external {
        _releaseOneGuardianId(
            guardianIdBeneficiary,
            beneficiaryGuardianIds,
            beneficiaryGuardianNodeWallets,
            guardianIdGbMining,
            depinIpBeneficiary,
            nodeWalletBeneficiary,
            walletDepinIpSeen,
            walletDepinNodeIps,
            validatorNodeCountOf,
            gbMiningNodeCountOf,
            nodeValidator,
            guardianNodes,
            from,
            guardianId
        );
    }

    function _releaseOneGuardianId(
        mapping(uint256 => address) storage guardianIdBeneficiary,
        mapping(address => uint256[]) storage beneficiaryGuardianIds,
        mapping(address => address[]) storage beneficiaryGuardianNodeWallets,
        mapping(uint256 => bool) storage guardianIdGbMining,
        mapping(bytes32 => address) storage depinIpBeneficiary,
        mapping(address => address) storage nodeWalletBeneficiary,
        mapping(address => mapping(bytes32 => bool)) storage walletDepinIpSeen,
        mapping(address => string[]) storage walletDepinNodeIps,
        mapping(address => uint256) storage validatorNodeCountOf,
        mapping(address => uint256) storage gbMiningNodeCountOf,
        mapping(uint256 => ValidatorBinding) storage nodeValidator,
        address guardianNodes,
        address from,
        uint256 guardianId
    ) internal {
        require(guardianId != 0, "ValidatorRedeem: zero guardian id");
        require(guardianIdBeneficiary[guardianId] == from, "ValidatorRedeem: not from beneficiary node");

        ValidatorBinding storage b = nodeValidator[guardianId];
        require(!b.active, "ValidatorRedeem: validator still active");

        uint256[] storage fromIds = beneficiaryGuardianIds[from];
        address[] storage fromWallets = beneficiaryGuardianNodeWallets[from];
        uint256 len = fromIds.length;
        uint256 idx = type(uint256).max;
        for (uint256 i = 0; i < len; i++) {
            if (fromIds[i] == guardianId) {
                idx = i;
                break;
            }
        }
        require(idx != type(uint256).max, "ValidatorRedeem: node not owned");

        address nodeWallet = fromWallets[idx];

        uint256 last = len - 1;
        fromIds[idx] = fromIds[last];
        fromWallets[idx] = fromWallets[last];
        fromIds.pop();
        fromWallets.pop();

        guardianIdBeneficiary[guardianId] = address(0);

        string memory ip;
        if (guardianNodes != address(0)) {
            ip = IGuardianNodesReleaseReader(guardianNodes).id2ip(guardianId);
            if (bytes(ip).length != 0) {
                bytes32 ipKey = keccak256(bytes(ip));
                depinIpBeneficiary[ipKey] = address(0);
                _removeDepinIpFromWallet(walletDepinIpSeen, walletDepinNodeIps, from, ipKey);
            }
        }

        if (nodeWalletBeneficiary[nodeWallet] == from && !_fromStillOwnsWallet(beneficiaryGuardianNodeWallets, from, nodeWallet)) {
            nodeWalletBeneficiary[nodeWallet] = address(0);
        }

        uint256 gbMoved = guardianIdGbMining[guardianId] ? 1 : 0;
        guardianIdGbMining[guardianId] = false;

        if (validatorNodeCountOf[from] >= 1) {
            validatorNodeCountOf[from] -= 1;
        } else {
            validatorNodeCountOf[from] = 0;
        }

        if (gbMiningNodeCountOf[from] >= gbMoved) {
            gbMiningNodeCountOf[from] -= gbMoved;
        } else {
            gbMiningNodeCountOf[from] = 0;
        }

        emit GuardianNodeReleased(guardianId, from, ip, nodeWallet);
    }

    function releaseGuardianIdsFrom(
        mapping(uint256 => address) storage guardianIdBeneficiary,
        mapping(address => uint256[]) storage beneficiaryGuardianIds,
        mapping(address => address[]) storage beneficiaryGuardianNodeWallets,
        mapping(uint256 => bool) storage guardianIdGbMining,
        mapping(bytes32 => address) storage depinIpBeneficiary,
        mapping(address => address) storage nodeWalletBeneficiary,
        mapping(address => mapping(bytes32 => bool)) storage walletDepinIpSeen,
        mapping(address => string[]) storage walletDepinNodeIps,
        mapping(address => uint256) storage validatorNodeCountOf,
        mapping(address => uint256) storage gbMiningNodeCountOf,
        mapping(uint256 => ValidatorBinding) storage nodeValidator,
        address guardianNodes,
        address transferMarket,
        address from,
        uint256[] calldata guardianIds
    ) external {
        require(from != address(0), "ValidatorRedeem: zero from");
        require(guardianIds.length > 0, "ValidatorRedeem: empty");
        for (uint256 i = 0; i < guardianIds.length; i++) {
            if (transferMarket != address(0)) {
                require(
                    ITransferMarketGuard(transferMarket).nodeOrder(guardianIds[i]) == 0,
                    "ValidatorRedeem: node listed in order"
                );
            }
            _releaseOneGuardianId(
                guardianIdBeneficiary,
                beneficiaryGuardianIds,
                beneficiaryGuardianNodeWallets,
                guardianIdGbMining,
                depinIpBeneficiary,
                nodeWalletBeneficiary,
                walletDepinIpSeen,
                walletDepinNodeIps,
                validatorNodeCountOf,
                gbMiningNodeCountOf,
                nodeValidator,
                guardianNodes,
                from,
                guardianIds[i]
            );
        }
    }

    function _fromStillOwnsWallet(
        mapping(address => address[]) storage beneficiaryGuardianNodeWallets,
        address from,
        address nodeWallet
    ) private view returns (bool) {
        address[] storage wallets = beneficiaryGuardianNodeWallets[from];
        for (uint256 i = 0; i < wallets.length; i++) {
            if (wallets[i] == nodeWallet) return true;
        }
        return false;
    }

    function _removeDepinIpFromWallet(
        mapping(address => mapping(bytes32 => bool)) storage walletDepinIpSeen,
        mapping(address => string[]) storage walletDepinNodeIps,
        address beneficiary,
        bytes32 ipKey
    ) private {
        if (!walletDepinIpSeen[beneficiary][ipKey]) return;
        walletDepinIpSeen[beneficiary][ipKey] = false;
        string[] storage arr = walletDepinNodeIps[beneficiary];
        for (uint256 i = 0; i < arr.length; i++) {
            if (keccak256(bytes(arr[i])) == ipKey) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                break;
            }
        }
    }
}
