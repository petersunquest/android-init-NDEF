// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IGuardianNodesAllocReader {
    function id2ip(uint256 id) external view returns (string memory);
    function idOwner(uint256 id) external view returns (address);
    function ipaddressExisting(string memory ipaddress) external view returns (bool);
    function ipaddress2owner(string memory ipaddress) external view returns (address);
}

/**
 * @title ValidatorDepositRedeemAllocLib
 * @notice External library: Guardian id allocation with hole-fill (EIP-170 offload).
 */
library ValidatorDepositRedeemAllocLib {
    event GuardianNodeAllocated(
        uint256 indexed guardianId,
        address indexed beneficiary,
        string ip,
        address nodeWallet
    );

    function allocateGuardianNodesFromGuardian(
        mapping(uint256 => address) storage guardianIdBeneficiary,
        mapping(address => uint256[]) storage beneficiaryGuardianIds,
        mapping(address => address[]) storage beneficiaryGuardianNodeWallets,
        mapping(address => address) storage nodeWalletBeneficiary,
        address guardianNodes,
        uint256 guardianAllocStartId,
        uint256 nextGuardianAllocId,
        address beneficiary,
        uint256 count
    ) external returns (string[] memory ips, uint256 newNextGuardianAllocId) {
        require(guardianNodes != address(0), "ValidatorRedeem: guardian unset");
        ips = new string[](count);
        uint256 cursor = nextGuardianAllocId;
        for (uint256 i = 0; i < count; i++) {
            uint256 nodeId;
            uint256 newNext;
            (nodeId, newNext) = _resolveNextFreeGuardianNodeId(
                guardianIdBeneficiary,
                guardianAllocStartId,
                cursor
            );
            cursor = newNext;
            require(nodeId >= guardianAllocStartId, "ValidatorRedeem: before pool start");

            string memory ip = IGuardianNodesAllocReader(guardianNodes).id2ip(nodeId);
            require(bytes(ip).length != 0, "ValidatorRedeem: guardian id missing ip");
            require(IGuardianNodesAllocReader(guardianNodes).ipaddressExisting(ip), "ValidatorRedeem: ip not on guardian");

            address nodeWallet = IGuardianNodesAllocReader(guardianNodes).idOwner(nodeId);
            if (nodeWallet == address(0)) {
                nodeWallet = IGuardianNodesAllocReader(guardianNodes).ipaddress2owner(ip);
            }
            require(nodeWallet != address(0), "ValidatorRedeem: no node wallet");

            if (nodeWalletBeneficiary[nodeWallet] == address(0)) {
                nodeWalletBeneficiary[nodeWallet] = beneficiary;
            }

            guardianIdBeneficiary[nodeId] = beneficiary;
            beneficiaryGuardianIds[beneficiary].push(nodeId);
            beneficiaryGuardianNodeWallets[beneficiary].push(nodeWallet);

            ips[i] = ip;
            emit GuardianNodeAllocated(nodeId, beneficiary, ip, nodeWallet);
        }
        newNextGuardianAllocId = cursor;
    }

    function markGbMiningOnLatestNodes(
        mapping(address => uint256[]) storage beneficiaryGuardianIds,
        mapping(uint256 => bool) storage guardianIdGbMining,
        address beneficiary,
        uint256 validatorCount,
        uint256 gbCount
    ) external {
        if (gbCount == 0 || validatorCount == 0) return;
        uint256[] storage ids = beneficiaryGuardianIds[beneficiary];
        require(ids.length >= validatorCount, "ValidatorRedeem: alloc mismatch");
        uint256 start = ids.length - validatorCount;
        uint256 mark = gbCount > validatorCount ? validatorCount : gbCount;
        for (uint256 j = 0; j < mark; j++) {
            guardianIdGbMining[ids[start + j]] = true;
        }
    }

    function _resolveNextFreeGuardianNodeId(
        mapping(uint256 => address) storage guardianIdBeneficiary,
        uint256 guardianAllocStartId,
        uint256 nextGuardianAllocId
    ) private returns (uint256 nodeId, uint256 newNext) {
        for (nodeId = guardianAllocStartId; nodeId < nextGuardianAllocId; ) {
            if (guardianIdBeneficiary[nodeId] == address(0)) {
                return (nodeId, nextGuardianAllocId);
            }
            unchecked {
                nodeId++;
            }
        }
        nodeId = nextGuardianAllocId;
        while (guardianIdBeneficiary[nodeId] != address(0)) {
            unchecked {
                nodeId++;
            }
        }
        newNext = nodeId + 1;
        return (nodeId, newNext);
    }
}
