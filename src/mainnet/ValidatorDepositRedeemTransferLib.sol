// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ValidatorBinding} from "./ValidatorDepositRedeemTypes.sol";

interface IGuardianNodesTransferReader {
    function id2ip(uint256 id) external view returns (string memory);
}

/**
 * @title ValidatorDepositRedeemTransferLib
 * @notice External library: hot-transfer one Guardian node id between beneficiaries (EIP-170 offload).
 */
library ValidatorDepositRedeemTransferLib {
    event DepinNodeBeneficiaryAssigned(bytes32 indexed ipKey, address indexed beneficiary, string ip);
    event NodeValidatorBeneficiaryUpdated(
        uint256 indexed guardianId,
        bytes32 indexed pubkeyHash,
        address indexed from,
        address to
    );

    function transferOneGuardianId(
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
        mapping(address => uint256) storage stakedValidatorCountOf,
        mapping(uint256 => ValidatorBinding) storage nodeValidator,
        address guardianNodes,
        address from,
        address to,
        uint256 guardianId
    ) external {
        require(guardianId != 0, "ValidatorRedeem: zero guardian id");
        require(guardianIdBeneficiary[guardianId] == from, "ValidatorRedeem: not from beneficiary node");

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

        guardianIdBeneficiary[guardianId] = to;
        beneficiaryGuardianIds[to].push(guardianId);
        beneficiaryGuardianNodeWallets[to].push(nodeWallet);

        uint256 last = len - 1;
        fromIds[idx] = fromIds[last];
        fromWallets[idx] = fromWallets[last];
        fromIds.pop();
        fromWallets.pop();

        if (guardianNodes != address(0)) {
            string memory ip = IGuardianNodesTransferReader(guardianNodes).id2ip(guardianId);
            if (bytes(ip).length != 0) {
                bytes32 ipKey = keccak256(bytes(ip));
                depinIpBeneficiary[ipKey] = to;
                _removeDepinIpFromWallet(walletDepinIpSeen, walletDepinNodeIps, from, ipKey);
                _addDepinIpToWallet(walletDepinIpSeen, walletDepinNodeIps, to, ip, ipKey);
                emit DepinNodeBeneficiaryAssigned(ipKey, to, ip);
            }
        }

        if (nodeWalletBeneficiary[nodeWallet] == from && !_fromStillOwnsWallet(beneficiaryGuardianNodeWallets, from, nodeWallet)) {
            nodeWalletBeneficiary[nodeWallet] = to;
        }
        if (nodeWalletBeneficiary[nodeWallet] == address(0)) {
            nodeWalletBeneficiary[nodeWallet] = to;
        }

        uint256 gbMoved = guardianIdGbMining[guardianId] ? 1 : 0;

        if (validatorNodeCountOf[from] >= 1) {
            validatorNodeCountOf[from] -= 1;
        } else {
            validatorNodeCountOf[from] = 0;
        }
        validatorNodeCountOf[to] += 1;

        if (gbMiningNodeCountOf[from] >= gbMoved) {
            gbMiningNodeCountOf[from] -= gbMoved;
        } else {
            gbMiningNodeCountOf[from] = 0;
        }
        gbMiningNodeCountOf[to] += gbMoved;

        ValidatorBinding storage b = nodeValidator[guardianId];
        if (b.pubkey.length != 0 && b.active) {
            b.withdrawalBeneficiary = to;
            emit NodeValidatorBeneficiaryUpdated(guardianId, keccak256(b.pubkey), from, to);
            if (stakedValidatorCountOf[from] > 0) {
                stakedValidatorCountOf[from] -= 1;
            }
            stakedValidatorCountOf[to] += 1;
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

    function _addDepinIpToWallet(
        mapping(address => mapping(bytes32 => bool)) storage walletDepinIpSeen,
        mapping(address => string[]) storage walletDepinNodeIps,
        address beneficiary,
        string memory ip,
        bytes32 ipKey
    ) private {
        if (walletDepinIpSeen[beneficiary][ipKey]) return;
        walletDepinIpSeen[beneficiary][ipKey] = true;
        walletDepinNodeIps[beneficiary].push(ip);
    }
}
